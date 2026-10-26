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
    }

    /// My PRs that are blocked.
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
        let blocked = s.mine.filter { PRVerdict.of($0).isBlocking }
        let ci = GitHubCILine.of(s.mine)
        let dot: GitHubDot = !blocked.isEmpty ? .red : (ci.isGoing ? .amber : .green)

        var mineRest = "막힘 \(blocked.count)"
        if let first = blocked.first {
            mineRest += " · " + blockedReason(first)
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
        let lines = Lines(ci: ci, mine: s.mine.count, blocked: blocked.count, mineRest: mineRest,
                          mergeable: mergeable.count, mergeableRest: mergeableRest)
        return GitHubGlance(count: blocked.count, dot: dot, lines: lines, stateLabel: "")
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
