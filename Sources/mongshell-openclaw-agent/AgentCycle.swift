import Foundation

/// One round of the watchdog: probe → maybe heal and re-probe → publish. The
/// outside world comes in through `World`, so the order of these steps — the
/// part that makes or breaks a restart loop — runs in the tests (#105).
@MainActor
struct AgentCycle {
    /// Gives launchd a moment to bring the gateway back before re-probing.
    static let postHealSettle: TimeInterval = 3

    struct World {
        var probe: @MainActor () -> ProbeObservation
        /// The gateway's launchd label, looked up only when a heal is due.
        var gatewayLabel: @MainActor () -> String
        /// Returns whether the kickstart succeeded.
        var kickstart: @MainActor (String) -> Bool
        /// Judges the host signals and writes the status file.
        var publish: @MainActor (_ verdict: ProbeVerdict, _ checkedAt: Date, _ lastHeal: HealRecord?) -> Void
        var log: @MainActor (String) -> Void
        var sleep: @MainActor (TimeInterval) -> Void
        var now: @MainActor () -> Date
    }

    enum Outcome: Equatable {
        case published
        /// A probe went unheard: the caller waits one interval and exits for
        /// a fresh process (see main.swift).
        case unobserved(reason: String)
    }

    let autoHeal: Bool
    private(set) var tracker: HealTracker
    /// The next process takes its cooldown from this in the status file.
    private(set) var lastHeal: HealRecord?

    init(autoHeal: Bool, lastHeal: HealRecord?) {
        self.autoHeal = autoHeal
        self.lastHeal = lastHeal
        tracker = HealTracker(lastHealAt: lastHeal?.at)
    }

    /// Runs one round up to, not including, the wait for the next one.
    mutating func run(_ world: World) -> Outcome {
        var verdict: ProbeVerdict
        switch world.probe() {
        case .observed(let v): verdict = v
        // A probe the agent couldn't hear says nothing about the gateway, so
        // it is neither published nor counted toward a heal.
        case .unobserved(let reason): return .unobserved(reason: reason)
        }
        var checkedAt = world.now()

        if autoHeal {
            tracker.record(verdict)
            if tracker.isHealDue(now: checkedAt) {
                let label = world.gatewayLabel()
                let ok = world.kickstart(label)
                tracker.markHealed(at: checkedAt)
                lastHeal = HealRecord(at: checkedAt, ok: ok, reason: verdict.healthName)
                world.log("복구 시도 — \(label) kickstart \(ok ? "성공" : "실패") (원인: \(describe(verdict)))")

                world.sleep(Self.postHealSettle)
                switch world.probe() {
                case .observed(let v):
                    verdict = v
                    checkedAt = world.now()
                    // Counted, but a failure only weakly (see
                    // `recordAfterHeal`); the cooldown just set keeps it from
                    // triggering another heal.
                    tracker.recordAfterHeal(verdict)
                case .unobserved(let reason):
                    // The heal must still reach the file: the next process
                    // takes its cooldown from `lastHeal` there. Published with
                    // the pre-heal verdict and the time it was observed.
                    world.publish(verdict, checkedAt, lastHeal)
                    return .unobserved(reason: reason)
                }
            }
        }

        world.publish(verdict, checkedAt, lastHeal)
        return .published
    }
}

func describe(_ verdict: ProbeVerdict) -> String {
    verdict.detailText.map { "\(verdict.healthName) (\($0))" } ?? verdict.healthName
}

func describe(_ host: HostStatus?) -> String {
    guard let host else { return "읽을 신호 없음" }
    let power = host.power.map { "전원 \($0.level.healthName)" } ?? "전원 없음"
    let disk = host.disk.map { "디스크 \($0.level.healthName)" } ?? "디스크 없음"
    let runners = host.runners.map { "러너 \($0.level.healthName)" } ?? "러너 없음"
    return "\(host.level.healthName) (\(power), \(disk), \(runners))"
}
