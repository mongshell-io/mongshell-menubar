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
    let resetAt: Date?
    /// e.g. "일요일 21:59 초기화"; empty when `resetAt` is nil.
    let resetText: String
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
    /// 5-hour rolling window usage, 0…100. nil when the response carried no
    /// readable value for it (a renamed `kind`, say) — never folded to 0, which
    /// would draw a reassuring green ring over a limit nobody read (#130).
    var fiveHourPercent: Int?
    /// Human text like "3시간 8분 후 초기화".
    var fiveHourResetText: String
    /// Raw reset instant of the 5-hour window — the menu bar formats this itself.
    var fiveHourResetAt: Date?

    /// Weekly all-models usage, 0…100; nil when unread, as above.
    var weeklyAllPercent: Int?
    /// e.g. "일요일 21:59 초기화".
    var weeklyResetText: String
    /// Raw reset instant of the weekly window.
    var weeklyResetAt: Date?
    /// Per-model weekly rows (Opus/Fable/…).
    var models: [ModelUsage]
    /// `limits` entries of a kind the app does not know, in response order.
    var extraLimits: [ExtraLimit]
    /// Top-level objects the app does not read, sorted by key. Debug log only.
    var unknownTopLevel: [UnknownBucket]

    /// Usage-credits status when meaningful (e.g. "$4.20 남음" / "크레딧 소진"),
    /// else nil. Derived from the response `spend`/`extra_usage`.
    var creditsText: String?

    var lastUpdated: Date

    /// The 5-hour or the weekly limit could not be read from the response.
    var hasUnreadLimit: Bool { fiveHourPercent == nil || weeklyAllPercent == nil }

    static let sample = UsageSnapshot(
        fiveHourPercent: 19,
        fiveHourResetText: "3시간 8분 후 초기화",
        fiveHourResetAt: Date().addingTimeInterval(3 * 3600 + 8 * 60),
        weeklyAllPercent: 19,
        weeklyResetText: "일요일 21:59 초기화",
        weeklyResetAt: Calendar.current.nextDate(
            after: Date(),
            matching: DateComponents(hour: 21, minute: 59, weekday: 1),
            matchingPolicy: .nextTime),
        models: [ModelUsage(name: "Fable 5", percent: 25)],
        extraLimits: [],
        unknownTopLevel: [],
        creditsText: nil,
        lastUpdated: .distantPast
    )
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

    /// nil when a manual refresh may go out now; otherwise when it may.
    static func manualRefreshBlocked(until state: LoadState, now: Date) -> Date? {
        guard case .rateLimited(let retryAt) = state, now < retryAt else { return nil }
        return retryAt
    }
}
