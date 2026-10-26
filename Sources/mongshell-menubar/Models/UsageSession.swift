import CryptoKit
import Foundation

/// What the usage side shows, and the flags that decide it. Every change goes
/// through one of the events below: the fixes for #44, #86, #90 and #92 were
/// all about these flags drifting apart while `UsageModel` set them by hand
/// in several places, where `scripts/test.sh` could not reach (#103).
struct UsageSession: Equatable {
    private(set) var snapshot: UsageSnapshot = .sample(now: Date())
    private(set) var loadState: LoadState = .signedOut
    /// Whose token the app is polling with, nil when it has none that works.
    /// Kept apart from `loadState`, which a 429, an error or a fetch in
    /// flight replace — the settings' account row read only `.loaded` and
    /// showed "로그아웃됨" through those (#90).
    private(set) var accountSource: DataSource?
    /// 429s in a row, capped; the poll loop doubles its wait per step.
    private(set) var backoff = 0
    /// The access token the last 401 ended on. A stale CLI token is retried
    /// every poll; naming it as the account for the length of each doomed
    /// fetch made the settings row flicker back to "사용 중".
    private var rejectedAccessToken: String?
    /// The "login lapsed" notice is showing and the user has not acted on it.
    /// Kept apart from `loadState`, which tracks the current connection:
    /// folding the two into one enum was why a single 429 or transport error
    /// could overwrite the notice and let the next CLI 401 downgrade it to a
    /// plain `signedOut` (#44).
    private var expiredUnresolved = false
    /// `snapshot` is the placeholder a sign-out put up, not fetched numbers.
    /// Tracked by event rather than read off the snapshot: nothing in a
    /// snapshot's values marks it as the sample for certain.
    private var showsSample = true
    /// Fingerprints of the refresh tokens whose lapse the user has been
    /// shown, for the life of the app. A lapse the Keychain could not
    /// confirm leaves the dead token in place (#147); it lapses again once
    /// the item reads, and by then a CLI fetch may have taken the notice
    /// down — so the notice being up is not enough to tell it is old news.
    /// Digests, not the tokens: nothing here needs to spend them.
    private var announcedLapses: Set<SHA256Digest> = []
    /// The user declined the own-token Keychain prompt this session. Polls
    /// then neither read nor store the own item — each try put the dialog
    /// back (#143). Set from what each read or save answered
    /// (`UsageRefreshPolicy.declined`), lifted only where the user acts
    /// (`allowKeychainAgain()`, `signedOut`); a relaunch starts without it,
    /// like GitHub's `ghKeychainDenied`. The popover's banner reads it (#146).
    private(set) var keychainDeclined = false
    /// The same for the Claude Code CLI item (#155): the user declined its
    /// prompt this session, so polls read only the CLI file. Set and lifted
    /// under the same rules and by the same user acts as `keychainDeclined`
    /// — each read on its own item: declining one says nothing of the other.
    private(set) var cliKeychainDeclined = false
    /// Bumped wherever the user lifts the decline. A read or save that went
    /// out before the lift answers for the dialog the user acted past, so it
    /// does not set the flag again (`UsageRefreshPolicy.declined`). Kept
    /// apart from the model's login generation: [다시 허용] is no new login,
    /// and a refresh under it still adopts what it gets.
    private(set) var declineLifts = 0

    static let backoffCap = 4

    /// Whether a lapse of the token with this refresh token is news to the
    /// user: false while the notice from an earlier lapse is still up, and
    /// false for a refresh token whose lapse was already announced this
    /// session, notice up or not. Another token's lapse is news once the
    /// notice is down.
    func lapseIsNews(refreshToken: String?) -> Bool {
        guard !expiredUnresolved else { return false }
        guard let refreshToken else { return true }
        return !announcedLapses.contains(Self.fingerprint(refreshToken))
    }

    private static func fingerprint(_ refreshToken: String) -> SHA256Digest {
        SHA256.hash(data: Data(refreshToken.utf8))
    }

    // MARK: Refresh events

    /// No token anywhere.
    mutating func noToken(now: Date) {
        markSignedOut(now: now)
    }

    /// A refresh is about to poll with this token. Under the lapsed-login
    /// notice no account is named until a fetch works (`loaded`): the token
    /// read may be the dead one the Keychain could not confirm (#147), and
    /// naming it showed "내 로그인" with a sign-out button under the notice
    /// for as long as its renewal was out (#156).
    mutating func begin(accessToken: String, source: DataSource) {
        if !expiredUnresolved { accountSource = accessToken == rejectedAccessToken ? nil : source }
        if case .signedOut = loadState { loadState = .loading }
    }

    /// A successful fetch is the one thing that resolves a lapsed login on
    /// its own: it proves whichever token we hold now works.
    mutating func loaded(_ snap: UsageSnapshot, source: DataSource) {
        snapshot = snap
        showsSample = false
        loadState = .loaded(source)
        accountSource = source
        rejectedAccessToken = nil
        backoff = 0
        expiredUnresolved = false
    }

    /// The server turned this token away for good.
    mutating func rejected(accessToken: String, now: Date) {
        rejectedAccessToken = accessToken
        markSignedOut(now: now)
    }

    /// The own token lapsed on `invalid_grant` and the notice goes up; the
    /// refresh tokens this lapse covers are remembered as announced (see
    /// `lapseIsNews`, `UsageRefreshPolicy.announcedRefreshTokens`).
    mutating func expired(refreshTokens: [String], now: Date) {
        for refreshToken in refreshTokens { announcedLapses.insert(Self.fingerprint(refreshToken)) }
        snapshot = .sample(now: now)
        showsSample = true
        accountSource = nil
        expiredUnresolved = true
        loadState = .sessionExpired
    }

