import SwiftUI

// The PR judgements the GitHub region shows (Decision #45 (e)): one badge per
// row, the menu-bar count and dot, the hover lines, and how check chips fold.
// Pure values — `GitHubModel` hands the parsed snapshot in and shows what
// comes out; the rules are pinned by `scripts/test.sh`.

/// One vocabulary for both kinds of check GitHub reports (CheckRun and the
/// older StatusContext). `GitHubAPIClient` does the mapping.
enum PRCheckOutcome: Equatable, Sendable {
    case passed, failed, running, queued, skipped

    /// Still going — a running chip ticks, a PR with one is "검사 진행중".
    var isPending: Bool { self == .running || self == .queued }
}

struct PRCheck: Equatable, Sendable {
    let name: String
    let outcome: PRCheckOutcome
    /// CheckRuns carry both; a StatusContext carries neither, so its chip
    /// shows no time.
    let startedAt: Date?
    let completedAt: Date?
    let url: URL?
}

/// `mergeable` as GitHub reports it. `.unknown` is also what an unfamiliar
/// value becomes: a conflict is only ever claimed when GitHub said so.
enum PRMergeable: Equatable, Sendable {
    case mergeable, conflicting, unknown
}

/// `mergeStateStatus` — GitHub's own verdict on whether the merge button is
/// green, folding branch protection, required checks and required reviews
/// together. `.unknown` is also what an unfamiliar or missing value becomes:
/// it sends the verdict back to the older approved + checks + mergeable rule.
enum PRMergeState: Equatable, Sendable {
    case clean, blocked, behind, dirty, draft, hasHooks, unstable, unknown
}

enum PRReviewDecision: Equatable, Sendable {
    case approved, changesRequested, reviewRequired
    /// null (no review rules), or a value we don't know.
    case none
}

/// `statusCheckRollup.state`, GitHub's own aggregate. It counts every run on
/// the commit, a cancelled re-run included, so the badge only falls back to
/// it when the chips don't cover the whole list (`effectiveChecks`).
enum PRChecksRollup: Equatable, Sendable {
    case success, failure, pending
    /// No rollup: the repo runs no checks.
    case none
}

/// `latestStatus.state` of one deployment, folded to what the deploy watch
/// (#167) tells apart. `.unknown` is also what an unfamiliar value becomes.
enum PRDeploymentState: Equatable, Sendable {
    /// PENDING, QUEUED, IN_PROGRESS, WAITING.
    case waiting
    /// SUCCESS, or INACTIVE — a deployment that was live until a newer one
    /// took over.
    case finished
    /// FAILURE, ERROR.
    case failed
    case unknown
}

/// One GitHub Deployment of a merged PR's merge commit (#167). Only
/// deployments that came back with an environment, a creation time and a
/// latest status are kept — a partial one says nothing the watch can use.
struct PRDeployment: Equatable, Sendable {
    /// The raw environment name ("Production", "sellcaddie / production"):
    /// part of the key, never shown.
    let environment: String
    let createdAt: Date
    let state: PRDeploymentState
}

struct GitHubPullRequest: Equatable, Identifiable, Sendable {
    /// "owner/name".
    let repository: String
    let number: Int
    let title: String
    let url: URL?
    let isDraft: Bool
    let reviewDecision: PRReviewDecision
    let mergeable: PRMergeable
    let mergeState: PRMergeState
    let checksRollup: PRChecksRollup
    /// One chip per check — the latest run of each workflow job or status
    /// context (`GitHubAPIClient` drops the re-run ones).
    let checks: [PRCheck]
    /// Every context GitHub has was read (none past the thirty requested,
    /// none of a kind we skip), so `checks` speaks for the whole PR.
    let checksListComplete: Bool
    let updatedAt: Date?
    let mergedAt: Date?
    /// GraphQL node id — what `mergePullRequest` takes. nil when the response
    /// didn't carry one; such a PR is never offered a merge.
    let nodeID: String?
    /// `headRefOid`, the commit the row shows. A merge is sent with it as
    /// `expectedHeadOid` so GitHub refuses one whose head moved meanwhile.
    let headSHA: String?
    /// The merge commit's latest deployments, oldest first as GitHub lists
    /// them (#167). Empty for an open PR (no merge commit) and for a
    /// repository that doesn't deploy through GitHub Deployments.
    var deployments: [PRDeployment] = []

