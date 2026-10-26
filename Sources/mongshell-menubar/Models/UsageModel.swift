import Foundation
import SwiftUI

/// Owns the usage snapshot + connection state and drives polling.
/// Shared singleton so the AppKit status item and SwiftUI views agree —
/// `shared`, built on the real boundaries, lives in `UsageModelLive.swift`.
@MainActor
final class UsageModel: ObservableObject {
    /// Everything the model reaches outside itself: the Keychain, OAuth, the
    /// usage endpoint, Notification Center and the two preferences it reads.
    /// One bundle so `scripts/test.sh` can compile this file with fakes that
    /// hold an await open and let a sign-in, sign-out or another refresh land
    /// there (#150). The app uses `.live`.
    ///
    /// The Keychain closures are `nonisolated(nonsending)` like the
    /// `CredentialStore` entry points they stand for: called from here they
    /// run on the main actor up to the queue, so the calls reach
    /// `KeychainQueue` in the order the model made them (Services/CLAUDE.md
    /// § Keychain 호출 스레드).
    struct Boundaries: Sendable {
        var lookupOwnToken: nonisolated(nonsending) @Sendable () async -> OwnTokenLookup
        var saveOwnToken: nonisolated(nonsending) @Sendable (OAuthToken) async -> OwnTokenSave
        var clearOwnToken: nonisolated(nonsending) @Sendable () async -> Bool
        /// `readingKeychain` false: the CLI file only (#155).
        var loadClaudeCodeToken: nonisolated(nonsending) @Sendable (_ readingKeychain: Bool) async -> ClaudeCodeTokenRead
        var signIn: @MainActor @Sendable () async throws -> OAuthToken
        var refresh: @MainActor @Sendable (OAuthToken) async throws -> OAuthToken
        var fetchUsage: @Sendable (OAuthToken) async throws -> UsageSnapshot
        var notificationsAvailable: @MainActor @Sendable () -> Bool
        var requestNotificationAuthorization: @MainActor @Sendable () -> Void
        var postNotification: @MainActor @Sendable (_ identifier: String, _ title: String, _ body: String) -> Void
        var postNotificationAfterAuthorizing: @MainActor @Sendable (_ identifier: String, _ title: String,
                                                                    _ body: String) -> Void
        var notifyThresholds: @MainActor @Sendable () -> Bool
        var pollIntervalSeconds: @MainActor @Sendable () -> Int
    }

    private let boundaries: Boundaries

    /// The app has one instance, `shared`; the order tests make their own.
    init(boundaries: Boundaries) {
        self.boundaries = boundaries
    }

    // Mirrors of `session`'s visible state. `@Published` sends
    // `objectWillChange` on every assignment, equal value or not, so the
    // `didSet` below assigns only what differs: a session change that shows
    // nothing new (a refresh starting under the same account, a flag, an
    // error repeated while real numbers are shown) leaves the views
    // observing this model — the menu bar icon among them — alone. While the
    // sample is up, each failed/rateLimited/noToken pass rebuilds it with
    // `sample(now:)` (#133), so that snapshot is published again.
    // See `UsageSession`.
    @Published private(set) var snapshot: UsageSnapshot = .sample(now: Date())
    @Published private(set) var loadState: LoadState = .signedOut
    @Published private(set) var accountSource: DataSource?
    /// Every own-token read folds its answer into this flag (#146), so it
    /// too is assigned only when it differs.
    @Published private(set) var keychainDeclined = false
    /// The same for the Claude Code CLI item (#155).
    @Published private(set) var cliKeychainDeclined = false
    /// Whether an own token the Keychain did not take is held — the banner
    /// reads it rather than guess from `loadState` (#151). Mirrors
    /// `pendingOwnToken`, assigned only when it differs, like the rest.
    @Published private(set) var holdsUnsavedLogin = false

