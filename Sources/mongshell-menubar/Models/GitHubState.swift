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
    /// `retryAt` is when the next automatic poll goes; `manualRetryAt` when
    /// the popover's 새로고침 opens again — earlier when the server named a
    /// time shorter than the backoff (#154). nil means it follows `retryAt`.
    case rateLimited(retryAt: Date, manualRetryAt: Date? = nil)
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

    /// One of my open PRs reads as checks-going (`effectiveChecks`, as its
    /// badge and the hover's CI row read it — so a PR whose checks already
    /// failed doesn't count) and has a running check that started within
    /// `Config.githubFastPollMaxRunningAge` of `now` — a start up to
    /// `Config.githubFastPollClockSkew` ahead of `now` counts, one further
    /// ahead does not. The only grounds for
    /// the fast cadence (Decision #45 후속 (#51)). A wait that may never end —
    /// queued checks, a status still expected, the rollup alone pending, a
    /// running check with no start time or one that has run past the cap —
    /// is still shown as going, but polls at base.
    func hasFreshRunningChecks(now: Date) -> Bool {
        mine.contains { pr in
            pr.effectiveChecks == .pending && pr.checks.contains { check in
                guard check.outcome == .running, let started = check.startedAt else { return false }
                let age = now.timeIntervalSince(started)
                return age >= -Config.githubFastPollClockSkew && age <= Config.githubFastPollMaxRunningAge
            }
        }
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

    /// The wait without the fast cadence. `base` is the user's setting,
    /// clamped to `Config.githubPollRange`; `backoff` the exponent after
    /// rate-limit trouble.
    static func nextWait(base: Int, backoff: Int) -> Int {
        let range = Config.githubPollRange
        let base = min(max(base, range.lowerBound), range.upperBound)
        if backoff > 0 { return min(base * (1 << backoff), maxBackoffWait) }
        return base
    }

    /// The wait before the next automatic poll, or nil for none (see
    /// `waitsForUser`). The fast cadence needs all three: no backoff — a
    /// running check must not undo backing off; a loaded state — a snapshot
    /// left over from before a missing token, a refused Keychain or an error
    /// speaks for no current answer, and polling fast would only repeat the
    /// failure; and `hasFreshRunningChecks` (`GitHubSnapshot`, read through
    /// the hidden repos). The popover need not be open: the hover's CI row
    /// should not lag a whole base interval behind the checks it shows.
    ///
    /// While rate-limited the wait never ends before `retryAt` (#154): the
    /// banner says when the next request goes, and one sent earlier only
    /// earns another refusal — on a token gh shares, so on the user's
    /// account. The usage loop keeps the same floor.
    static func nextAutoWait(after state: GitHubLoadState, base: Int, backoff: Int,
                             hasFreshRunningChecks: Bool, now: Date) -> Int? {
        if waitsForUser(state) { return nil }
        if backoff == 0, case .loaded = state, hasFreshRunningChecks {
            return Config.githubFastPollSeconds
        }
        let wait = nextWait(base: base, backoff: backoff)
        guard case .rateLimited(let retryAt, _) = state else { return wait }
        return max(wait, secondsUntil(retryAt, now: now))
    }

    /// When to ask again after a rate-limited answer: the backoff wait, or
    /// what the server named when that is later — `retry-after` for the
    /// secondary limit, `x-ratelimit-reset` for the primary one. The
    /// server's wait is capped at `maxBackoffWait` so a hostile value can't
    /// park polling for days; that cap is also the backoff's own.
    static func retryAt(now: Date, serverRetryAt: Date?, base: Int, backoff: Int) -> Date {
        let serverWait = serverRetryAt.map { secondsUntil($0, now: now) } ?? 0
        return now.addingTimeInterval(TimeInterval(max(nextWait(base: base, backoff: backoff), serverWait)))
    }

    /// When the popover's 새로고침 may go out again after a rate-limited
    /// answer: the time the server named, or the backoff's `retryAt` when
    /// it named none. Not the automatic wait's max of the two — that held a
    /// `retry-after: 30` behind a backoff of up to `maxBackoffWait` (#154).
    /// Capped like `retryAt`, so a hostile value parks it no longer.
    static func manualRetryAt(now: Date, serverRetryAt: Date?, retryAt: Date) -> Date {
        guard let serverRetryAt else { return retryAt }
        return now.addingTimeInterval(TimeInterval(secondsUntil(serverRetryAt, now: now)))
    }

    /// nil when the popover's manual refresh may go out now; otherwise when
    /// it may: while rate-limited, not before `manualRetryAt` (or `retryAt`
    /// when the state carries none).
    static func manualRefreshBlocked(until state: GitHubLoadState, now: Date) -> Date? {
        guard case .rateLimited(let retryAt, let manualRetryAt) = state else { return nil }
        let until = manualRetryAt ?? retryAt
        return now < until ? until : nil
    }

    /// Whole seconds from `now` to `date`, rounded up so a wait never ends
    /// short of it, and kept within 0…`maxBackoffWait` — which also keeps
    /// the conversion from trapping on an absurd date.
    private static func secondsUntil(_ date: Date, now: Date) -> Int {
        let seconds = date.timeIntervalSince(now).rounded(.up)
        return Int(min(max(seconds, 0), TimeInterval(maxBackoffWait)))
    }

    /// Whether a failed request backs off as a rate limit does. A 403 or
    /// 429 without any rate-limit header (`interpret` throws `.http` for
    /// it) may still be GitHub's secondary limit, whose guidance is to wait
    /// at least a minute and then back off exponentially — retrying at base
    /// would keep hitting it. The state stays the plain error: no header
    /// says it was the limit, and a 403 can be a refusal as well.
    static func backsOff(after error: GitHubAPIError) -> Bool {
        switch error {
        case .http(403), .http(429): return true
        default: return false
        }
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
