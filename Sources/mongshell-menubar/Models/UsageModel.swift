import Foundation
import SwiftUI
import UserNotifications

/// Owns the usage snapshot + connection state and drives polling.
/// Shared singleton so the AppKit status item and SwiftUI views agree.
@MainActor
final class UsageModel: ObservableObject {
    static let shared = UsageModel()

    // Mirrors of `session`, published one by one so `$snapshot` subscribers
    // (the status item's width) hear only what changed. See `UsageSession`.
    @Published private(set) var snapshot: UsageSnapshot = .sample
    @Published private(set) var loadState: LoadState = .signedOut
    @Published private(set) var accountSource: DataSource?

    /// The one place the state above changes (#103).
    private var session = UsageSession() {
        didSet {
            if snapshot != session.snapshot { snapshot = session.snapshot }
            if loadState != session.loadState { loadState = session.loadState }
            if accountSource != session.accountSource { accountSource = session.accountSource }
        }
    }
    private var thresholds = UsageThresholdWatch()

    private let api = UsageAPIClient()
    private let auth = AuthService()
    private var pollTask: Task<Void, Never>?
    /// The refresh token is single-use and rotates on every refresh, so two
    /// overlapping `refreshOnce` runs (poll loop + the popover's "새로고침")
    /// can each spend it and sign the user out. `@MainActor` makes this plain
    /// flag a sufficient guard within this process only; a race with another
    /// instance (a stale dev build left running after `make_app.sh`) is
    /// stopped by `ownTokenStillCurrent` instead.
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
        if Preferences.shared.notifyThresholds { requestNotificationAuth() }
        pollTask?.cancel()
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    /// The popover's "새로고침" and "재시도". Does nothing inside a rate
    /// limit — the poll loop asks again once it is over (#86).
    func refreshNow() {
        guard manualRefreshBlockedUntil == nil else { return }
        Task { await refreshOnce() }
    }

    /// When the manual refresh opens again, or nil when it is open now.
    var manualRefreshBlockedUntil: Date? {
        UsageRetryPolicy.manualRefreshBlocked(until: loadState, now: Date())
    }

    private var pollBase: Int { max(Config.minPollInterval, Preferences.shared.pollIntervalSeconds) }

    private func pollLoop() async {
        while !Task.isCancelled {
            await refreshOnce()
            var wait = TimeInterval(UsageRetryPolicy.pollWait(base: pollBase, backoff: session.backoff))
            if case .rateLimited(let retryAt) = loadState {
                wait = max(wait, retryAt.timeIntervalSinceNow)
            }
            try? await Task.sleep(for: .seconds(wait))
        }
    }

    // MARK: Token resolution

    private func currentToken() -> UsageTokenChoice {
        let own = CredentialStore.lookupOwnToken()
        if case .refused(let status) = own { AuthDebugLog.write("own token refused status=\(status)") }
        return UsageRefreshPolicy.chooseToken(own: own, cli: CredentialStore.loadClaudeCodeToken)
    }

    // MARK: Refresh

    /// Satisfies one refresh request. Requests that arrive while a refresh is
    /// in flight are coalesced into a single follow-up run, however many
    /// there were.
    private func refreshOnce() async {
        guard !refreshInFlight else { refreshRequested = true; return }
        refreshInFlight = true
        defer { refreshInFlight = false }
        repeat {
            refreshRequested = false
            await performRefresh()
        } while refreshRequested
    }

    private func performRefresh() async {
        let initialToken: OAuthToken, source: DataSource
        switch currentToken() {
        case .token(let found, let foundSource):
            (initialToken, source) = (found, foundSource)
        case .none:
            session.noToken()
            return
        case .ownUnavailable(let status):
            AuthDebugLog.write("own token unavailable status=\(status)")
            session.failed("Keychain 이 잠겨 있어 로그인 정보를 읽지 못했습니다")
            return
        }
        var token = initialToken
        session.begin(accessToken: token.accessToken, source: source)

        if UsageRefreshPolicy.shouldRenewUpFront(source: source, tokenExpired: token.isExpired) {
            let renewal = await renewOwnToken(token)
            switch (UsageRefreshPolicy.step(afterUpFront: renewal.kind), renewal) {
            case (.useRenewed, .renewed(let renewed)):
                guard ownTokenStillCurrent(token) else { return }
                CredentialStore.saveOwnToken(renewed)
                token = renewed
            case (.useRenewed, _):
                assertionFailure("useRenewed without a renewed token")
                return
            case (.expireSession, _):
                expireSession(token)
                return
            case (.pollAnyway, _):
                break
            }
        }

        let first = await fetchUsage(token)
        if first == .unauthorized { AuthDebugLog.write("usage 401 source=\(source)") }
        var retry: OwnTokenRetry?
        if UsageRefreshPolicy.shouldRenew(after: first, source: source) {
            switch await renewOwnToken(token) {
            case .renewed(let renewed):
                guard ownTokenStillCurrent(token) else { return }
                CredentialStore.saveOwnToken(renewed)
                token = renewed
                retry = .refetched(await fetchUsage(renewed))
            case .sessionExpired:
                retry = .sessionExpired
            case .transientFailure:
                retry = .renewalFailed
            }
        }
        apply(UsageRefreshPolicy.step(after: first, retry: retry), token: token, source: source)
    }