    var id: String { url?.absoluteString ?? "\(repository)#\(number)" }

    /// The "name" of "owner/name" — what the menu bar and hover have room for.
    var repositoryName: String {
        repository.split(separator: "/").last.map(String.init) ?? repository
    }

    /// How the PR's checks stand, for the badge, the menu-bar count and the
    /// hover. From the chips when they are the whole list — the rollup still
    /// fails on a cancelled run that a later re-run replaced — and from the
    /// rollup when the list was cut short or is empty.
    var effectiveChecks: PRChecksRollup {
        guard checksListComplete, !checks.isEmpty else { return checksRollup }
        if checks.contains(where: { $0.outcome == .failed }) { return .failure }
        if checks.contains(where: { $0.outcome.isPending }) { return .pending }
        return .success
    }

    /// The first failed check chip, for the hover line.
    var firstFailedCheck: PRCheck? { checks.first { $0.outcome == .failed } }

    /// The PR's checks are pending (the same reading the badge uses), or a
    /// chip is still going — the row's "검사 진행중" badge.
    var checksPending: Bool {
        effectiveChecks == .pending || checks.contains { $0.outcome.isPending }
    }
}

// MARK: - Verdict

/// The one badge a row gets. Declaration order is priority order (mockup
/// § D): `min()` of several verdicts is the one that wins.
enum PRVerdict: Int, Comparable, Sendable {
    case conflict, checksFailed, changesRequested, draft, awaitingReview, approved, mergeable

    static func < (lhs: PRVerdict, rhs: PRVerdict) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Something the author must act on before the PR can move — what the
    /// menu-bar count and red dot are made of.
    var isBlocking: Bool { self <= .changesRequested }

    var label: String {
        switch self {
        case .conflict:         return "충돌"
        case .checksFailed:     return "검사 실패"
        case .changesRequested: return "변경 요청"
        case .draft:            return "Draft"
        case .awaitingReview:   return "리뷰 대기"
        case .approved:         return "승인"
        case .mergeable:        return "머지 가능"
        }
    }

    static func of(_ pr: GitHubPullRequest) -> PRVerdict {
        if pr.mergeable == .conflicting { return .conflict }
        let checks = pr.effectiveChecks
        if checks == .failure { return .checksFailed }
        if pr.reviewDecision == .changesRequested { return .changesRequested }
        if pr.isDraft { return .draft }
        let approved = pr.reviewDecision == .approved
        let checksClear = checks == .success || checks == .none
        switch pr.mergeState {
        case .clean:
            // GitHub's merge button is green. A repo with no review rules
            // never gets a reviewDecision, so approval can't be asked for.
            if checksClear { return .mergeable }
        case .unknown:
            // Without GitHub's verdict the chips are all there is, and a
            // required status that hasn't reported yet is not among them —
            // only the rollup's PENDING/EXPECTED says it is still owed.
            if approved && checksClear && pr.checksRollup != .pending
                && pr.mergeable == .mergeable { return .mergeable }
        default:
            break
        }
        return approved ? .approved : .awaitingReview
    }
}

/// The outlined badges after a row's verdict badge, in the order drawn.
enum PRSecondaryBadge: Equatable, Sendable {
    case checksPending
    /// Approved, while the verdict says something else — a verdict that
    /// already reads approved or mergeable doesn't say it twice.
    case approved

    static func of(_ pr: GitHubPullRequest, verdict: PRVerdict) -> [PRSecondaryBadge] {
        var badges: [PRSecondaryBadge] = []
        if pr.checksPending { badges.append(.checksPending) }
        if pr.reviewDecision == .approved, verdict != .approved, verdict != .mergeable {
            badges.append(.approved)
        }
        return badges
    }
}

// MARK: - Deploy watch (#167)

/// What a merged PR of mine shows in "내 PR" while its merge commit deploys,
/// or after that deploy failed. No status means the PR has left the list.
enum PRDeployStatus: Equatable, Sendable {
    case deploying, failed

    var label: String {
        switch self {
        case .deploying: return "배포중"
        case .failed:    return "배포 실패"
        }
    }

    /// A failed deploy is something to act on, as a failed check is — it
    /// counts toward the menu-bar number and turns the dot red.
    var isBlocking: Bool { self == .failed }
}

