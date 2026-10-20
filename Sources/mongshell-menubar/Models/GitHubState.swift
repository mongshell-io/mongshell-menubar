import Foundation

/// Which Keychain item the working token came from (Decision #45 (c)).
enum GitHubTokenSource: Equatable, Sendable {
    /// The gh CLI's item; `account` is the GitHub username it was stored under.
    case ghCLI(account: String)
    /// A classic PAT the user pasted into our own item.
    case pat
}

/// Connection state of the GitHub region. Like `OpenClawHealth`, "no
/// precondition" cases are kept apart from failures: each one is a different
/// banner, and none of them is an empty list.
enum GitHubLoadState: Equatable, Sendable {
    /// The region is switched off — render nothing, poll nothing.
    case off
    /// Neither a PAT nor a gh CLI item exists.
    case noToken
    /// The user refused the Keychain prompt for gh's item; remembered for the
    /// session, retried only from settings.
    case keychainDenied
    /// A token is known; the first answer hasn't arrived.
    case loading
    case loaded(GitHubTokenSource)
    /// 403/429/`RATE_LIMITED`, or the remaining budget fell under the reserve.
    case rateLimited(retryAt: Date)
    /// 401 — the token was rejected.
    case unauthorized
    case error(String)

    /// Hover text while the region shows a grey dot. Empty when the region is
    /// off or when a snapshot speaks instead.
    var hoverLabel: String {
        switch self {
        case .off, .loaded:   return ""
        case .noToken:        return "GitHub 토큰 없음"
        case .keychainDenied: return "Keychain 접근 거부됨"
        case .loading:        return "확인 중…"
        case .rateLimited:    return "API 한도 초과"
        case .unauthorized:   return "토큰이 거부되었어요 (401)"
        case .error(let s):   return s
        }
    }
}

/// `rateLimit { cost remaining limit resetAt }` of the request that produced
/// a snapshot. The popover footer shows remaining / limit.
struct GitHubRateLimit: Equatable, Sendable {
    let cost: Int
    let remaining: Int
    let limit: Int
    let resetAt: Date?
}

/// One answer to the one GraphQL request: the three lists plus what the
/// response said about the token and the budget.
struct GitHubSnapshot: Equatable, Sendable {
    var reviewRequested: [GitHubPullRequest]
    var mine: [GitHubPullRequest]
    var recentlyMerged: [GitHubPullRequest]
    var rateLimit: GitHubRateLimit?
    var fetchedAt: Date
    /// `x-oauth-scopes` was present and lacked `repo` → private repos may be
    /// missing (banner). nil when the header wasn't sent (fine-grained PAT).
    var tokenScopesLackRepo: Bool?

    /// A check still running or queued anywhere in the two open lists — what
    /// switches the open popover to the fast cadence.
    var hasPendingChecks: Bool {
        (reviewRequested + mine).contains { $0.checks.contains { $0.outcome.isPending } }
    }

    /// The same snapshot without the repositories the user hid ("owner/name",
    /// lowercased). Every consumer — glance, hover, popover — reads through
    /// this so a hidden repo shows up nowhere.
    func hiding(_ repos: Set<String>) -> GitHubSnapshot {
        guard !repos.isEmpty else { return self }
        func keep(_ pr: GitHubPullRequest) -> Bool { !repos.contains(pr.repository.lowercased()) }
        var out = self
        out.reviewRequested = reviewRequested.filter(keep)
        out.mine = mine.filter(keep)
        out.recentlyMerged = recentlyMerged.filter(keep)
        return out
    }
}

/// How long to sleep before the next poll (Decision #45 (d)). Pure so the
/// cadence rules are pinned by `scripts/test.sh`.
enum GitHubPollPolicy {
    static let maxBackoffWait = 3600

    /// - base: the user's setting, clamped to `Config.githubPollRange`.
    /// - backoff: exponent after rate-limit trouble; while it is above zero
    ///   the open-popover cadence is ignored — backing off must not be undone
    ///   by looking at the popover.
    /// - popoverOpen + hasPendingChecks: the only case for the 30s cadence.
    static func nextWait(base: Int, backoff: Int, popoverOpen: Bool, hasPendingChecks: Bool) -> Int {
        let range = Config.githubPollRange
        let base = min(max(base, range.lowerBound), range.upperBound)
        if backoff > 0 { return min(base * (1 << backoff), maxBackoffWait) }
        if popoverOpen && hasPendingChecks { return Config.githubOpenPollSeconds }
        return base
    }

    /// Whether opening the popover asks GitHub at once. Not while backing
    /// off — looking at the popover must not add requests to a budget that
    /// is already short; the loop's backed-off wait stands.
    static func refreshesOnOpen(backoff: Int) -> Bool {
        backoff == 0
    }
}