    private func fetchUsage(_ token: OAuthToken) async -> UsageFetchResult {
        do {
            return .ok(try await api.fetch(token: token))
        } catch {
            return UsageFetchResult(.failure(error))
        }
    }

    /// `token` is the last one tried: the renewed token after a refresh, so
    /// a second 401 rejects that one, and the pre-refresh one otherwise.
    private func apply(_ step: UsageRefreshStep, token: OAuthToken, source: DataSource) {
        switch step {
        case .show(let snap):
            session.loaded(snap, source: source)
            logUnknownLimitsIfChanged(snap)
            maybeNotify(percent: snap.fiveHourPercent)
        case .signOut:
            session.rejected(accessToken: token.accessToken)
        case .expireSession:
            expireSession(token)
        case .rateLimited(let retryAfter):
            session.rateLimited(retryAfter: retryAfter, now: Date(), pollBase: pollBase)
        case .failed:
            session.failed("사용량을 불러오지 못했습니다")
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
    func presentForSnapshot(_ snap: UsageSnapshot, state: LoadState) {
        pollTask?.cancel()
        pollTask = nil
        session.present(snap, state: state)
    }

    private enum OwnTokenRenewal {
        case renewed(OAuthToken)
        /// The server rejected the refresh token for good — keeping it only
        /// buys a 400 every poll and blocks the CLI-token fallback.
        case sessionExpired
        /// Network or server trouble; the token may still be fine, so keep it.
        case transientFailure

        var kind: UpFrontRenewal {
            switch self {
            case .renewed: return .renewed
            case .sessionExpired: return .sessionExpired
            case .transientFailure: return .renewalFailed
            }
        }
    }

    private func renewOwnToken(_ token: OAuthToken) async -> OwnTokenRenewal {
        do {
            return .renewed(try await auth.refresh(token))
        } catch AuthError.invalidGrant {
            return .sessionExpired
        } catch {
            return .transientFailure
        }
    }

    /// Drops the dead own token so the next poll falls through to the CLI
    /// token (or to signed-out), and tells the user once. No repeat guard is
    /// needed: with the token gone, nothing can reach this path again until
    /// the user signs in anew.
    private func expireSession(_ token: OAuthToken) {
        guard ownTokenStillCurrent(token) else { return }
        AuthDebugLog.write("own token discarded (invalid_grant) \(AuthDebugLog.session(token))")
        CredentialStore.clearOwnToken()
        session.expired()
        notifySessionExpired()
    }

    /// Guards every write to the own token. The poll may be renewing or
    /// discarding a token that `signIn()` — or another instance of this app —
    /// has replaced in the meantime; acting on the stale one would overwrite
    /// or delete the fresh login. When the Keychain has moved on the caller
    /// leaves it alone and the next poll re-reads it.
    private func ownTokenStillCurrent(_ token: OAuthToken) -> Bool {
        if CredentialStore.loadOwnToken()?.refreshToken == token.refreshToken { return true }
        AuthDebugLog.write("own token changed elsewhere; kept")
        return false
    }

    // MARK: Sign in / out

    func signIn() async {
        do {
            let token = try await auth.signIn()
            // A token that did not reach the Keychain is gone at the next
            // poll, which would then quietly fall back to the CLI token.
            guard CredentialStore.saveOwnToken(token) else {
                session.failed("로그인 정보를 Keychain 에 저장하지 못했습니다")
                return
            }
            session.signedIn()
            await refreshOnce()
        } catch {
            session.failed((error as? LocalizedError)?.errorDescription ?? "로그인 실패")
        }
    }

    func signOut() {
        CredentialStore.clearOwnToken()
        session.signedOut()
    }

    // MARK: Notifications

    /// UserNotifications requires a real app bundle; guard so an unbundled
    /// `swift run` dev launch doesn't crash.
    private var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    private func requestNotificationAuth() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Not tied to `notifyThresholds`: that toggle is about usage levels, and
    /// this is a rare, action-required event of a different kind. Asks for
    /// permission on the spot in case the threshold prompt never ran.
    private func notifySessionExpired() {
        guard notificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "Claude 로그인이 만료되었습니다"
        content.body = "메뉴바 아이콘을 눌러 다시 로그인하세요."
        let request = UNNotificationRequest(identifier: "mongshell-menubar-session-expired",
                                            content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }

    private func maybeNotify(percent: Int) {
        guard Preferences.shared.notifyThresholds, notificationsAvailable,
              let level = thresholds.observe(percent: percent) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Claude 사용량 \(level)% 도달"
        content.body = level >= 90 ? "곧 한도에 도달합니다." : "사용량이 \(percent)%입니다."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "mongshell-menubar-\(level)", content: content, trigger: nil)
        )
    }
}
