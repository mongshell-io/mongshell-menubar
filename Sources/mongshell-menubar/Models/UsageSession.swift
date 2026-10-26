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

    static let backoffCap = 4

    // MARK: Refresh events

    /// No token anywhere.
    mutating func noToken(now: Date) {
        markSignedOut(now: now)
    }

    /// A refresh is about to poll with this token.
    mutating func begin(accessToken: String, source: DataSource) {
        accountSource = accessToken == rejectedAccessToken ? nil : source
        if case .signedOut = loadState { loadState = .loading }
    }

    /// A successful fetch is the one thing that resolves a lapsed login on
    /// its own: it proves whichever token we hold now works.
    mutating func loaded(_ snap: UsageSnapshot, source: DataSource) {
        snapshot = snap
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

    /// The own token was discarded after `invalid_grant`.
    mutating func expired(now: Date) {
        snapshot = .sample(now: now)
        accountSource = nil
        expiredUnresolved = true
        loadState = .sessionExpired
    }

    mutating func rateLimited(retryAfter: TimeInterval?, now: Date, pollBase: Int) {
        backoff = min(backoff + 1, Self.backoffCap)
        loadState = .rateLimited(retryAt: UsageRetryPolicy.retryAt(
            now: now, base: pollBase, backoff: backoff, retryAfter: retryAfter))
    }

    /// Keeps the account and the numbers; the next poll tries again.
    mutating func failed(_ message: String) {
        loadState = .error(message)
    }

    // MARK: User events

    /// A new login reached the Keychain; the lapsed-login notice has done
    /// its job.
    mutating func signedIn() {
        expiredUnresolved = false
    }

    mutating func signedOut(now: Date) {
        expiredUnresolved = false
        accountSource = nil
        loadState = .signedOut
        snapshot = .sample(now: now)
    }

    /// Snapshot hook: a given snapshot and state, nothing else carried over.
    mutating func present(_ snap: UsageSnapshot, state: LoadState) {
        snapshot = snap
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