    /// The one place the state above changes (#103).
    private var session = UsageSession() {
        didSet {
            if snapshot != session.snapshot { snapshot = session.snapshot }
            if loadState != session.loadState { loadState = session.loadState }
            if accountSource != session.accountSource { accountSource = session.accountSource }
            if keychainDeclined != session.keychainDeclined { keychainDeclined = session.keychainDeclined }
            if cliKeychainDeclined != session.cliKeychainDeclined { cliKeychainDeclined = session.cliKeychainDeclined }
        }
    }
    private var thresholds = UsageThresholdWatch()
    /// An own token the Keychain has not taken yet — a renewal (#108) or a
    /// sign-in (#151).
    private var pendingOwnToken: PendingOwnToken? {
        didSet {
            let holds = pendingOwnToken != nil
            if holdsUnsavedLogin != holds { holdsUnsavedLogin = holds }
        }
    }
    /// Bumped by every sign-in and sign-out. A refresh that started under an
    /// older value must not adopt or show what it got (#108).
    ///
    /// Invariant: every place that bumps this also bumps
    /// `session.declineLifts` (`allowKeychainAgain()` / `signedOut`). The
    /// decline is folded in by allowance alone (`UsageRefreshPolicy.declined`),
    /// so a bump here without one there would let a cancel from before the
    /// new login set the decline again. Pinned in Tests/UsageModelTests.
    private var loginGeneration = 0

    private var pollTask: Task<Void, Never>?
    /// The refresh token is single-use and rotates on every refresh, so two
    /// overlapping `refreshOnce` runs (poll loop + the popover's "새로고침")
    /// can each spend it and sign the user out. `@MainActor` makes this plain
    /// flag a sufficient guard within this process only; a race with another
    /// instance (a stale dev build left running after `make_app.sh`) is
    /// stopped by `keychainMatch` instead.
    private var refreshInFlight = false
    /// A refresh asked for while one was running. Dropping it would leave
    /// stale state on screen until the next poll — e.g. the expired-session
    /// banner after `signIn()` succeeded mid-poll — so the running refresh
    /// goes round once more instead.
    private var refreshRequested = false
    /// `AuthDebugLog.usageUnknownKey` of the last snapshot whose unknown
    /// limits were logged — the set of unknown things, not their numbers —
    /// so a response that keeps carrying the same ones is logged once.
    private var lastUnknownKey: String?

    // MARK: Lifecycle

