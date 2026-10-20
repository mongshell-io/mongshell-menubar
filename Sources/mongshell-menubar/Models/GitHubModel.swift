import Foundation
import SwiftUI

/// Owns the GitHub PR snapshot and its connection state, and drives the one
/// poll loop behind the menu-bar region (Decision #45). Not a singleton:
/// AppDelegate creates it and hands the same instance to the status item,
/// hover, popover and settings views.
///
/// The judgements — badge, count, dot, hover lines — are not made here:
/// `GitHubGlance` / `PRVerdict` read the snapshot, and this only stores what
/// came back and decides when to ask again.
@MainActor
final class GitHubModel: ObservableObject {
    @Published private(set) var snapshot: GitHubSnapshot?
    @Published private(set) var loadState: GitHubLoadState = .off
    /// Which item the last refresh read its token from; nil while none was
    /// found or the region is off. Kept apart from `loadState` so settings
    /// can still say "PAT 사용 중" (and offer to clear it) after a 401.
    @Published private(set) var tokenSource: GitHubTokenSource?
    /// What the menu-bar region shows; recomputed whenever the snapshot, the
    /// state or the hidden repositories change.
    @Published private(set) var glance: GitHubGlance = .empty
    /// Set by `presentForSnapshot` so reference images don't tick: the
    /// popover's elapsed-time clock reads this instead of `Date()` when set.
    @Published private(set) var frozenNow: Date?
    /// Merges asked for from the popover, by `GitHubPullRequest.id`
    /// (Decision #49). What a refresh keeps is `GitHubMergePolicy.carryOver`.
    @Published private(set) var mergeActivity: [String: PRMergeActivity] = [:]

    private let prefs: Preferences
    private let credentials: GitHubCredentialStore
    private let client: GitHubAPIClient
    /// The one poll loop. It lives while the region is on: opening the
    /// popover or swapping the token wakes it (`refreshNow()`) rather than
    /// replacing it, so a refresh asked for mid-request is not lost with a
    /// cancelled loop. Kept after cancelling so the next loop can wait for
    /// it to wind down.
    private var pollTask: Task<Void, Never>?
    /// The loop's current sleep. Cancelling it wakes the loop without
    /// cancelling the loop itself.
    private var napTask: Task<Void, Never>?
    /// Bumped whenever the token or the on/off switch changes. A response is
    /// applied only under the generation it was requested in, so an old
    /// token's answer never lands over what the new token is about to show.
    private var generation = 0
    /// The generation `snapshot` arrived under. A token swap bumps
    /// `generation` but keeps the list on screen until the new token's
    /// answer, so the two differ exactly while the list speaks for a token
    /// no longer in use — `GitHubMergePolicy.gate` refuses a merge then.
    private var snapshotGeneration = 0
    /// The token source `snapshot` was fetched with. `tokenSource` moves at
    /// the start of every refresh, and `loadState` stops saying it while
    /// loading or rate-limited, so the list's own is kept here — a
    /// `gh auth switch` outside the app changes the account without a new
    /// generation, and `GitHubMergePolicy.gate` compares this instead.
    private var snapshotSource: GitHubTokenSource?
    private var backoff = 0
    private var popoverOpen = false
    /// The user refused the Keychain prompt for gh's item. Remembered for the
    /// session so the prompt doesn't come back every poll; cleared only by
    /// `retryGHKeychain()` and by switching the region off and on.
    private var ghKeychainDenied = false
    /// Same coalescing as `UsageModel`: a refresh asked for mid-flight runs
    /// once more afterwards instead of overlapping.
    private var refreshInFlight = false
    private var refreshRequested = false

    static let maxBackoff = 4
    /// `Task.sleep` has no "forever": an open-ended nap sleeps in steps of
    /// this many seconds until cancelled. Waking is by cancellation, so the
    /// step never delays it.
    private static let untilWokenStep = 3600

    init(prefs: Preferences, credentials: GitHubCredentialStore = .init(), client: GitHubAPIClient = .init()) {
        self.prefs = prefs
        self.credentials = credentials
        self.client = client
    }

    // MARK: Lifecycle

    func start() {
        guard prefs.githubEnabled else {
            loadState = .off
            updateGlance()
            return
        }
        startPolling()
    }

