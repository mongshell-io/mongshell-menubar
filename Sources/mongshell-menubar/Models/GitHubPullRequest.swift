import SwiftUI

// The PR judgements the GitHub region shows (Decision #45 (e)): one badge per
// row, the menu-bar count and dot, the hover lines, and how check chips fold.
// Pure values — `GitHubModel` hands the parsed snapshot in and shows what
// comes out; the rules are pinned by `scripts/test.sh`.

/// One vocabulary for both kinds of check GitHub reports (CheckRun and the
/// older StatusContext). `GitHubAPIClient` does the mapping.
enum PRCheckOutcome: Equatable, Sendable {
    case passed, failed, running, queued, skipped

    /// Still going — what keeps the open popover on the fast cadence.
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
}

// MARK: - Verdict

/// The one badge a row gets. Declaration order is priority order (mockup
/// § D): `min()` of several verdicts is the one that wins.
enum PRVerdict: Int, Comparable, Sendable {
    case conflict, checksFailed, changesRequested, myReviewPending, draft, awaitingReview, approved, mergeable

    static func < (lhs: PRVerdict, rhs: PRVerdict) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Something the author must act on before the PR can move — what the
    /// menu-bar count and red dot are made of.
    var isBlocking: Bool { self <= .changesRequested }

    var label: String {
        switch self {
        case .conflict:         return "충돌"
        case .checksFailed:     return "검사 실패"
        case .changesRequested: return "변경 요청"
        case .myReviewPending:  return "내 리뷰 대기"
        case .draft:            return "Draft"
        case .awaitingReview:   return "리뷰 대기"
        case .approved:         return "승인"
        case .mergeable:        return "머지 가능"
        }
    }

