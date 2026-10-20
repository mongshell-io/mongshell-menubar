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
    /// What the menu-bar region shows; recomputed whenever the snapshot, the
    /// state or the hidden repositories change.
    @Published private(set) var glance: GitHubGlance = .empty
    /// Set by `presentForSnapshot` so reference images don't tick: the
    /// popover's elapsed-time clock reads this instead of `Date()` when set.
    @Published private(set) var frozenNow: Date?

    private let prefs: Preferences
    private let credentials: GitHubCredentialStore
    private let client: GitHubAPIClient
    private var pollTask: Task<Void, Never>?
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
        restartPolling()
    }

    /// The settings toggle. Switching on is the user gesture the first
    /// Keychain read happens in; switching off drops everything, so the
    /// region leaves no trace and the next switch-on starts clean.
    func setEnabled(_ on: Bool) {
        prefs.githubEnabled = on
        guard on else {
            pollTask?.cancel()
            pollTask = nil
            snapshot = nil
            backoff = 0
            ghKeychainDenied = false
            loadState = .off
            updateGlance()
            return
        }
        ghKeychainDenied = false
        restartPolling()
    }

    func refreshNow() {
        guard prefs.githubEnabled else { return }
        Task { await refreshOnce() }
    }

    /// From AppDelegate on open and on `NSPopover.didCloseNotification`.
    /// Opening refreshes at once and, with a check still running, keeps the
    /// fast cadence; closing only lets the loop fall back to the base
    /// interval at its next wake — no extra request for a close.
    func setPopoverOpen(_ open: Bool) {
        guard open != popoverOpen else { return }
        popoverOpen = open
        guard open, prefs.githubEnabled else { return }
        restartPolling()
    }

    /// Saves a pasted classic PAT and reads with it at once. Empty input is
    /// ignored — clearing is `clearPAT()`.
    func applyPAT(_ raw: String) {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        credentials.savePAT(token)
        guard prefs.githubEnabled else { return }
        restartPolling()
    }

    /// Drops the PAT; the next read falls through to gh's item.
    func clearPAT() {
        credentials.clearPAT()
        guard prefs.githubEnabled else { return }
        restartPolling()
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

    /// Snapshot hook: shows a given snapshot and state without any network,
    /// so reference images are deterministic and never carry real PRs.
    func presentForSnapshot(_ snapshot: GitHubSnapshot?, state: GitHubLoadState, now: Date) {
        pollTask?.cancel()
        pollTask = nil
        self.snapshot = snapshot
        loadState = state
        frozenNow = now
        updateGlance()
    }

    // MARK: Polling

    private func restartPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await refreshOnce()
            let wait = GitHubPollPolicy.nextWait(
                base: prefs.githubPollSeconds, backoff: backoff,
                popoverOpen: popoverOpen, hasPendingChecks: snapshot?.hasPendingChecks ?? false)
            try? await Task.sleep(for: .seconds(wait))
        }
    }

    private func refreshOnce() async {
        guard !refreshInFlight else { refreshRequested = true; return }
        refreshInFlight = true
        defer { refreshInFlight = false }
        repeat {
            refreshRequested = false
            await performRefresh()
        } while refreshRequested
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
        let token: String
        let source: GitHubTokenSource
        switch resolveToken() {
        case .token(let t, let s):
            token = t; source = s
        case .unavailable(let state):
            loadState = state
            updateGlance()
            return
        }
        if snapshot == nil { loadState = .loading; updateGlance() }

        let now = Date()
        let outcome: Result<GitHubFetchResult, GitHubAPIError>
        do {
            outcome = .success(try await client.fetch(token: token, now: now))
        } catch {
            outcome = .failure(error)
        }
        // A cancelled poll belongs to a loop that has been replaced; the
        // region may have been switched off or the token swapped meanwhile.
        guard !Task.isCancelled, prefs.githubEnabled else { return }

        switch outcome {
        case .success(.snapshot(let snap)):
            snapshot = snap
            loadState = .loaded(source)
            // Nearing the budget backs off like a 429 would, before one arrives.
            if let remaining = snap.rateLimit?.remaining, remaining < Config.githubRateLimitReserve {
                backOff()
            } else {
                backoff = 0
            }
        case .success(.unauthorized):
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