    /// The settings toggle. Switching on is the user gesture the first
    /// Keychain read happens in; switching off drops everything, so the
    /// region leaves no trace and the next switch-on starts clean.
    func setEnabled(_ on: Bool) {
        prefs.githubEnabled = on
        generation += 1
        guard on else {
            pollTask?.cancel()
            snapshot = nil
            snapshotSource = nil
            tokenSource = nil
            mergeActivity = [:]
            backoff = 0
            ghKeychainDenied = false
            loadState = .off
            updateGlance()
            return
        }
        ghKeychainDenied = false
        refreshNow()
    }

    /// Refreshes on the running loop and lets it work out the next wait
    /// afterwards: mid-request, the coalesced follow-up runs; asleep, the
    /// loop is woken. Starts the loop if none is running.
    func refreshNow() {
        guard prefs.githubEnabled else { return }
        guard isPolling else { startPolling(); return }
        if refreshInFlight {
            refreshRequested = true
        } else {
            napTask?.cancel()
        }
    }

    /// From AppDelegate on open and on `NSPopover.didCloseNotification`.
    /// Opening refreshes at once and, with a check still running, keeps the
    /// fast cadence; closing only lets the loop fall back to the base
    /// interval at its next wake — no extra request for a close. While
    /// backing off, or after a 401 or a failed PAT save, opening only
    /// records the flag.
    func setPopoverOpen(_ open: Bool) {
        guard open != popoverOpen else { return }
        popoverOpen = open
        guard open, GitHubPollPolicy.refreshesOnOpen(after: loadState, backoff: backoff) else { return }
        refreshNow()
    }

    /// Saves a pasted classic PAT and reads with it at once. Empty input is
    /// ignored — clearing is `clearPAT()`. A failed save is a banner, and
    /// nothing is requested until the user acts again — not by the loop's
    /// next poll, not by opening the popover: whatever the Keychain holds
    /// now is not the token the user just gave.
    func applyPAT(_ raw: String) {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        let status = credentials.savePAT(token)
        // The item was replaced either way, so a request still out with the
        // previous token no longer speaks for what is stored.
        generation += 1
        guard status == errSecSuccess else {
            guard prefs.githubEnabled else { return }
            // A follow-up asked for before the failure would go out right
            // after the request in flight, with whatever the Keychain now
            // resolves to — not the token just given.
            refreshRequested = false
            loadState = .patSaveFailed(status)
            updateGlance()
            return
        }
        refreshNow()
    }

    /// Drops the PAT; the next read falls through to gh's item.
    func clearPAT() {
        credentials.clearPAT()
        generation += 1
        refreshNow()
    }

    /// Settings-only: forget the refusal and ask the Keychain again.
    func retryGHKeychain() {
        ghKeychainDenied = false
        refreshNow()
    }