    /// - reviewRequested: the PR came from the review-requested list — someone
    ///   else's PR waiting on me, which outranks its own draft state.
    static func of(_ pr: GitHubPullRequest, reviewRequested: Bool) -> PRVerdict {
        if pr.mergeable == .conflicting { return .conflict }
        let checks = pr.effectiveChecks
        if checks == .failure { return .checksFailed }
        if pr.reviewDecision == .changesRequested { return .changesRequested }
        if reviewRequested { return .myReviewPending }
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

// MARK: - Merge (Decision #49)

/// Which popover list a row sits in.
enum PRSection: Sendable {
    case reviewRequested, mine, merged
}

/// Where one PR's merge stands, as its row shows it. No entry means none
/// was asked for.
enum PRMergeActivity: Equatable, Sendable {
    case merging
    /// GitHub said `MERGED`. The list can still show the PR open for a
    /// moment — search is indexed after the fact — so the row says so
    /// instead of offering the merge again.
    case merged
    /// The line under the row, until the next successful refresh.
    case failed(String)
}

enum GitHubMergePolicy {
    /// The merge button is drawn — never greyed out — only on my own PR,
    /// when GitHub's own verdict is `CLEAN` (the one signal a solo repo has:
    /// no review rules, no `reviewDecision`), it isn't a draft, the
    /// response carried what the mutation needs, and its link survived the
    /// https · github.com filter — a PR whose URL was dropped is data we
    /// don't trust enough to offer an irreversible write on.
    static func canOffer(_ pr: GitHubPullRequest, section: PRSection) -> Bool {
        section == .mine && pr.mergeState == .clean && !pr.isDraft
            && pr.nodeID != nil && pr.headSHA != nil && pr.url != nil
    }

    /// The row's line when the list moved to a new head between drawing the
    /// row and the click: nothing was sent.
    static let headMovedReason = "그 사이 새 커밋이 올라왔어요 — 다시 확인해 주세요"

    /// The row's line when the token changed after the list on screen was
    /// fetched: nothing was sent, and the new token's list is on its way.
    static let listStaleReason = "토큰이 바뀌어 목록을 다시 받는 중이에요 — 받은 뒤 다시 눌러 주세요"

    /// Whether the region's state lets a merge go out: loaded, or loading /
    /// rate-limited on an earlier answer (the same states `GitHubGlance`
    /// reads a snapshot in). A rejected token, a failed PAT save, an error,
    /// no token, a refused Keychain or a region switched off sends nothing.
    /// The state alone doesn't say the list came from the token in use — a
    /// token swap leaves `.loaded` standing until the next answer — so
    /// `gate` also compares the list's generation with the current one.
    static func allowsMerge(in state: GitHubLoadState) -> Bool {
        switch state {
        case .loaded, .loading, .rateLimited: return true
        case .off, .noToken, .keychainDenied, .unauthorized, .patSaveFailed, .error: return false
        }
    }

    /// What the model does with a click on the merge button.
    enum Gate: Equatable, Sendable {
        case send(nodeID: String)
        /// The list now holds another head than the one the row showed.
        case headMoved
        /// The list was fetched before the token last changed, so it speaks
        /// for another token than the one the merge would go out with.
        case listStale
        /// Nothing to send and nothing to say: a merge already out or done,
        /// a stopped state, or a PR the list no longer offers a merge on.
        case ignore
    }

    /// Judged on the PR as `mine` holds it now — looked up by id, never the
    /// copy the row drew from — so the node id, the head and `canOffer` all
    /// come from the current list. `listGeneration` is the model's
    /// generation when that list arrived, `generation` its generation now.
    static func gate(id: String, expectedHead: String, mine: [GitHubPullRequest]?,
                     listGeneration: Int, generation: Int,
                     state: GitHubLoadState, activity: PRMergeActivity?) -> Gate {
        guard allowsMerge(in: state), activity != .merging, activity != .merged,
              let current = mine?.first(where: { $0.id == id }),
              canOffer(current, section: .mine),
              let nodeID = current.nodeID else { return .ignore }
        guard listGeneration == generation else { return .listStale }
        guard current.headSHA == expectedHead else { return .headMoved }
        return .send(nodeID: nodeID)
    }

    /// What a successful refresh keeps: a merge still out, and a finished
    /// one whose PR the list still shows open. Failure lines end here — the
    /// list they were about has been replaced.
    static func carryOver(_ activity: [String: PRMergeActivity],
                          into mine: [GitHubPullRequest]) -> [String: PRMergeActivity] {
        let listed = Set(mine.map(\.id))
        return activity.filter { id, state in
            switch state {
            case .merging: return true
            case .merged:  return listed.contains(id)
            case .failed:  return false
            }
        }
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

/// What the menu-bar region and its hover show. Hidden repositories are
/// removed before anything is counted.
struct GitHubGlance: Equatable, Sendable {
    /// The two hover rows, as parts: the hover view colors the numbers and
    /// greys the rest, so they are not pre-joined into one string.
    struct Lines: Equatable, Sendable {
        let reviewRequested: Int
        let mine: Int
        let blocked: Int
        /// After the review-requested count: "bookdam #58 외 1", or empty.
        let line1Rest: String
        /// After the my-PR count: "막힘 1 · #45 build 실패".
        let line2Rest: String
    }

    /// Review requests + my PRs that are blocked.
    let count: Int
    let dot: GitHubDot
    /// nil when no snapshot speaks for the region (token missing, refused,
    /// first load…) — the hover then shows `stateLabel` on its own.
    let lines: Lines?
    let stateLabel: String

    static let empty = GitHubGlance(count: 0, dot: .grey, lines: nil, stateLabel: "")

    /// "리뷰 요청 2 · bookdam #58 외 1", or the state label without lines.
    var hoverLine1: String {
        guard let lines else { return stateLabel }
        return "리뷰 요청 \(lines.reviewRequested)" + (lines.line1Rest.isEmpty ? "" : " · \(lines.line1Rest)")
    }

    /// "내 PR 4 · 막힘 1 · #45 build 실패", or empty without lines.
    var hoverLine2: String {
        guard let lines else { return "" }
        return "내 PR \(lines.mine) · \(lines.line2Rest)"
    }

    /// A snapshot is only read for `.loaded`, and for `.loading` /
    /// `.rateLimited` when one was kept from before; every other state is a
    /// grey dot with its own hover label, whatever snapshot is lying around.
    static func of(_ snapshot: GitHubSnapshot?, state: GitHubLoadState, hidden: Set<String>) -> GitHubGlance {
        switch state {
        case .loaded:
            return snapshot.map { of($0.hiding(hidden)) } ?? .empty
        case .loading, .rateLimited:
            if let snapshot { return of(snapshot.hiding(hidden)) }
            return GitHubGlance(count: 0, dot: .grey, lines: nil, stateLabel: state.hoverLabel)
        case .off, .noToken, .keychainDenied, .unauthorized, .patSaveFailed, .error:
            return GitHubGlance(count: 0, dot: .grey, lines: nil, stateLabel: state.hoverLabel)
        }
    }

    private static func of(_ s: GitHubSnapshot) -> GitHubGlance {
        let blocked = s.mine.filter { PRVerdict.of($0, reviewRequested: false).isBlocking }
        let requested = s.reviewRequested.count
        let dot: GitHubDot = !blocked.isEmpty ? .red : (requested > 0 ? .amber : .green)

        var line1Rest = ""
        if let first = s.reviewRequested.first {
            line1Rest = "\(first.repositoryName) #\(first.number)"
            if requested > 1 { line1Rest += " 외 \(requested - 1)" }
        }

        var line2Rest = "막힘 \(blocked.count)"
        if let first = blocked.first {
            line2Rest += " · " + blockedReason(first)
        }
        let lines = Lines(reviewRequested: requested, mine: s.mine.count, blocked: blocked.count,
                          line1Rest: line1Rest, line2Rest: line2Rest)
        return GitHubGlance(count: requested + blocked.count, dot: dot, lines: lines, stateLabel: "")
    }

    /// "#45 build 실패" / "#45 충돌" / "#45 변경 요청". A rollup failure with no
    /// failed chip (the failure sits past the thirty contexts read) names
    /// the badge instead of a check.
    private static func blockedReason(_ pr: GitHubPullRequest) -> String {
        let verdict = PRVerdict.of(pr, reviewRequested: false)
        switch verdict {
        case .checksFailed:
            if let check = pr.firstFailedCheck { return "#\(pr.number) \(check.name) 실패" }
            return "#\(pr.number) \(verdict.label)"
        default:
            return "#\(pr.number) \(verdict.label)"
        }
    }
}