/// One merged PR the deploy watch keeps in "내 PR".
struct GitHubDeployRow: Equatable, Sendable {
    let pr: GitHubPullRequest
    let status: PRDeployStatus
}

/// Which of my merged PRs are still deploying or failed to (#167), from the
/// GitHub Deployments of their merge commits. Every deployment is read
/// against the others of its repository and environment across the whole
/// merged list, because a newer deploy of the same environment carries the
/// older change with it.
enum PRDeployWatch {
    private struct Key: Hashable {
        let repository: String
        let environment: String
    }

    /// By `GitHubPullRequest.id`. `now` is when the list was fetched: the
    /// windows are judged as of the answer, so the glance and the popover,
    /// which both read the same snapshot, can't part.
    static func statuses(of merged: [GitHubPullRequest], now: Date) -> [String: PRDeployStatus] {
        var byKey: [Key: [PRDeployment]] = [:]
        var deployingRepos: Set<String> = []
        for pr in merged where !pr.deployments.isEmpty {
            deployingRepos.insert(pr.repository.lowercased())
            for deployment in pr.deployments {
                byKey[key(pr, deployment), default: []].append(deployment)
            }
        }
        var out: [String: PRDeployStatus] = [:]
        for pr in merged {
            if let status = status(of: pr, byKey: byKey, deployingRepos: deployingRepos, now: now) {
                out[pr.id] = status
            }
        }
        return out
    }

    /// Deploying wins over failed across the PR's environments: something
    /// is still on its way, and the 30-second cadence follows it.
    private static func status(of pr: GitHubPullRequest, byKey: [Key: [PRDeployment]],
                               deployingRepos: Set<String>, now: Date) -> PRDeployStatus? {
        if pr.deployments.isEmpty {
            // The deployment lands seconds after the merge; until it does, a
            // repository seen deploying is taken to deploy this one too, so
            // the row doesn't drop out and come back on the next poll.
            guard let mergedAt = pr.mergedAt, deployingRepos.contains(pr.repository.lowercased()),
                  isWithin(mergedAt, Config.githubDeployPendingGrace, of: now) else { return nil }
            return .deploying
        }
        var failed = false
        for deployment in pr.deployments {
            let others = byKey[key(pr, deployment)] ?? []
            let newer = others.filter { $0.createdAt > deployment.createdAt }
            // A newer deploy of the same environment that went live has this
            // change in it — whatever this one's own state was left at.
            if newer.contains(where: { $0.state == .finished }) { continue }
            switch deployment.state {
            case .waiting:
                // Past the cap a wait is no longer believed: one stuck for
                // days would hold the row and the fast cadence forever.
                if isWithin(deployment.createdAt, Config.githubDeployMaxWaitingAge, of: now) {
                    return .deploying
                }
            case .failed:
                // Only the environment's latest word: a newer attempt that
                // failed itself, or is still believably going, speaks for it
                // instead. A newer wait past the cap or a state we don't
                // know does not — a retry stuck in IN_PROGRESS (sellcaddie#976)
                // would otherwise take this row down with it after an hour,
                // and nothing would say production never got the change.
                if !newer.contains(where: { speaksOverFailure($0, now: now) }),
                   let mergedAt = pr.mergedAt,
                   isWithin(mergedAt, Config.githubDeployFailureWindow, of: now) {
                    failed = true
                }
            case .finished:
                break
            case .unknown:
                // Not read as waiting: a state we don't know might never
                // change, and would hold the 30-second cadence for an hour
                // on every merge. Not read as failed either — nothing says
                // it did. The row leaves, as a finished deploy's does.
                break
            }
        }
        return failed ? .failed : nil
    }

    /// A newer deployment of the same environment that hides an older
    /// failure: finished, failed, or waiting within the cap.
    private static func speaksOverFailure(_ newer: PRDeployment, now: Date) -> Bool {
        switch newer.state {
        case .finished, .failed: return true
        case .waiting:           return isWithin(newer.createdAt, Config.githubDeployMaxWaitingAge, of: now)
        case .unknown:           return false
        }
    }

    private static func key(_ pr: GitHubPullRequest, _ deployment: PRDeployment) -> Key {
        Key(repository: pr.repository.lowercased(), environment: deployment.environment)
    }

