import Foundation

/// Why a GitHub request produced no answer. `detail` is what the banner
/// shows — never the token, never a response body.
enum GitHubAPIError: Error, Equatable, Sendable {
    case http(Int)
    case timedOut
    case offline
    /// Any other transport failure (DNS, TLS, refused, …).
    case network
    /// Not JSON, no `data`, or over the size cap.
    case badResponse
    /// Cancelled on our side (the poll loop was replaced) — not news.
    case cancelled

    var detail: String {
        switch self {
        case .http(let code): return "GitHub 응답 오류 (HTTP \(code))"
        case .timedOut:       return "응답 시간 초과"
        case .offline:        return "네트워크 연결 없음"
        case .network:        return "GitHub 에 연결할 수 없습니다"
        case .badResponse:    return "GitHub 응답을 읽을 수 없습니다"
        case .cancelled:      return "요청 취소됨"
        }
    }

    static func transport(_ code: URLError.Code) -> GitHubAPIError {
        switch code {
        case .cancelled: return .cancelled
        case .timedOut:  return .timedOut
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return .offline
        default:         return .network
        }
    }
}

/// What one request came back with. The caller tells these apart into a
/// banner (`unauthorized`), a backoff (`rateLimited`) or a snapshot.
enum GitHubFetchResult: Equatable, Sendable {
    case snapshot(GitHubSnapshot)
    /// 401 — the token was rejected.
    case unauthorized
    /// 403/429 with `retry-after`, a zero `x-ratelimit-remaining`, or a
    /// `RATE_LIMITED` GraphQL error. `retryAt` is GitHub's figure when it
    /// gave one.
    case rateLimited(retryAt: Date?)
}

/// What one merge request came back with (Decision #49). Never thrown: every
/// outcome is something the row says, and only `unauthorized` changes the
/// region's state.
enum GitHubMergeResult: Equatable, Sendable {
    /// GitHub reported the PR `MERGED`.
    case merged
    /// The head moved past the `expectedHeadOid` sent — nothing was merged.
    case headChanged
    /// GitHub refused the merge (conflict, branch protection, checks, …);
    /// its message, shortened to one line.
    case notMergeable(String)
    /// The token may read the PR but not merge it (`FORBIDDEN`, or a 403
    /// that isn't rate limiting).
    case forbidden
    /// 401 — the token was rejected.
    case unauthorized
    case rateLimited
    /// No usable answer: transport, 3xx/5xx, or a body that isn't one.
    case failed(GitHubAPIError)

    /// The line under the row; nil for a merge that went through. Never
    /// carries the token — GitHub's own message passes `mergeMessage` first.
    var failureReason: String? {
        switch self {
        case .merged:                 return nil
        case .headChanged:            return "그 사이 새 커밋이 올라와 머지하지 않았어요 — 갱신 후 다시"
        case .notMergeable(let why):  return "머지 불가 — \(why)"
        case .forbidden:              return "머지 권한이 없어요 — 토큰의 repo 권한 확인"
        case .unauthorized:           return "토큰이 거부되었어요 (401)"
        case .rateLimited:            return "API 한도 초과 — 잠시 후 다시"
        case .failed(let error):      return error.detail
        }
    }
}

/// GraphQL requests to `api.github.com`. The poll is one query (Decision #45
/// (d)): two searches and `rateLimit`, bundled because cost is per node,
/// not per request. The one write is `merge` — a squash merge of my own PR,
/// sent only after the user confirmed it (Decision #49). Either way the token
/// goes to this one host only: redirects are refused (`BoundedHTTP`).
struct GitHubAPIClient: Sendable {
    /// Two searches with check contexts take longer than a static file;
    /// past this the next poll will try again.
    static let requestTimeout: TimeInterval = 20

    private static let session = BoundedHTTP.makeSession(timeout: requestTimeout)

    // MARK: Query

    /// Each search returns up to this many PRs. Rows past the section caps
    /// become an "외 N건" line, and someone with more than twenty open PRs
    /// has a different problem.
    static let searchPageSize = 20
    /// Check contexts read per PR. Beyond this the chips are incomplete, and
    /// the badge falls back to `statusCheckRollup.state`, which covers all.
    static let contextsPageSize = 30