    /// Keeps the account and the numbers, like `failed`. A 429 right after
    /// signing in lands while the sample is still up, and the backoff can
    /// outlast its countdown.
    mutating func rateLimited(retryAfter: TimeInterval?, now: Date, pollBase: Int) {
        backoff = min(backoff + 1, Self.backoffCap)
        loadState = .rateLimited(retryAt: UsageRetryPolicy.retryAt(
            now: now, base: pollBase, backoff: backoff, retryAfter: retryAfter))
        rebuildSampleIfShowing(now: now)
    }

    /// Keeps the account and the numbers; the next poll tries again. A
    /// Keychain that stays locked while signed out fails every poll.
    mutating func failed(_ message: String, now: Date) {
        loadState = .error(message)
        rebuildSampleIfShowing(now: now)
    }

    /// The flag as `UsageRefreshPolicy.declined` folded the Keychain's
    /// answer into it.
    mutating func setKeychainDeclined(_ declined: Bool) {
        keychainDeclined = declined
    }

    /// The CLI item's flag as `UsageRefreshPolicy.declined(_:afterReadingCLI:sameAllowance:)`
    /// folded its read into it.
    mutating func setCLIKeychainDeclined(_ declined: Bool) {
        cliKeychainDeclined = declined
    }

    /// The own item would not read (a locked Keychain); the next poll
    /// reads again. Like `failed`, except under the lapsed-login notice: a
    /// lapse the Keychain could not confirm leaves the item (#147), and the
    /// locked read that follows would swap the notice and its login button
    /// for an error banner that stays for as long as the Keychain does.
    mutating func ownTokenUnreadable(_ message: String, now: Date) {
        guard expiredUnresolved else { return failed(message, now: now) }
        loadState = .sessionExpired
        rebuildSampleIfShowing(now: now)
    }

    // MARK: User events

    /// Signing in or a manual refresh: the user acting, so a declined
    /// Keychain prompt — either item's — may show again.
    mutating func allowKeychainAgain() {
        keychainDeclined = false
        cliKeychainDeclined = false
        declineLifts += 1
    }

    /// A new login reached the Keychain; the lapsed-login notice has done
    /// its job.
    mutating func signedIn() {
        expiredUnresolved = false
    }

    /// Signing out is the user acting too, and it deletes the item the
    /// declined prompt was for: a decline left standing would keep saying
    /// "Keychain 접근을 취소했어요" with [다시 허용] over the login banner.
    mutating func signedOut(now: Date) {
        expiredUnresolved = false
        keychainDeclined = false
        cliKeychainDeclined = false
        declineLifts += 1
        accountSource = nil
        loadState = .signedOut
        snapshot = .sample(now: now)
        showsSample = true
    }

    /// Snapshot hook: a given snapshot and state, nothing else carried over.
    /// A signed-out state is taken to be showing the sample, as it would be.
    mutating func present(_ snap: UsageSnapshot, state: LoadState, keychainDeclined: Bool = false,
                          cliKeychainDeclined: Bool = false) {
        snapshot = snap
        self.keychainDeclined = keychainDeclined
        self.cliKeychainDeclined = cliKeychainDeclined
        showsSample = state == .signedOut || state == .sessionExpired
        loadState = state
        if case .loaded(let source) = state { accountSource = source } else { accountSource = nil }
    }

    /// `sessionExpired` outranks `signedOut`: the banner that explains why the
    /// numbers went back to sample must survive the polls that follow (no
    /// token at all, or a CLI token that 401s) until the user acts. Both
    /// banners say the numbers are sample, so the numbers go back here too —
    /// a 401 that left the last real ones up contradicted its banner (#134).
    /// Rebuilt on every call, polls that stay signed out included, so the
    /// sample countdown is counted from now rather than from launch (#133).
    private mutating func markSignedOut(now: Date) {
        accountSource = nil
        loadState = expiredUnresolved ? .sessionExpired : .signedOut
        snapshot = .sample(now: now)
        showsSample = true
    }

    /// For the events that keep whatever numbers are up: real ones stay as
    /// they were, but a sample is rebuilt from `now` like every signed-out
    /// poll — one left from before would tick down to "곧 초기화" and stay
    /// there for as long as the polls keep failing (#133).
    private mutating func rebuildSampleIfShowing(now: Date) {
        if showsSample { snapshot = .sample(now: now) }
    }
}

/// When to post a usage-threshold notification: once per level on the way
/// up, never again on the way down until the window resets.
struct UsageThresholdWatch: Equatable {
    /// The top level.
    static let critical = 90
    static let thresholds = [critical, 75, 50, 25]

    private(set) var lastNotifiedLevel = 0

    /// Returns the level to announce now, or nil — a value out of a mutating
    /// function so the caller decides whether to notify (the command/query
    /// exception in code-standards). The caller skips this entirely while
    /// threshold notifications are off, so a level is only counted once it
    /// could have been shown.
    mutating func observe(percent: Int) -> Int? {
        let level = Self.thresholds.first(where: { percent >= $0 }) ?? 0
        guard level > lastNotifiedLevel else {
            if percent < Self.thresholds.last! { lastNotifiedLevel = 0 } // window reset
            return nil
        }
        lastNotifiedLevel = level
        return level
    }
}
