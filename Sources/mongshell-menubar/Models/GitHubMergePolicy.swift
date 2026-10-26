import Foundation

// MARK: - Merge (Decision #49)

/// Which popover list a row sits in.
enum PRSection: Sendable {
    case mine, merged
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
    /// fetched — swapped in the app, or another account made active in gh
    /// outside it: nothing was sent, and the new token's list is on its way.
    static let listStaleReason = "토큰이 바뀌어 목록을 다시 받는 중이에요 — 받은 뒤 다시 눌러 주세요"

    /// Whether the region's state lets a merge go out: loaded, or loading /
    /// rate-limited on an earlier answer (the same states `GitHubGlance`
    /// reads a snapshot in). A rejected token, a failed PAT save, an error,
    /// no token, a refused Keychain or a region switched off sends nothing.
    /// The state alone doesn't say the list came from the token in use — a
    /// token swap leaves `.loaded` standing until the next answer — so
    /// `gate` also compares the list's generation and token source with the
    /// current ones.
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
        /// The list was fetched before the token last changed, or with a
        /// token from another item or account than the one the merge would
        /// go out with, so it speaks for someone else.
        case listStale
        /// Nothing to send and nothing to say: a merge already out or done,
        /// a stopped state, or a PR the list no longer offers a merge on.
        case ignore
    }

    /// Judged on the PR as `mine` holds it now — looked up by id, never the
    /// copy the row drew from — so the node id, the head and `canOffer` all
    /// come from the current list. `listGeneration` is the model's
    /// generation when that list arrived, `generation` its generation now;
    /// `listSource` is the token source that list was fetched with,
    /// `tokenSource` the one the merge would go out with. A swap in the app
    /// bumps the generation, but `gh auth switch` outside it changes only
    /// the account gh's item resolves to — the source tells that apart.
    static func gate(id: String, expectedHead: String, mine: [GitHubPullRequest]?,
                     listGeneration: Int, generation: Int,
                     listSource: GitHubTokenSource?, tokenSource: GitHubTokenSource,
                     state: GitHubLoadState, activity: PRMergeActivity?) -> Gate {
        guard allowsMerge(in: state), activity != .merging, activity != .merged,
              let current = mine?.first(where: { $0.id == id }),
              canOffer(current, section: .mine),
              let nodeID = current.nodeID else { return .ignore }
        guard listGeneration == generation, listSource == tokenSource else { return .listStale }
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