    /// The query text. `mergedSince` becomes `merged:>=YYYY-MM-DD` in the
    /// given calendar — GitHub's search dates are whole days.
    static func query(mergedSince: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: mergedSince)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        // `sort:updated-desc` makes "the first blocked PR" in the hover a
        // stable choice rather than search relevance.
        let searches = [
            ("mine", "is:pr is:open author:@me sort:updated-desc"),
            ("merged", "is:pr is:merged author:@me merged:>=\(day) sort:updated-desc"),
        ]
        let fields = searches.map { alias, search in
            "\(alias): search(query: \"\(search)\", type: ISSUE, first: \(searchPageSize)) { nodes { ...PR } }"
        }.joined(separator: "\n  ")
        return """
        query {
          \(fields)
          rateLimit { cost remaining limit resetAt }
        }
        fragment PR on PullRequest {
          __typename id number title url isDraft headRefOid reviewDecision mergeable mergeStateStatus updatedAt mergedAt
          repository { nameWithOwner }
          commits(last: 1) { nodes { commit { statusCheckRollup { state
            contexts(first: \(contextsPageSize)) { totalCount nodes { __typename
              ... on CheckRun { name status conclusion startedAt completedAt detailsUrl
                checkSuite { workflowRun { workflow { name } } app { slug } } }
              ... on StatusContext { context state createdAt targetUrl } } } } } } }
        }
        """
    }

    // MARK: Merge mutation (Decision #49)

    /// Squash only, no branch deletion, and no commit headline or body — the
    /// repository's squash defaults apply. The ids travel as variables, never
    /// spliced into the text.
    static let mergeMutation = """
    mutation($pullRequestId: ID!, $expectedHeadOid: GitObjectID!) {
      mergePullRequest(input: { pullRequestId: $pullRequestId, mergeMethod: SQUASH, expectedHeadOid: $expectedHeadOid }) {
        pullRequest { number state mergedAt }
      }
    }
    """

    static func mergeRequestBody(pullRequestId: String, expectedHeadOid: String) -> [String: Any] {
        ["query": mergeMutation,
         "variables": ["pullRequestId": pullRequestId, "expectedHeadOid": expectedHeadOid]]
    }

    // MARK: Fetch

    func fetch(token: String, now: Date = Date()) async throws(GitHubAPIError) -> GitHubFetchResult {
        let mergedSince = now.addingTimeInterval(-Double(Config.githubMergedWindowDays) * 86_400)
        let reply = try await post(["query": Self.query(mergedSince: mergedSince)], token: token)
        return try Self.interpret(statusCode: reply.statusCode, headers: reply.headers,
                                  data: reply.data, now: now)
    }

    /// One squash merge of `pullRequestId`, refused by GitHub unless its head
    /// is still `expectedHeadOid`. Not retried — a merge is not repeated
    /// without the user asking again.
    func merge(pullRequestId: String, expectedHeadOid: String, token: String) async -> GitHubMergeResult {
        let reply: Reply
        do {
            reply = try await post(Self.mergeRequestBody(pullRequestId: pullRequestId,
                                                         expectedHeadOid: expectedHeadOid),
                                   token: token)
        } catch {
            return .failed(error)
        }
        return Self.interpretMerge(statusCode: reply.statusCode, headers: reply.headers, data: reply.data)
    }

    private struct Reply {
        let statusCode: Int
        let headers: [String: String]
        let data: Data
    }

    /// The one POST both requests make: same endpoint, headers and session.
    private func post(_ payload: [String: Any], token: String) async throws(GitHubAPIError) -> Reply {
        var req = URLRequest(url: Config.githubGraphQLURL)
        req.httpMethod = "POST"
        req.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(Config.githubUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { throw .badResponse }
        req.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await BoundedHTTP.download(
                req, session: Self.session, maxBytes: Config.githubMaxResponseBytes,
                readsBody: Self.readsBody(statusCode:))
        } catch is BoundedHTTP.ResponseTooLarge {
            throw .badResponse
        } catch let error as URLError {
            throw .transport(error.code)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .network
        }
        guard let http = response as? HTTPURLResponse else { throw .badResponse }
        return Reply(statusCode: http.statusCode, headers: Self.headers(of: http), data: data)
    }

    /// Only a 2xx carries a document; the error codes are judged on code and
    /// headers alone, so an error page can't trip the size cap.
    static func readsBody(statusCode: Int) -> Bool {
        (200..<300).contains(statusCode)
    }

    private static func headers(of http: HTTPURLResponse) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            out[String(describing: key)] = String(describing: value)
        }
        return out
    }

    // MARK: Interpret

    /// Status code + headers + body → result. Split from `fetch` so the
    /// rate-limit and scope reading is testable without a server. Header
    /// names match case-insensitively.
    ///
    /// Rate limiting is looked for before the data: a 2xx whose
    /// `x-ratelimit-remaining` is 0, or whose `errors` carry `RATE_LIMITED`,
    /// is a backoff even when `data` came along with it.
    static func interpret(statusCode: Int, headers: [String: String], data: Data,
                          now: Date) throws(GitHubAPIError) -> GitHubFetchResult {
        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        let resetAt = header("x-ratelimit-reset").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        let remaining = header("x-ratelimit-remaining").flatMap(Int.init)

        switch statusCode {
        case 401:
            return .unauthorized
        case 403, 429:
            if let after = header("retry-after").flatMap(Double.init) {
                return .rateLimited(retryAt: now.addingTimeInterval(after))
            }
            if remaining == 0 { return .rateLimited(retryAt: resetAt) }
            throw .http(statusCode)
        case 200..<300:
            if remaining == 0 { return .rateLimited(retryAt: resetAt) }
            let root = try jsonObject(data)
            if hasRateLimitedError(root) { return .rateLimited(retryAt: resetAt) }
            var snapshot = try parse(root: root, now: now)
            snapshot.tokenScopesLackRepo = header("x-oauth-scopes").map { !scopes($0).contains("repo") }
            return .snapshot(snapshot)
        default:
            throw .http(statusCode)
        }
    }

    /// Status code + headers + body of a merge → result. Rate limiting reads
    /// as for the poll; a `MERGED` state wins over anything else in the body —
    /// the merge happened. GitHub's error message is what the row shows, so
    /// it goes through `mergeMessage`.
    static func interpretMerge(statusCode: Int, headers: [String: String], data: Data) -> GitHubMergeResult {
        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        let rateLimitHeaders = header("retry-after") != nil || header("x-ratelimit-remaining").flatMap(Int.init) == 0

        switch statusCode {
        case 401:
            return .unauthorized
        case 429:
            return .rateLimited
        case 403:
            return rateLimitHeaders ? .rateLimited : .forbidden
        case 200..<300:
            guard let root = try? jsonObject(data) else { return .failed(.badResponse) }
            let pullRequest = ((root["data"] as? [String: Any])?["mergePullRequest"]
                               as? [String: Any])?["pullRequest"] as? [String: Any]
            let state = pullRequest?["state"] as? String
            if state == "MERGED" { return .merged }
            let errors = root["errors"] as? [[String: Any]] ?? []
            if rateLimitHeaders || hasRateLimitedError(root) { return .rateLimited }
            if errors.contains(where: { $0["type"] as? String == "FORBIDDEN" }) { return .forbidden }
            if let message = errors.lazy.compactMap({ $0["message"] as? String }).first(where: { !$0.isEmpty }) {
                return isHeadChanged(message) ? .headChanged : .notMergeable(mergeMessage(message))
            }
            // An answer without errors that still isn't MERGED (a queue, a
            // state we don't know) is not a merge.
            if pullRequest != nil {
                return .notMergeable(mergeMessage("GitHub 이 머지하지 않았어요 (\(state ?? "상태 없음"))"))
            }
            return .failed(.badResponse)
        default:
            return .failed(.http(statusCode))
        }
    }

    /// GitHub words a moved head as "Head branch was modified…". Only that:
    /// other errors that name the input (a malformed `expectedHeadOid`) are
    /// not a moved head, and stay GitHub's own message.
    private static func isHeadChanged(_ message: String) -> Bool {
        message.lowercased().contains("head branch was modified")
    }

    /// The one line under a row: whitespace folded, anything shaped like a
    /// GitHub token masked, cut to `mergeMessageMaxLength`. GitHub has no
    /// reason to echo a token, but the row is not where to find out.
    static func mergeMessage(_ raw: String) -> String {
        let oneLine = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let masked = oneLine.replacingOccurrences(of: tokenPattern, with: "•••", options: .regularExpression)
        guard masked.count > mergeMessageMaxLength else { return masked }
        return String(masked.prefix(mergeMessageMaxLength)) + "…"
    }

    /// Classic and OAuth tokens (`ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`) and
    /// fine-grained PATs (`github_pat_`).
    private static let tokenPattern = #"(gh[pousr]_|github_pat_)[A-Za-z0-9_]+"#
    /// The row truncates sooner; the full line sits in its tooltip.
    static let mergeMessageMaxLength = 120

    /// `x-oauth-scopes: repo, read:org` → ["repo", "read:org"]. Only a classic
    /// PAT sends it; `repo` must be the whole scope — `public_repo` isn't it.
    private static func scopes(_ header: String) -> Set<String> {
        Set(header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    private static func hasRateLimitedError(_ root: [String: Any]) -> Bool {
        guard let errors = root["errors"] as? [[String: Any]] else { return false }
        return errors.contains { $0["type"] as? String == "RATE_LIMITED" }
    }

    // MARK: Tolerant decoding

    /// The response body → snapshot. Lenient per alias: a search that's
    /// missing leaves its list empty while the others fill; a node that
    /// isn't a `PullRequest`, or lacks a number or repository, is skipped;
    /// no `rateLimit` → nil. What must exist is `data` itself — a body
    /// without it is a failed request, not an empty one.
    static func parse(_ data: Data, now: Date) throws(GitHubAPIError) -> GitHubSnapshot {
        try parse(root: try jsonObject(data), now: now)
    }

    private static func jsonObject(_ data: Data) throws(GitHubAPIError) -> [String: Any] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw .badResponse
        }
        return root
    }

    private static func parse(root: [String: Any], now: Date) throws(GitHubAPIError) -> GitHubSnapshot {
        guard let data = root["data"] as? [String: Any] else { throw .badResponse }
        return GitHubSnapshot(
            mine: pullRequests(data["mine"]),
            recentlyMerged: pullRequests(data["merged"]),
            rateLimit: rateLimit(data["rateLimit"]),
            fetchedAt: now,
            tokenScopesLackRepo: nil
        )
    }

    private static func rateLimit(_ any: Any?) -> GitHubRateLimit? {
        guard let dict = any as? [String: Any],
              let cost = int(dict["cost"]), let remaining = int(dict["remaining"]),
              let limit = int(dict["limit"]) else { return nil }
        return GitHubRateLimit(cost: cost, remaining: remaining, limit: limit,
                               resetAt: isoDate(dict["resetAt"]))
    }

    private static func pullRequests(_ any: Any?) -> [GitHubPullRequest] {
        guard let nodes = (any as? [String: Any])?["nodes"] as? [Any] else { return [] }
        return nodes.compactMap { pullRequest($0 as? [String: Any]) }
    }

    private static func pullRequest(_ node: [String: Any]?) -> GitHubPullRequest? {
        guard let node, node["__typename"] as? String == "PullRequest",
              let number = int(node["number"]),
              let repository = (node["repository"] as? [String: Any])?["nameWithOwner"] as? String
        else { return nil }
        let rollup = ((((node["commits"] as? [String: Any])?["nodes"] as? [Any])?.first
                       as? [String: Any])?["commit"] as? [String: Any])?["statusCheckRollup"]
        let contexts = checks(rollup)
        return GitHubPullRequest(
            repository: repository,
            number: number,
            title: node["title"] as? String ?? "",
            url: pullRequestURL(node["url"]),
            isDraft: node["isDraft"] as? Bool ?? false,
            reviewDecision: reviewDecision(node["reviewDecision"]),
            mergeable: mergeable(node["mergeable"]),
            mergeState: mergeState(node["mergeStateStatus"]),
            checksRollup: checksRollup(rollup),
            checks: latestRuns(contexts.runs),
            checksListComplete: contexts.complete,
            updatedAt: isoDate(node["updatedAt"]),
            mergedAt: isoDate(node["mergedAt"]),
            nodeID: nonEmptyString(node["id"]),
            headSHA: nonEmptyString(node["headRefOid"])
        )
    }

    /// null and anything unfamiliar are `.none` — neither is "approved".
    private static func reviewDecision(_ any: Any?) -> PRReviewDecision {
        switch any as? String {
        case "APPROVED":          return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        case "REVIEW_REQUIRED":   return .reviewRequired
        default:                  return .none
        }
    }

    /// A conflict is claimed only on GitHub's word; `UNKNOWN` (still
    /// computing) and anything unfamiliar are `.unknown`.
    private static func mergeable(_ any: Any?) -> PRMergeable {
        switch any as? String {
        case "MERGEABLE":   return .mergeable
        case "CONFLICTING": return .conflicting
        default:            return .unknown
        }
    }

    /// Missing (an older server) and unfamiliar values are `.unknown`, which
    /// falls back to the approved + checks + mergeable rule — never `.clean`.
    private static func mergeState(_ any: Any?) -> PRMergeState {
        switch any as? String {
        case "CLEAN":     return .clean
        case "BLOCKED":   return .blocked
        case "BEHIND":    return .behind
        case "DIRTY":     return .dirty
        case "DRAFT":     return .draft
        case "HAS_HOOKS": return .hasHooks
        case "UNSTABLE":  return .unstable
        default:          return .unknown
        }
    }

    /// No rollup at all (null) means the repo runs no checks. A state we
    /// don't know is `.pending`: not provably passed.
    private static func checksRollup(_ any: Any?) -> PRChecksRollup {
        guard let dict = any as? [String: Any] else { return .none }
        switch dict["state"] as? String {
        case "SUCCESS":            return .success
        case "FAILURE", "ERROR":   return .failure
        default:                   return .pending
        }
    }

    /// Every context read, re-runs included, and whether that is all of them:
    /// GitHub's `totalCount` matches what we could read. A missing count, a
    /// page cut at thirty, or a node of a kind we skip each leave it
    /// incomplete — what we couldn't read might be the failing one.
    private static func checks(_ rollup: Any?) -> (runs: [CheckRunEntry], complete: Bool) {
        guard let contexts = (rollup as? [String: Any])?["contexts"] as? [String: Any],
              let nodes = contexts["nodes"] as? [Any]
        else { return ([], false) }
        let runs = nodes.compactMap { check($0 as? [String: Any]) }
        return (runs, int(contexts["totalCount"]) == runs.count)
    }

    /// What makes two runs the same check run again. A CheckRun's `name` is
    /// only the job's, and two workflows on one commit can each have a
    /// `build`, so the workflow (else the app) is part of it. A StatusContext's
    /// `context` is already its whole identity.
    enum RerunKey: Hashable, Sendable {
        case checkRun(suite: String, name: String)
        case status(context: String)
    }

    /// One parsed context and its re-run key — nil when a CheckRun names
    /// neither workflow nor app: it can't be told apart from another job of
    /// the same name, so it is never merged with one.
    typealias CheckRunEntry = (key: RerunKey?, check: PRCheck)

    /// A re-run adds a run under the same key instead of replacing the old
    /// one, so the list holds both. Keeps one per key — the latest
    /// (`isEarlier`), the one later in the response on a tie. Survivors keep
    /// their original order.
    static func latestRuns(_ runs: [CheckRunEntry]) -> [PRCheck] {
        var winner: [RerunKey: Int] = [:]
        for (index, run) in runs.enumerated() {
            guard let key = run.key else { continue }
            guard let held = winner[key] else { winner[key] = index; continue }
            if !isEarlier(run.check, than: runs[held].check) { winner[key] = index }
        }
        let kept = Set(winner.values)
        return runs.indices.filter { runs[$0].key == nil || kept.contains($0) }.map { runs[$0].check }
    }

    /// Strictly earlier by run time — `startedAt`, else `completedAt`. A run
    /// with neither hasn't started yet, so it is the newest: later than any
    /// run with a time. That keeps the order total, so which run survives
    /// doesn't depend on the order GitHub lists them in.
    private static func isEarlier(_ a: PRCheck, than b: PRCheck) -> Bool {
        switch (a.startedAt ?? a.completedAt, b.startedAt ?? b.completedAt) {
        case let (ta?, tb?): return ta < tb
        case (.some, nil):   return true
        case (nil, _):       return false
        }
    }

    private static func check(_ node: [String: Any]?) -> CheckRunEntry? {
        guard let node else { return nil }
        switch node["__typename"] as? String {
        case "CheckRun":
            let name = node["name"] as? String ?? ""
            let run = PRCheck(name: name,
                              outcome: checkRunOutcome(status: node["status"] as? String,
                                                       conclusion: node["conclusion"] as? String),
                              startedAt: isoDate(node["startedAt"]),
                              completedAt: isoDate(node["completedAt"]),
                              url: httpsURL(node["detailsUrl"]))
            return (checkSuiteName(node["checkSuite"]).map { .checkRun(suite: $0, name: name) }, run)
        case "StatusContext":
            // Commit statuses carry a creation time only — no duration.
            let context = node["context"] as? String ?? ""
            let status = PRCheck(name: context,
                                 outcome: statusContextOutcome(state: node["state"] as? String),
                                 startedAt: nil, completedAt: nil,
                                 url: httpsURL(node["targetUrl"]))
            return (.status(context: context), status)
        default:
            return nil
        }
    }

    /// The workflow's name for an Actions run, else the app's slug for any
    /// other app's run; nil (or empty) when neither came back.
    private static func checkSuiteName(_ any: Any?) -> String? {
        let suite = any as? [String: Any]
        let workflow = ((suite?["workflowRun"] as? [String: Any])?["workflow"] as? [String: Any])?["name"] as? String
        let app = (suite?["app"] as? [String: Any])?["slug"] as? String
        return [workflow, app].lazy.compactMap { $0 }.first { !$0.isEmpty }
    }

    // MARK: Check vocabulary

    /// CheckRun `status` + `conclusion` → one outcome. Unfamiliar values never
    /// become `.passed`: an unknown `status` is still going (`.queued`), and a
    /// completed run with an unknown `conclusion` is shown as `.failed` — a
    /// red chip the user can look at, rather than a spinner that would keep
    /// the popover on the fast cadence forever.
    static func checkRunOutcome(status: String?, conclusion: String?) -> PRCheckOutcome {
        switch status {
        case "COMPLETED":
            switch conclusion {
            case "SUCCESS":            return .passed
            case "NEUTRAL", "SKIPPED": return .skipped
            default:                   return .failed
            }
        case "IN_PROGRESS":
            return .running
        default:
            // QUEUED, WAITING, PENDING, REQUESTED, and whatever comes next.
            return .queued
        }
    }

    /// StatusContext `state` → outcome. PENDING/EXPECTED and unknown values
    /// are `.queued`.
    static func statusContextOutcome(state: String?) -> PRCheckOutcome {
        switch state {
        case "SUCCESS":          return .passed
        case "FAILURE", "ERROR": return .failed
        default:                 return .queued
        }
    }

    // MARK: helpers

    /// The one gate for links that get opened: https only, so a response
    /// can't hand `NSWorkspace` a `javascript:`, a custom app scheme or a
    /// plain-http page. Check links are whatever the CI wrote, so this is
    /// all they get.
    private static func httpsURL(_ any: Any?) -> URL? {
        guard let s = any as? String, let url = URL(string: s),
              url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    /// A PR's own link is GitHub's — anything off `github.com` isn't one.
    private static func pullRequestURL(_ any: Any?) -> URL? {
        guard let url = httpsURL(any), url.host?.lowercased() == Self.pullRequestHost else { return nil }
        return url
    }

    private static let pullRequestHost = "github.com"

    /// JSONSerialization hands `true` back as an NSNumber worth 1 — a bool is
    /// not a count.
    private static func int(_ any: Any?) -> Int? {
        guard let number = any as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value < Double(Int32.max) else { return nil }
        return Int(value)
    }

    private static func nonEmptyString(_ any: Any?) -> String? {
        guard let s = any as? String, !s.isEmpty else { return nil }
        return s
    }

    private static func isoDate(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFrac.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