    /// `date` lies within `limit` before `now` — or up to the clock-skew
    /// allowance after it, as for a check's start.
    private static func isWithin(_ date: Date, _ limit: TimeInterval, of now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return age >= -Config.githubFastPollClockSkew && age <= limit
    }
}

// MARK: - Check chips

/// The checks line of a row: folded to one chip when everything passed,
/// spread out when anything needs looking at.
enum ChecksLine: Equatable, Sendable {
    case none
    /// "검사 N개 통과" with the wall time from the earliest start to the latest
    /// finish — nil when any check lacks a time (a StatusContext has none).
    case collapsed(passedCount: Int, total: TimeInterval?, skipped: [PRCheck])
    case expanded([PRCheck])

    static func fold(_ checks: [PRCheck]) -> ChecksLine {
        if checks.isEmpty { return .none }
        if checks.contains(where: { $0.outcome != .passed && $0.outcome != .skipped }) {
            return .expanded(checks)
        }
        let starts = checks.compactMap(\.startedAt)
        let ends = checks.compactMap(\.completedAt)
        var total: TimeInterval?
        if starts.count == checks.count, ends.count == checks.count,
           let first = starts.min(), let last = ends.max() {
            total = max(0, last.timeIntervalSince(first))
        }
        return .collapsed(passedCount: checks.filter { $0.outcome == .passed }.count,
                          total: total,
                          skipped: checks.filter { $0.outcome == .skipped })
    }
}

// MARK: - Glance (menu bar + hover)

enum GitHubDot: Equatable, Sendable {
    case green, amber, red, grey

    var color: Color {
        switch self {
        case .green: return Palette.green
        case .amber: return Palette.amber
        case .red:   return Palette.red
        case .grey:  return Palette.textTertiary
        }
    }
}

/// The hover's CI row (#51): how the checks on my PRs stand. A PR is read
/// by its `effectiveChecks`, as its badge is — one whose checks already
/// failed counts as failed even while another of its checks still runs.
enum GitHubCILine: Equatable, Sendable {
    /// `prs` of my PRs still have checks going. `subject` names the running
    /// check that started first across all of them — "growdle #121 Vercel" —
    /// and `since` is its start; nil when no running check carries one.
    case running(prs: Int, subject: String, since: Date?)
    /// Checks going, none of them running yet: the first queued one of the
    /// first such PR.
    case queued(prs: Int, subject: String)
    /// Nothing going, `prs` failed. `rest` is "#45 build 실패".
    case failed(prs: Int, rest: String)
    case allPassed
    /// None of my PRs has a check.
    case noChecks

    static func of(_ mine: [GitHubPullRequest]) -> GitHubCILine {
        let going = mine.filter { $0.effectiveChecks == .pending }
        if let firstGoing = going.first {
            let running = going.flatMap { pr in
                pr.checks.filter { $0.outcome == .running }.map { (pr: pr, check: $0) }
            }
            // Ties and untimed runs keep list order: `min(by:)` keeps the first.
            let timed = running.compactMap { run in run.check.startedAt.map { (run: run, start: $0) } }
            if let lead = timed.min(by: { $0.start < $1.start })?.run ?? running.first {
                return .running(prs: going.count, subject: subject(lead.pr, lead.check.name),
                                since: lead.check.startedAt)
            }
            for pr in going {
                if let queued = pr.checks.first(where: { $0.outcome == .queued }) {
                    return .queued(prs: going.count, subject: subject(pr, queued.name))
                }
            }
            // Pending by the rollup alone (the chips were cut short): no
            // check to name.
            return .running(prs: going.count, subject: subject(firstGoing, "검사"), since: nil)
        }
        let failed = mine.filter { $0.effectiveChecks == .failure }
        if let first = failed.first {
            let name = first.firstFailedCheck?.name ?? "검사"
            return .failed(prs: failed.count, rest: "#\(first.number) \(name) 실패")
        }
        if mine.contains(where: { $0.effectiveChecks != PRChecksRollup.none }) { return .allPassed }
        return .noChecks
    }

    private static func subject(_ pr: GitHubPullRequest, _ check: String) -> String {
        "\(pr.repositoryName) #\(pr.number) \(check)"
    }