    func start() {
        if boundaries.notifyThresholds() { boundaries.requestNotificationAuthorization() }
        pollTask?.cancel()
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    /// The popover's "새로고침", "재시도" and "다시 허용". Does nothing inside a rate
    /// limit — the poll loop asks again once it is over (#86). Asking for it
    /// is the user acting, so a declined Keychain prompt may show again.
    func refreshNow() {
        guard manualRefreshBlockedUntil == nil else { return }
        session.allowKeychainAgain()
        Task { await refreshOnce() }
    }

    /// When the manual refresh opens again, or nil when it is open now.
    var manualRefreshBlockedUntil: Date? {
        UsageRetryPolicy.manualRefreshBlocked(until: loadState, now: Date())
    }

    /// What the usage surfaces show and offer right now (#104).
    var presentation: UsagePresentation {
        UsagePresentation(loadState: loadState, accountSource: accountSource,
                          limitsUnread: snapshot.hasUnreadLimit, keychainDeclined: keychainDeclined,
                          cliKeychainDeclined: cliKeychainDeclined, holdsUnsavedLogin: holdsUnsavedLogin,
                          now: Date())
    }

    private var pollBase: Int { max(Config.minPollInterval, boundaries.pollIntervalSeconds()) }

    private func pollLoop() async {
        var wake = WakeRetry()
        while !Task.isCancelled {
            await refreshOnce()
            let failed = UsageRetryPolicy.wakeRetryFailed(after: loadState, backoff: session.backoff)
            var wait = TimeInterval(wake.wait(
                normal: UsageRetryPolicy.pollWait(base: pollBase, backoff: session.backoff), failed: failed))
            wake.polled(failed: failed)
            if case .rateLimited(let retryAt) = loadState {
                wait = max(wait, retryAt.timeIntervalSinceNow)
            }
            let mark = WakeRetry.Mark()
            try? await Task.sleep(for: .seconds(wait))
            wake.waitEnded(slept: mark.sleptSince)
        }
    }

    // MARK: Token resolution

    /// Every own-token read goes through here, so a declined prompt is not
    /// put back by any of them (#143). The read runs off the main thread
    /// (#141), so the answer is folded into the flag as it stands when the
    /// read comes back — a save the user cancelled meanwhile keeps it set.
    private func lookupOwnToken() async -> OwnTokenLookup {
        if let remembered = UsageRefreshPolicy.ownLookup(declined: session.keychainDeclined) { return remembered }
        let lifts = session.declineLifts
        let own = await boundaries.lookupOwnToken()
        if case .refused(let status) = own { AuthDebugLog.write("own token refused status=\(status)") }
        rememberDecline(UsageRefreshPolicy.declined(session.keychainDeclined, after: own,
                                                    sameAllowance: lifts == session.declineLifts))
        return own
    }

    /// Every own-token save goes through here, for the same reason.
    private func saveOwnToken(_ token: OAuthToken) async -> OwnTokenSave {
        let lifts = session.declineLifts
        let result = await boundaries.saveOwnToken(token)
        rememberDecline(UsageRefreshPolicy.declined(session.keychainDeclined, afterSaving: result,
                                                    sameAllowance: lifts == session.declineLifts))
        return result
    }

    private func rememberDecline(_ declined: Bool) {
        if declined, !session.keychainDeclined {
            AuthDebugLog.write("own token prompt declined; not asked again until the user acts")
        }
        session.setKeychainDeclined(declined)
    }

    /// Stores or drops the held renewal as `resolution` says. Returns false
    /// when a sign-in or sign-out came while the save was out: that dropped
    /// the held renewal already, and the refresh stops there.
    private func resolvePendingToken(_ resolution: PendingResolution, generation: Int) async -> Bool {
        switch resolution {
        case .none, .useInMemory:
            return true
        case .drop:
            AuthDebugLog.write("own token changed elsewhere; held renewal dropped")
            pendingOwnToken = nil
            return true
        case .save(let token):
            guard let held = pendingOwnToken else { return true }
            let result = await saveOwnToken(token)
            guard generation == loginGeneration else { return false }
            pendingOwnToken = UsageRefreshPolicy.pending(afterSaving: held, result: result)
            return true
        }
    }

    /// The CLI token is read only when the policy falls through to it — that
    /// read can prompt too.
    private func currentToken(_ resolution: PendingResolution, own: OwnTokenLookup) async -> UsageTokenChoice {
        if let choice = UsageRefreshPolicy.ownChoice(resolution: resolution, own: own) { return choice }
        return UsageRefreshPolicy.cliChoice(await loadClaudeCodeToken())
    }

    /// Every CLI-token read goes through here, so a declined prompt for that
    /// item is not put back by a poll either (#155): while the decline
    /// stands only the CLI file is read. Folded in like `lookupOwnToken`.
    private func loadClaudeCodeToken() async -> OAuthToken? {
        let lifts = session.declineLifts
        let read = await boundaries.loadClaudeCodeToken(!session.cliKeychainDeclined)
        let declined = UsageRefreshPolicy.declined(session.cliKeychainDeclined, afterReadingCLI: read,
                                                   sameAllowance: lifts == session.declineLifts)
        if declined, !session.cliKeychainDeclined {
            AuthDebugLog.write("Claude Code item prompt declined; not asked again until the user acts")
        }
        session.setCLIKeychainDeclined(declined)
        return read.token
    }

    // MARK: Refresh

    /// Satisfies one refresh request. Requests that arrive while a refresh is
    /// in flight are coalesced into a single follow-up run, however many
    /// there were. Not private only so the order tests can await a whole
    /// refresh (#150); the app goes through `start()` and `refreshNow()`.
    func refreshOnce() async {
        guard !refreshInFlight else { refreshRequested = true; return }
        refreshInFlight = true
        defer { refreshInFlight = false }
        repeat {
            refreshRequested = false
            await performRefresh()
        } while refreshRequested
    }

    /// Every Keychain call here is awaited off the main thread (#141), so a
    /// sign-in or sign-out can land between any two steps. Each step after
    /// an await checks `loginGeneration` before it acts on what it read;
    /// another refresh cannot land there — `refreshInFlight` holds across
    /// the awaits.
    private func performRefresh() async {
        let generation = loginGeneration
        let own = await lookupOwnToken()
        // A sign-in or sign-out while a read was out wins; the read speaks
        // for the Keychain before it, and its own refresh shows what follows.
        guard generation == loginGeneration else { return }
        let resolution = UsageRefreshPolicy.resolvePending(pendingOwnToken, own: own)
        guard await resolvePendingToken(resolution, generation: generation) else { return }
        let choice = await currentToken(resolution, own: own)
        guard generation == loginGeneration else { return }
        let initialToken: OAuthToken, source: DataSource
        switch choice {
        case .token(let found, let foundSource):
            (initialToken, source) = (found, foundSource)
        case .none:
            session.noToken(now: Date())
            return
        case .ownUnavailable(let status):
            AuthDebugLog.write("own token unavailable status=\(status)")
            session.ownTokenUnreadable("Keychain 이 잠겨 있어 로그인 정보를 읽지 못했습니다", now: Date())
            return
        }
        var token = initialToken
        session.begin(accessToken: token.accessToken, source: source)

        if UsageRefreshPolicy.shouldRenewUpFront(source: source, tokenExpired: token.isExpired) {
            switch UsageRefreshPolicy.step(afterUpFront: await renewOwnToken(token)) {
            case .useRenewed(let renewed):
                guard await adoptRenewed(renewed, replacing: token, generation: generation) else { return }
                token = renewed
            case .expireSession:
                await expireSession(token, generation: generation)
                return
            case .pollAnyway:
                break
            }
        }

        let first = await fetchUsage(token)
        if first == .unauthorized { AuthDebugLog.write("usage 401 source=\(source)") }
        var retry: OwnTokenRetry?
        if UsageRefreshPolicy.shouldRenew(after: first, source: source) {
            switch await renewOwnToken(token) {
            case .renewed(let renewed):
                guard await adoptRenewed(renewed, replacing: token, generation: generation) else { return }
                token = renewed
                retry = .refetched(await fetchUsage(renewed))
            case .sessionExpired:
                retry = .sessionExpired
            case .transientFailure:
                retry = .renewalFailed
            }
        }
        // A sign-in or sign-out while the requests were out wins; its own
        // refresh shows the state that follows.
        guard generation == loginGeneration else { return }
        await apply(UsageRefreshPolicy.step(after: first, retry: retry), token: token, source: source,
                    generation: generation)
    }

    private func fetchUsage(_ token: OAuthToken) async -> UsageFetchResult {
        do {
            return .ok(try await boundaries.fetchUsage(token))
        } catch {
            return UsageFetchResult(.failure(error))
        }
    }

    /// `token` is the last one tried: the renewed token after a refresh, so
    /// a second 401 rejects that one, and the pre-refresh one otherwise.
    private func apply(_ step: UsageRefreshStep, token: OAuthToken, source: DataSource, generation: Int) async {
        switch step {
        case .show(let snap):
            session.loaded(snap, source: source)
            logUnknownLimitsIfChanged(snap)
            // An unread 5-hour limit is not "under 25%": skipping it keeps the
            // watch from re-arming and repeating a level already sent (#130).
            if let five = snap.fiveHourPercent { maybeNotify(percent: five) }
        case .signOut:
            session.rejected(accessToken: token.accessToken, now: Date())
        case .expireSession:
            await expireSession(token, generation: generation)
        case .rateLimited(let retryAfter):
            session.rateLimited(retryAfter: retryAfter, now: Date(), pollBase: pollBase)
        case .failed:
            session.failed("사용량을 불러오지 못했습니다", now: Date())
        }
    }

    /// Writes one line when the response starts carrying limits or buckets
    /// the app has no rule for, or when that set changes (a percentage
    /// moving within the same set does not count). Nothing is written while
    /// it stays the same, nor when it goes away.
    private func logUnknownLimitsIfChanged(_ snap: UsageSnapshot) {
        let key = AuthDebugLog.usageUnknownKey(snap)
        guard key != lastUnknownKey else { return }
        lastUnknownKey = key
        if let line = AuthDebugLog.usageUnknownLine(snap) { AuthDebugLog.write(line) }
    }

    /// Snapshot hook: shows a given snapshot and state without any network,
    /// so reference images are deterministic and never carry real usage.
    /// `holdsUnsavedLogin` stands in for a held token, which the hook has
    /// no real one for.
    func presentForSnapshot(_ snap: UsageSnapshot, state: LoadState, keychainDeclined: Bool = false,
                            cliKeychainDeclined: Bool = false, holdsUnsavedLogin: Bool = false) {
        pollTask?.cancel()
        pollTask = nil
        pendingOwnToken = nil
        session.present(snap, state: state, keychainDeclined: keychainDeclined,
                        cliKeychainDeclined: cliKeychainDeclined)
        self.holdsUnsavedLogin = holdsUnsavedLogin
    }

    private func renewOwnToken(_ token: OAuthToken) async -> OwnTokenRenewal {
        do {
            return .renewed(try await boundaries.refresh(token))
        } catch AuthError.invalidGrant {
            return .sessionExpired
        } catch {
            return .transientFailure
        }
    }

    /// Drops the dead own token so the next poll falls through to the CLI
    /// token (or to signed-out), and tells the user once. When the Keychain
    /// cannot say whether it still holds that token, the notice goes up all
    /// the same but the item is left (#147); once it reads again the dead
    /// token lapses again, and `lapseIsNews` keeps that from notifying twice
    /// — even when a CLI fetch took the notice down in between.
    /// A sign-in or sign-out that lands while the Keychain is asked wins:
    /// before the delete, nothing is deleted; after it, its save was queued
    /// behind the delete and stands, and the lapsed notice is not shown over
    /// it.
    private func expireSession(_ token: OAuthToken, generation: Int) async {
        let expected = UsageRefreshPolicy.expectation(pending: pendingOwnToken, polling: token)
        let match = await keychainMatch(expected)
        guard generation == loginGeneration else { return }
        // The token is dead either way; a held renewal of it is too.
        pendingOwnToken = nil
        let step = UsageRefreshPolicy.lapse(match: match)
        switch step {
        case .leave:
            return
        case .noticeOnly:
            AuthDebugLog.write("own token lapsed (invalid_grant), Keychain cannot say; item kept \(AuthDebugLog.session(token))")
        case .discard:
            AuthDebugLog.write("own token discarded (invalid_grant) \(AuthDebugLog.session(token))")
            _ = await boundaries.clearOwnToken()
            guard generation == loginGeneration else { return }
        }
        let isNews = session.lapseIsNews(refreshToken: token.refreshToken)
        session.expired(refreshTokens: UsageRefreshPolicy.announcedRefreshTokens(lapsed: token, expected: expected,
                                                                                 step: step),
                        now: Date())
        if isNews { notifySessionExpired() }
    }

    /// Takes a renewed own token: stores it, or holds it in memory when the
    /// Keychain cannot say or cannot take it now — the server has already
    /// spent the old one (#108). Returns false when the Keychain has moved
    /// on (a sign-in, a sign-out or another instance of this app): the
    /// caller drops the renewal rather than overwrite the fresh login.
    /// `sameLogin` is read after the Keychain answered, and again after the
    /// save: a sign-in during the save queued its own save behind ours, so
    /// the fresh login stands and the renewal is not held against it.
    private func adoptRenewed(_ renewed: OAuthToken, replacing token: OAuthToken, generation: Int) async -> Bool {
        let expected = UsageRefreshPolicy.expectation(pending: pendingOwnToken, polling: token)
        let match = await keychainMatch(expected)
        let step = UsageRefreshPolicy.adopt(match: match, sameLogin: generation == loginGeneration)
        switch step {
        case .drop:
            // After a sign-in or sign-out the held token is theirs — a
            // sign-in the Keychain did not take holds its own (#151).
            if generation == loginGeneration { pendingOwnToken = nil }
            return false
        case .store:
            let result = await saveOwnToken(renewed)
            guard generation == loginGeneration else { return false }
            pendingOwnToken = UsageRefreshPolicy.pending(after: result, token: renewed, expected: expected)
        case .hold:
            pendingOwnToken = UsageRefreshPolicy.pending(after: nil, token: renewed, expected: expected)
        }
        if pendingOwnToken != nil {
            AuthDebugLog.write("renewed own token held in memory until the Keychain takes it")
        }
        return true
    }

    /// Guards every write to the own token. The poll may be renewing or
    /// discarding a token that `signIn()` — or another instance of this app —
    /// has replaced in the meantime; acting on the stale one would overwrite
    /// or delete the fresh login.
    private func keychainMatch(_ expected: KeychainExpectation) async -> KeychainMatch {
        let match = UsageRefreshPolicy.keychainMatch(own: await lookupOwnToken(), expects: expected)
        if match == .changed { AuthDebugLog.write("own token changed elsewhere; kept") }
        return match
    }

    // MARK: Sign in / out

    func signIn() async {
        do {
            let token = try await boundaries.signIn()
            loginGeneration += 1
            let generation = loginGeneration
            pendingOwnToken = nil
            // Signing in is the user acting: the save below may ask again.
            session.allowKeychainAgain()
            let save = await saveOwnToken(token)
            // A sign-out or another sign-in while the save was out wins.
            guard generation == loginGeneration else { return }
            // A token that did not reach the Keychain is held, not dropped:
            // dropped, the next poll fell back to the CLI token and the
            // user had to go through OAuth again (#151). The poll uses it
            // and stores it by the held-token rules — every poll after a
            // failure, on [다시 허용] or a manual refresh after a cancel.
            pendingOwnToken = UsageRefreshPolicy.pending(after: save, token: token, expected: .replacesAny)
            if pendingOwnToken != nil {
                AuthDebugLog.write("sign-in token held in memory until the Keychain takes it")
            }
            session.signedIn()
            await refreshOnce()
        } catch {
            session.failed((error as? LocalizedError)?.errorDescription ?? "로그인 실패", now: Date())
        }
    }

    /// Shows signed-out at once, and lifts a remembered decline with it
    /// (`UsageSession.signedOut`); the Keychain delete follows off the main
    /// thread (#141). A refresh that reads after it was queued behind the
    /// delete, so it does not bring the token back.
    func signOut() async {
        loginGeneration += 1
        let generation = loginGeneration
        pendingOwnToken = nil
        session.signedOut(now: Date())
        let cleared = await boundaries.clearOwnToken()
        guard generation == loginGeneration else { return }
        // The token is still there and the next poll would show it again.
        if !cleared { session.failed("Keychain 에서 로그인 정보를 지우지 못했습니다", now: Date()) }
    }

    // MARK: Notifications

    /// Not tied to `notifyThresholds`: that toggle is about usage levels, and
    /// this is a rare, action-required event of a different kind. Asks for
    /// permission on the spot in case the threshold prompt never ran.
    private func notifySessionExpired() {
        boundaries.postNotificationAfterAuthorizing("mongshell-menubar-session-expired",
                                                    "Claude 로그인이 만료되었습니다",
                                                    "메뉴바 아이콘을 눌러 다시 로그인하세요.")
    }

    /// The availability check comes before `observe`: a level the app could
    /// not have shown is not counted as announced.
    private func maybeNotify(percent: Int) {
        guard boundaries.notifyThresholds(), boundaries.notificationsAvailable(),
              let level = thresholds.observe(percent: percent) else { return }
        boundaries.postNotification("mongshell-menubar-\(level)",
                                    "Claude 사용량 \(level)% 도달",
                                    level >= UsageThresholdWatch.critical ? "곧 한도에 도달합니다." : "사용량이 \(percent)%입니다.")
    }
}
