import Foundation

/// One weekly per-model usage row (e.g. "Fable 5" → 25%).
struct ModelUsage: Identifiable, Equatable {
    let name: String
    let percent: Int
    var id: String { name }
}

/// A `limits` entry whose `kind` the app does not know — e.g. a limit reset
/// or bonus granted from the Claude settings page. Carried through rather than
/// dropped so a new kind shows up in the popover without a release.
struct ExtraLimit: Identifiable, Equatable {
    /// `kind`, with an index suffix when the response repeats a kind.
    let id: String
    let kind: String
    /// `scope.model.display_name` when the entry has one.
    let scopeModel: String?
    let percent: Int
    /// The popover phrases it at draw time (`TimeText.resetsAt`).
    let resetAt: Date?
    /// `is_active` as sent; nil when absent. Logged only — the response marks
    /// `weekly_all` inactive too, so it does not mean "currently in effect".
    let isActive: Bool?

    /// Shown as the row label. Nothing is invented: the kind with its
    /// underscores spaced, prefixed by the scope's model name when there is
    /// one ("Fable 5 · bonus") — so a scoped row still differs from the
    /// `weekly_scoped` row of the same model.
    var name: String {
        let spacedKind = kind.replacingOccurrences(of: "_", with: " ")
        guard let scopeModel else { return spacedKind }
        return "\(scopeModel) · \(spacedKind)"
    }
}

/// A top-level response object the app does not read (`iguana_necktie`-style
/// code names). Only the non-sensitive fields are kept, for the debug log.
struct UnknownBucket: Equatable {
    let key: String
    let utilization: Int?
    let resetAt: Date?
}

/// Normalized usage snapshot that drives every view. Populated from the
/// oauth/usage response, or from sample data when signed out.
///
/// Note: the usage endpoint carries no peak/off-peak-pricing info, so this
/// model deliberately omits it rather than fabricating an "Off-peak" label.
struct UsageSnapshot: Equatable {
    /// Weekly all-models usage, 0…100 — the app's main number. nil when the
    /// response carried no readable value for it (a renamed `kind`, say) —
    /// never folded to 0, which would draw a reassuring green ring over a
    /// limit nobody read (#130).
    var weeklyAllPercent: Int?
    /// Reset instant of the weekly window. Only the instant is kept: each
    /// surface phrases it when it draws ("3일 8시간 후 초기화" counts down),
    /// so the text never freezes at the moment the response arrived (#133).
    var weeklyResetAt: Date?
    /// Per-model weekly rows (Opus/Fable/…).
    var models: [ModelUsage]
    /// `limits` entries of a kind the app does not know, in response order.
    var extraLimits: [ExtraLimit]
    /// Top-level objects the app does not read, sorted by key. Debug log only.
    var unknownTopLevel: [UnknownBucket]
    /// Windows (`seven_day`) read from their flat object although the response
    /// carried a `limits` array — its row for that window went missing or
    /// unreadable. Debug log only: an early sign of a format change.
    var flatFallbacks: [String] = []

    /// Usage-credits status when meaningful (e.g. "$4.20 남음" / "크레딧 소진"),
    /// else nil. Derived from the response `spend`/`extra_usage`.
    var creditsText: String?

    var lastUpdated: Date

    /// The weekly limit could not be read from the response.
    var hasUnreadLimit: Bool { weeklyAllPercent == nil }

    /// The placeholder numbers shown while signed out, with its resets
    /// counted from `now`. A function, not a stored constant: the countdown
    /// is phrased at draw time (#133), so a reset fixed at first read would
    /// tick down to "곧 초기화" a few days after launch and stay there.
    /// The half-minute of slack keeps "3일 8시간" through the seconds between
    /// building it and drawing it.
    static func sample(now: Date) -> UsageSnapshot {
        UsageSnapshot(
            weeklyAllPercent: 19,
            weeklyResetAt: now.addingTimeInterval(sampleWeeklyLeft),
            models: [ModelUsage(name: "Fable 5", percent: 25)],
            extraLimits: [],
            unknownTopLevel: [],
            creditsText: nil,
            lastUpdated: .distantPast
        )
    }

    private static let sampleWeeklyLeft: TimeInterval = 3 * 86400 + 8 * 3600 + 30
}

/// Where the current data came from — drives the popover's status/footer.
enum DataSource: Equatable {
    case sample                 // signed out; showing placeholder numbers
    case claudeCodeCLI          // token borrowed from ~/.claude / Keychain
    case oauthLogin             // signed in via the app's own OAuth
}

/// Auth/connection state for the popover.
enum LoadState: Equatable {
    case signedOut
    /// Was signed in with the app's own OAuth, but the server stopped honouring
    /// the refresh token (`invalid_grant`). Distinct from `signedOut` — "never
    /// signed in" and "the login lapsed" ask for different wording.
    case sessionExpired
    case loading
    case loaded(DataSource)
    /// `retryAt` is when the poll loop asks again; neither the poll nor the
    /// popover's manual refresh asks before it (#86). A fresh sign-in still
    /// checks its new token once.
    case rateLimited(retryAt: Date)
    case error(String)
}

/// When the usage endpoint may be asked again. The endpoint is unofficial
/// (Decision 2), so asking inside a rate limit risks stretching it — the
/// poll loop and the manual refresh read the same window from here.
enum UsageRetryPolicy {
    /// Longest the loop waits on its own, and the cap on a server's
    /// Retry-After so a hostile value can't park polling for days.
    static let maxWait = 3600

    /// The poll loop's next wait: the user's interval, doubled per 429 in a row.
    static func pollWait(base: Int, backoff: Int) -> Int {
        backoff > 0 ? min(base * (1 << backoff), maxWait) : base
    }

    /// When to ask again after a 429: the backoff wait, or the server's
    /// Retry-After when that is longer.
    static func retryAt(now: Date, base: Int, backoff: Int, retryAfter: TimeInterval?) -> Date {
        let serverWait = min(max(retryAfter ?? 0, 0), TimeInterval(maxWait))
        return now.addingTimeInterval(max(TimeInterval(pollWait(base: base, backoff: backoff)), serverWait))
    }

    /// Whether the poll that left `state` counts as failed for the retry
    /// after a wake (`WakeRetry`, #156). An error while a 429 backoff is
    /// still running keeps that backoff's wait: the short retry is for the
    /// network not being back, and the endpoint is the one the 429 came from.
    static func wakeRetryFailed(after state: LoadState, backoff: Int) -> Bool {
        guard case .error = state else { return false }
        return backoff == 0
    }

    /// nil when a manual refresh may go out now; otherwise when it may.
    static func manualRefreshBlocked(until state: LoadState, now: Date) -> Date? {
        guard case .rateLimited(let retryAt) = state, now < retryAt else { return nil }
        return retryAt
    }
}