    /// The count after "CI"; nil when the row says it in words.
    var number: Int? {
        switch self {
        case .running(let prs, _, _), .queued(let prs, _), .failed(let prs, _): return prs
        case .allPassed, .noChecks: return nil
        }
    }

    /// The count's color: amber while checks run, red once they failed.
    var tone: GitHubDot? {
        switch self {
        case .running, .queued: return .amber
        case .failed:           return .red
        case .allPassed, .noChecks: return nil
        }
    }

    var isGoing: Bool {
        switch self {
        case .running, .queued: return true
        case .failed, .allPassed, .noChecks: return false
        }
    }

    /// Where the elapsed time counts from. Only then does the hover tick.
    var runningSince: Date? {
        if case .running(_, _, let since) = self { return since }
        return nil
    }

    /// The text after the count, the elapsed time read against `now` — the
    /// hover's clock, frozen for the snapshot renderer. Formatted as the
    /// popover's running chip is.
    func rest(now: Date) -> String {
        switch self {
        case .running(_, let subject, let since?):
            return "\(subject) \(TimeText.duration(Int(now.timeIntervalSince(since))))…"
        case .running(_, let subject, nil): return "\(subject) 진행중"
        case .queued(_, let subject):        return "\(subject) 대기"
        case .failed(_, let rest):           return rest
        case .allPassed:                     return "모두 통과"
        case .noChecks:                      return "없음"
        }
    }
}

/// What the menu-bar region and its hover show. Hidden repositories are
/// removed before anything is counted.
struct GitHubGlance: Equatable, Sendable {
    /// The hover rows, as parts: the hover view colors the numbers and
    /// greys the rest, so they are not pre-joined into one string.
    struct Lines: Equatable, Sendable {
        let ci: GitHubCILine
        let mine: Int
        let blocked: Int
        /// After the my-PR count: "막힘 1 · #45 build 실패".
        let mineRest: String
        /// My PR rows the popover draws with a merge button right now
        /// (Decision #52) — rows past the section cap have none.
        let mergeable: Int
        /// After the mergeable count: "bookdam #57 외 1", or empty.
        let mergeableRest: String
        /// My merged PRs still deploying (#167); the row is left out at 0.
        var deploying: Int = 0
        /// After the deploying count: "sellcaddie #985 외 1", or empty.
        var deployingRest: String = ""
    }

    /// My PRs that are blocked — a failed deploy among them (#167).
    let count: Int
    let dot: GitHubDot
    /// nil when no snapshot speaks for the region (token missing, refused,
    /// first load…) — the hover then shows `stateLabel` on its own.
    let lines: Lines?
    let stateLabel: String

    static let empty = GitHubGlance(count: 0, dot: .grey, lines: nil, stateLabel: "")

    /// Whether one of my PRs can be merged from the popover now — what turns
    /// the menu-bar glyph into the green merge arrow. False without lines.
    var hasMergeable: Bool { (lines?.mergeable ?? 0) > 0 }

    /// "CI 1 · growdle #121 Vercel 2m 05s…" / "CI 모두 통과", or the state
    /// label without lines.
    func hoverCILine(now: Date) -> String {
        guard let lines else { return stateLabel }
        let rest = lines.ci.rest(now: now)
        return lines.ci.number.map { "CI \($0) · \(rest)" } ?? "CI \(rest)"
    }

    /// "내 PR 4 · 막힘 1 · #45 build 실패", or empty without lines.
    var hoverMineLine: String {
        guard let lines else { return "" }
        return "내 PR \(lines.mine) · \(lines.mineRest)"
    }

    /// "배포 2 · sellcaddie #985 외 1", or empty when nothing deploys (#167) —
    /// the hover then leaves the row out.
    var hoverDeployLine: String {
        guard let lines, lines.deploying > 0 else { return "" }
        return "배포 \(lines.deploying) · \(lines.deployingRest)"
    }

    /// "머지 가능 2 · bookdam #57 외 1", "머지 가능 0", or empty without lines.
    var hoverMergeableLine: String {
        guard let lines else { return "" }
        return "머지 가능 \(lines.mergeable)" + (lines.mergeableRest.isEmpty ? "" : " · \(lines.mergeableRest)")
    }

