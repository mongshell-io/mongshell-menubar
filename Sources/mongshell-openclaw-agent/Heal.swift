import Foundation

/// Decides *when* to hard-restart the gateway: on the 2nd consecutive failure
/// — the 4th when every one of them was a timeout — at most once per cooldown.
/// Pure state; the clock is passed in so tests don't sleep.
struct HealTracker {
    /// One failed probe can be a blip between longpolls; two in a row is not.
    static let failuresBeforeHeal = 2
    /// A run made only of timeouts may be a loaded host rather than a hung
    /// gateway, and a restart then only adds load and kills work in flight
    /// (issue #79). A real hang still times out every time, so it is healed —
    /// a few minutes later.
    static let timeoutsBeforeHeal = 4
    /// A kickstart that didn't help won't help 60s later either — and a
    /// restart loop would hide the real problem behind constant churn.
    static let cooldown: TimeInterval = 600

    private(set) var consecutiveFailures = 0
    /// Whether the current run of failures has one that isn't a timeout.
    private(set) var runHasHardFailure = false
    private(set) var lastHealAt: Date?

    init(lastHealAt: Date? = nil) {
        self.lastHealAt = lastHealAt
    }

    /// Counts a probe result. `.notInstalled` resets like `.ok` — restarting
    /// the gateway can't install a missing binary.
    mutating func record(_ verdict: ProbeVerdict) {
        switch verdict {
        case .down, .degraded:
            consecutiveFailures += 1
            runHasHardFailure = true
        case .timedOut:
            consecutiveFailures += 1
        case .ok, .notInstalled:
            resetRun()
        }
    }

    /// Counts the re-probe right after a kickstart. A failure there is counted
    /// like a timeout: the gateway is likely still starting, so a "not
    /// reachable" says nothing firm — counted as hard, a single timeout after
    /// the cooldown would heal again whenever the interval is long.
    mutating func recordAfterHeal(_ verdict: ProbeVerdict) {
        switch verdict {
        case .down, .degraded, .timedOut: record(.timedOut)
        case .ok, .notInstalled: record(verdict)
        }
    }

    func isHealDue(now: Date) -> Bool {
        let needed = runHasHardFailure ? Self.failuresBeforeHeal : Self.timeoutsBeforeHeal
        guard consecutiveFailures >= needed else { return false }
        if let last = lastHealAt, now.timeIntervalSince(last) < Self.cooldown { return false }
        return true
    }

    mutating func markHealed(at now: Date) {
        lastHealAt = now
        resetRun()
    }

    private mutating func resetRun() {
        consecutiveFailures = 0
        runHasHardFailure = false
    }
}

/// launchd side of healing: finding the gateway's label and kickstarting it.
enum Launchd {
    static let launchctlPath = "/bin/launchctl"
    static let kickstartTimeout: TimeInterval = 10
    /// The label openclaw's installer documents; used when nothing is found.
    static let defaultGatewayLabel = "ai.openclaw.gateway"

    static var userLaunchAgentsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
    }

    /// The gateway's launchd label. An explicit label wins unless it names this
    /// agent itself (a misconfigured plist) — then it is ignored like an
    /// absent one. Otherwise: basename of the first (sorted) `*.plist` in `dir`
    /// whose name contains `claw`, **excluding `selfLabel`** — this agent's own
    /// plist name also contains "claw"; whenever it sorts first (e.g. the
    /// gateway's plist is missing or renamed) the agent would otherwise
    /// kickstart itself.
    static func gatewayLabel(explicit: String?, selfLabel: String, in dir: URL) -> String {
        if let explicit, !explicit.isEmpty, explicit != selfLabel { return explicit }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let match = files.sorted().lazy
            .filter { $0.hasSuffix(".plist") && $0.lowercased().contains("claw") }
            .map { String($0.dropLast(".plist".count)) }
            .first { $0 != selfLabel }
        return match ?? defaultGatewayLabel
    }

    /// OS-level hard restart — the only thing that fixes openclaw's
    /// cancel-proof longpoll hang. Returns whether launchctl reported success.
    static func kickstart(label: String) -> Bool {
        let target = "gui/\(getuid())/\(label)"
        let result = Probe.run(launchctlPath, ["kickstart", "-k", target], timeout: kickstartTimeout)
        return !result.timedOut && result.termination == .exited(status: 0)
    }
}
