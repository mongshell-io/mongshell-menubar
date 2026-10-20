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
    /// The pasted PAT could not be stored. Whatever the Keychain holds now
    /// is not the token the user just gave, so nothing is sent until they
    /// act again.
    case patSaveFailed(OSStatus)
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
        case .patSaveFailed(let status): return "PAT 를 Keychain 에 저장하지 못했어요 (\(status))"
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

/// One answer to the one GraphQL request: the two lists plus what the
/// response said about the token and the budget.
struct GitHubSnapshot: Equatable, Sendable {
    var mine: [GitHubPullRequest]
    var recentlyMerged: [GitHubPullRequest]
    var rateLimit: GitHubRateLimit?
    var fetchedAt: Date
    /// `x-oauth-scopes` was present and lacked `repo` → private repos may be
    /// missing (banner). nil when the header wasn't sent (fine-grained PAT).
    var tokenScopesLackRepo: Bool?

    /// One of my open PRs has checks still going, read as its badge and the
    /// hover's CI row read it (`effectiveChecks`) — what switches polling to
    /// the fast cadence, popover open or not (#51).
    var hasPendingChecks: Bool {
        mine.contains { $0.effectiveChecks == .pending }
    }

    /// The same snapshot without the repositories the user hid ("owner/name",
    /// lowercased). Every consumer — glance, hover, popover — reads through
    /// this so a hidden repo shows up nowhere.
    func hiding(_ repos: Set<String>) -> GitHubSnapshot {
        guard !repos.isEmpty else { return self }
        func keep(_ pr: GitHubPullRequest) -> Bool { !repos.contains(pr.repository.lowercased()) }
        var out = self
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
    ///   the fast cadence is ignored — a running check must not undo
    ///   backing off.
    /// - hasPendingChecks: the only case for the fast cadence. The popover
    ///   need not be open: the hover's CI row should not lag a whole base
    ///   interval behind the checks it shows.
    static func nextWait(base: Int, backoff: Int, hasPendingChecks: Bool) -> Int {
        let range = Config.githubPollRange
        let base = min(max(base, range.lowerBound), range.upperBound)
        if backoff > 0 { return min(base * (1 << backoff), maxBackoffWait) }
        if hasPendingChecks { return Config.githubPendingPollSeconds }
        return base
    }

    /// The wait before the next automatic poll, or nil for none (see
    /// `waitsForUser`).
    static func nextAutoWait(after state: GitHubLoadState, base: Int, backoff: Int,
                             hasPendingChecks: Bool) -> Int? {
        if waitsForUser(state) { return nil }
        return nextWait(base: base, backoff: backoff, hasPendingChecks: hasPendingChecks)
    }

    /// Whether opening the popover asks GitHub at once. Not while backing
    /// off — looking at the popover must not add requests to a budget that
    /// is already short; the loop's backed-off wait stands. Not while
    /// waiting for the user either: opening the popover to read the banner
    /// is not a request to resend.
    static func refreshesOnOpen(after state: GitHubLoadState, backoff: Int) -> Bool {
        backoff == 0 && !waitsForUser(state)
    }

    /// States that stop automatic requests. After a 401 the same rejected
    /// token would only be resent, and GitHub may answer repeated failures
    /// by refusing that user's valid credentials too (gh, the browser).
    /// After a failed PAT save the stored token is not the one the user
    /// just gave. Requests resume only on a user gesture — refresh/retry,
    /// PAT apply or clear, retrying gh's item, switching on — and stop
    /// again if that lands here too.
    private static func waitsForUser(_ state: GitHubLoadState) -> Bool {
        switch state {
        case .unauthorized, .patSaveFailed: return true
        default: return false
        }
    }
}