    /// A snapshot is only read for `.loaded`, and for `.loading` /
    /// `.rateLimited` when one was kept from before; every other state is a
    /// grey dot with its own hover label, whatever snapshot is lying around.
    /// `mergeActivity` is the model's per-PR merge state: a merge already
    /// out or done takes its PR out of the mergeable count.
    static func of(_ snapshot: GitHubSnapshot?, state: GitHubLoadState, hidden: Set<String>,
                   mergeActivity: [String: PRMergeActivity]) -> GitHubGlance {
        switch state {
        case .loaded:
            return snapshot.map { of($0.hiding(hidden), mergeActivity: mergeActivity) } ?? .empty
        case .loading, .rateLimited:
            if let snapshot { return of(snapshot.hiding(hidden), mergeActivity: mergeActivity) }
            return GitHubGlance(count: 0, dot: .grey, lines: nil, stateLabel: state.hoverLabel)
        case .off, .noToken, .keychainDenied, .unauthorized, .patSaveFailed, .error:
            return GitHubGlance(count: 0, dot: .grey, lines: nil, stateLabel: state.hoverLabel)
        }
    }

    private static func of(_ s: GitHubSnapshot, mergeActivity: [String: PRMergeActivity]) -> GitHubGlance {
        // The open PRs' reasons first, then the failed deploys, in the
        // order the popover lists them.
        let deployRows = s.deployRows
        let blockedReasons = s.mine.filter { PRVerdict.of($0).isBlocking }.map(blockedReason)
            + deployRows.filter { $0.status.isBlocking }.map { "#\($0.pr.number) \($0.status.label)" }
        let deploying = deployRows.filter { $0.status == .deploying }.map(\.pr)
        let ci = GitHubCILine.of(s.mine)
        // A deploy on its way is amber as a running check is: nothing to do,
        // something still moving.
        let dot: GitHubDot = !blockedReasons.isEmpty ? .red
            : (ci.isGoing || !deploying.isEmpty ? .amber : .green)

        var mineRest = "막힘 \(blockedReasons.count)"
        if let first = blockedReasons.first {
            mineRest += " · " + first
        }
        // Only the rows the popover draws (the rest fold into "외 N건" with
        // no button), so the glyph never says yes to a merge the popover
        // can't offer.
        let mergeable = s.mine.prefix(Config.githubSectionCaps.mine)
            .filter { isMergeableNow($0, activity: mergeActivity[$0.id]) }
        var mergeableRest = ""
        if let first = mergeable.first {
            mergeableRest = "\(first.repositoryName) #\(first.number)"
            if mergeable.count > 1 { mergeableRest += " 외 \(mergeable.count - 1)" }
        }
        var deployingRest = ""
        if let first = deploying.first {
            deployingRest = "\(first.repositoryName) #\(first.number)"
            if deploying.count > 1 { deployingRest += " 외 \(deploying.count - 1)" }
        }
        let lines = Lines(ci: ci, mine: s.mine.count + deployRows.count, blocked: blockedReasons.count,
                          mineRest: mineRest, mergeable: mergeable.count, mergeableRest: mergeableRest,
                          deploying: deploying.count, deployingRest: deployingRest)
        return GitHubGlance(count: blockedReasons.count, dot: dot, lines: lines, stateLabel: "")
    }

    /// The popover's merge button would be drawn on its row (Decision #52): the
    /// same `canOffer`, minus a merge already out or done — search indexes
    /// a merged PR late, and until then it would read as one still to merge.
    /// A failed attempt still counts: the button is offered again.
    private static func isMergeableNow(_ pr: GitHubPullRequest, activity: PRMergeActivity?) -> Bool {
        guard GitHubMergePolicy.canOffer(pr, section: .mine) else { return false }
        return activity != .merging && activity != .merged
    }

    /// "#45 build 실패" / "#45 충돌" / "#45 변경 요청". A rollup failure with no
    /// failed chip (the failure sits past the thirty contexts read) names
    /// the badge instead of a check.
    private static func blockedReason(_ pr: GitHubPullRequest) -> String {
        let verdict = PRVerdict.of(pr)
        switch verdict {
        case .checksFailed:
            if let check = pr.firstFailedCheck { return "#\(pr.number) \(check.name) 실패" }
            return "#\(pr.number) \(verdict.label)"
        default:
            return "#\(pr.number) \(verdict.label)"
        }
    }
}