    /// Hides or shows one repository ("owner/name"). Goes through the model
    /// so the glance follows the change at once.
    func setRepoHidden(_ repository: String, hidden: Bool) {
        let key = repository.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return }
        var repos = prefs.githubHiddenRepos
        if hidden { repos.insert(key) } else { repos.remove(key) }
        prefs.githubHiddenReposRaw = repos.sorted().joined(separator: "\n")
        updateGlance()
    }

    // MARK: Merge (Decision #49)

    /// Squash-merges one of my PRs on one click of its button, sending the
    /// head SHA the row showed as `expectedHeadOid`. What
    /// `GitHubMergePolicy.gate` says of the current list and state decides:
    /// nothing goes out in a stopped state (a 401 among them) or on a list
    /// fetched before the token changed or with another account than the
    /// one the token now resolves to, and a head that moved since the row
    /// was drawn is refused here, before GitHub is asked.
    func merge(_ id: String, expectedHead: String) {
        // The token is resolved before the gate, because the gate compares
        // its source with the list's. A stopped state is turned away first
        // so it reads no Keychain and isn't overwritten by what that read
        // finds — the gate would refuse it anyway.
        guard prefs.githubEnabled, GitHubMergePolicy.allowsMerge(in: loadState) else { return }
        let token: String
        let source: GitHubTokenSource
        switch resolveToken() {
        case .token(let t, let s):
            token = t; source = s
        case .unavailable(let state):
            tokenSource = nil
            loadState = state
            updateGlance()
            return
        }
        let nodeID: String
        switch GitHubMergePolicy.gate(id: id, expectedHead: expectedHead, mine: snapshot?.mine,
                                      listGeneration: snapshotGeneration, generation: generation,
                                      listSource: snapshotSource, tokenSource: source,
                                      state: loadState, activity: mergeActivity[id]) {
        case .send(let node):
            nodeID = node
        case .headMoved:
            mergeActivity[id] = .failed(GitHubMergePolicy.headMovedReason)
            return
        case .listStale:
            mergeActivity[id] = .failed(GitHubMergePolicy.listStaleReason)
            // A swap in the app has already asked for the new list; an
            // account switched outside it has not. Same condition as after
            // a merge: a backoff is not skipped.
            if GitHubPollPolicy.refreshesOnOpen(after: loadState, backoff: backoff) { refreshNow() }
            return
        case .ignore:
            return
        }
        mergeActivity[id] = .merging
        let requestedIn = generation
        let client = client
        Task { [weak self] in
            let result = await client.merge(pullRequestId: nodeID, expectedHeadOid: expectedHead, token: token)
            self?.finishMerge(id, result: result, requestedIn: requestedIn)
        }
    }

    private func finishMerge(_ id: String, result: GitHubMergeResult, requestedIn: Int) {
        // Switched off meanwhile: that dropped every entry, this one too.
        guard prefs.githubEnabled, mergeActivity[id] == .merging else { return }
        switch result {
        case .merged:
            mergeActivity[id] = .merged
            // The list catches up at once — unless backing off, when the
            // next regular wake does, or stopped by a 401 or a failed PAT
            // save that landed while this merge was out (none is sent from
            // a stopped state), when nothing does until the user resumes.
            // Meanwhile the row stays "머지됨" (carried over while listed)
            // so it can't be clicked again.
            if GitHubPollPolicy.refreshesOnOpen(after: loadState, backoff: backoff) { refreshNow() }
        case .unauthorized:
            mergeActivity[id] = nil
            // The same stop as a polled 401 — unless the token was swapped
            // meanwhile, and the new one speaks for itself.
            guard requestedIn == generation else { return }
            refreshRequested = false
            loadState = .unauthorized
            updateGlance()
        default:
            mergeActivity[id] = .failed(result.failureReason ?? "")
        }
    }

    /// Snapshot hook: shows a given snapshot and state without any network,
    /// so reference images are deterministic and never carry real PRs.
    func presentForSnapshot(_ snapshot: GitHubSnapshot?, state: GitHubLoadState, now: Date,
                            mergeActivity: [String: PRMergeActivity] = [:]) {
        generation += 1
        pollTask?.cancel()
        self.snapshot = snapshot
        snapshotGeneration = generation
        if case .loaded(let source) = state { snapshotSource = source } else { snapshotSource = nil }
        self.mergeActivity = mergeActivity
        loadState = state
        if case .loaded(let source) = state { tokenSource = source } else { tokenSource = nil }
        frozenNow = now
        updateGlance()
    }

    // MARK: Polling

    private var isPolling: Bool { pollTask.map { !$0.isCancelled } ?? false }

    private func startPolling() {
        let previous = pollTask
        previous?.cancel()
        pollTask = Task { [weak self] in
            // A cancelled loop may still be finishing its request; until it
            // has, `refreshInFlight` would turn this loop's first refresh
            // into a follow-up that the cancelled loop never runs.
            await previous?.value
            await self?.pollLoop()
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await refreshOnce()
            let ranOut = await nap(seconds: autoWait())
            // A state set while asleep can withdraw the wait it started
            // with — a failed PAT save lands between polls. Then only a
            // wake from `refreshNow()` ends the nap.
            if ranOut, autoWait() == nil, !Task.isCancelled { await nap(seconds: nil) }
        }
    }

    private func autoWait() -> Int? {
        GitHubPollPolicy.nextAutoWait(
            after: loadState, base: prefs.githubPollSeconds, backoff: backoff,
            popoverOpen: popoverOpen, hasPendingChecks: snapshot?.hasPendingChecks ?? false)
    }

    /// Sleeps in a task of its own so `refreshNow()` can cut it short while
    /// the loop carries on; cancelling the loop cancels the nap too. nil
    /// sleeps until woken. Returns whether the wait ran its full length
    /// rather than being cut short.
    @discardableResult
    private func nap(seconds: Int?) async -> Bool {
        let nap = Task<Void, Never> {
            if let seconds {
                try? await Task.sleep(for: .seconds(seconds))
                return
            }
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(Self.untilWokenStep)) }
        }
        napTask = nap
        await withTaskCancellationHandler { await nap.value } onCancel: { nap.cancel() }
        if napTask == nap { napTask = nil }
        return !nap.isCancelled
    }

    private func refreshOnce() async {
        guard !refreshInFlight else { refreshRequested = true; return }
        refreshInFlight = true
        defer { refreshInFlight = false }
        repeat {
            refreshRequested = false
            await performRefresh()
        } while refreshRequested && !Task.isCancelled
    }

    // MARK: Token resolution (Decision #45 (c): own PAT → gh)

    private enum TokenResolution {
        case token(String, GitHubTokenSource)
        case unavailable(GitHubLoadState)
    }

    private func resolveToken() -> TokenResolution {
        if let pat = credentials.loadOwnPAT() { return .token(pat, .pat) }
        if ghKeychainDenied { return .unavailable(.keychainDenied) }
        switch credentials.loadGHToken() {
        case .success(let gh):
            return .token(gh.token, .ghCLI(account: gh.account))
        case .failure(.missing):
            return .unavailable(.noToken)
        case .failure(.denied):
            ghKeychainDenied = true
            return .unavailable(.keychainDenied)
        case .failure(.failure(let status)):
            return .unavailable(.error("Keychain 읽기 실패 (\(status))"))
        }
    }

    // MARK: Refresh

    /// The request is async URLSession work off the main thread; only the
    /// value lands back here.
    private func performRefresh() async {
        guard prefs.githubEnabled else { return }
        let requestedIn = generation
        let token: String
        let source: GitHubTokenSource
        switch resolveToken() {
        case .token(let t, let s):
            token = t; source = s
        case .unavailable(let state):
            tokenSource = nil
            loadState = state
            updateGlance()
            return
        }
        tokenSource = source
        if snapshot == nil { loadState = .loading; updateGlance() }

        let now = Date()
        let outcome: Result<GitHubFetchResult, GitHubAPIError>
        do {
            outcome = .success(try await client.fetch(token: token, now: now))
        } catch {
            outcome = .failure(error)
        }
        // The generation moved on meanwhile: drop the answer. A new state
        // that wants a refresh schedules one itself through `refreshNow()`.
        guard requestedIn == generation, prefs.githubEnabled else { return }

        switch outcome {
        case .success(.snapshot(let snap)):
            snapshot = snap
            snapshotGeneration = requestedIn
            snapshotSource = source
            mergeActivity = GitHubMergePolicy.carryOver(mergeActivity, into: snap.mine)
            loadState = .loaded(source)
            // Nearing the budget backs off like a 429 would, before one arrives.
            if let remaining = snap.rateLimit?.remaining, remaining < Config.githubRateLimitReserve {
                backOff()
            } else {
                backoff = 0
            }
        case .success(.unauthorized):
            // A follow-up coalesced while this request was out would resend
            // the rejected token once more without the user asking.
            refreshRequested = false
            loadState = .unauthorized
        case .success(.rateLimited(let retryAt)):
            backOff()
            loadState = .rateLimited(retryAt: retryAt ?? now.addingTimeInterval(Double(nextWait())))
        case .failure(.cancelled):
            return
        case .failure(let error):
            loadState = .error(error.detail)
        }
        updateGlance()
    }

    private func backOff() {
        backoff = min(backoff + 1, Self.maxBackoff)
    }

    private func nextWait() -> Int {
        GitHubPollPolicy.nextWait(base: prefs.githubPollSeconds, backoff: backoff,
                                  popoverOpen: popoverOpen,
                                  hasPendingChecks: snapshot?.hasPendingChecks ?? false)
    }

    private func updateGlance() {
        glance = GitHubGlance.of(snapshot, state: loadState, hidden: prefs.githubHiddenRepos)
    }
}
