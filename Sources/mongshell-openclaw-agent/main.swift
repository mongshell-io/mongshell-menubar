import Foundation

// Server-side openclaw watchdog. Runs under launchd on the always-on mac:
// probe the gateway → maybe hard-restart it → judge the host's own signals
// (power, disk, CI runners) → write the verdicts to a JSON file that `tailscale funnel`
// serves to the menubar clients. No network listener of our own — funnel does
// the serving.

// MARK: Options

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("오류: \(message)\n\n\(Options.usage)\n".utf8))
    exit(64) // EX_USAGE
}

// MARK: Logging

/// launchd redirects stdout to a log file; line-buffer it so entries land as
/// they happen instead of in 4KB bursts.
setvbuf(stdout, nil, _IOLBF, 0)

/// Formatter built per call: logging is rare (state changes and heals only),
/// and a shared top-level instance would be main-actor isolated under Swift 6.
func log(_ message: String) {
    print("\(ISO8601DateFormatter().string(from: Date())) \(message)")
}

// MARK: Loop

/// EX_TEMPFAIL: the agent exits after a probe it couldn't hear (see below), and
/// launchd's KeepAlive starts a fresh process.
let unobservedExitCode: Int32 = 75

let options: Options
switch Options.parse(Array(CommandLine.arguments.dropFirst())) {
case .run(let parsed): options = parsed
case .help: print(Options.usage); exit(0)
case .invalid(let message): fail(message)
}
var lastLogged: ProbeVerdict?
/// nil: nothing logged yet.
var lastLoggedHostLevels: HostSignalLevels?
/// Timeout is logged on the first of a run of timed-out probes only.
var lastProbeTimedOut = false

let agentVersion = AgentStatus.publishableVersion(options.buildVersion)
log("시작 — version=\(agentVersion ?? "없음") status-file=\(options.statusFile.path) interval=\(options.interval)s autoHeal=\(options.autoHeal)")
if let raw = options.buildVersion, agentVersion == nil {
    log("경고: --build-version 값이 형식에 맞지 않아 싣지 않습니다 (\(raw.count)자)")
}
if options.gatewayLabel == options.selfLabel {
    log("경고: --gateway-label 이 자기 레이블(\(options.selfLabel))이라 무시하고 자동 탐색합니다")
}

/// One probe, with a log line when it timed out.
@MainActor func probeGateway() -> ProbeObservation {
    let (run, observation) = Probe.probe()
    let timedOut = run?.timedOut ?? false
    if timedOut && !lastProbeTimedOut {
        log("probe 시간 초과 — \(Int(Probe.probeTimeout))초 안에 끝나지 않아 프로세스 그룹을 종료")
    }
    lastProbeTimedOut = timedOut
    return observation
}

/// A probe the agent couldn't hear says nothing about the gateway, so it is
/// neither published nor counted toward a heal. The cause is usually in this
/// process (an exhausted fd table once made every probe read empty), so rather
/// than retry in place the agent waits one interval — launchd would otherwise
/// restart it in a tight loop — and exits for a fresh start.
@MainActor func restartAfterUnobserved(_ reason: String) -> Never {
    log("probe 결과를 받지 못함 — \(reason). 게시·복구 없이 \(options.interval)초 뒤 재시작")
    Thread.sleep(forTimeInterval: TimeInterval(options.interval))
    exit(unobservedExitCode)
}

/// Judges the host signals and writes the status file, logging changes.
@MainActor func publish(_ verdict: ProbeVerdict, checkedAt: Date, lastHeal: HealRecord?) {
    let host = HostRules.judge(power: HostProbe.readPower(), disk: HostProbe.readDisk(),
                               runners: HostProbe.readRunners())

    let status = AgentStatus(
        checkedAt: checkedAt, verdict: verdict, intervalSeconds: options.interval,
        autoHeal: options.autoHeal, lastHeal: lastHeal, host: host, agentVersion: agentVersion)
    do {
        try StatusFile.write(status, to: options.statusFile)
    } catch {
        log("상태 파일 쓰기 실패 — \(error.localizedDescription)")
    }

    if verdict != lastLogged {
        log("상태: \(describe(verdict))")
        lastLogged = verdict
    }
    // Per signal, not the overall level: power going bad while the disk
    // already holds the overall level at warning is still a line.
    let hostLevels = HostSignalLevels(host)
    if hostLevels != lastLoggedHostLevels {
        log("호스트: \(describe(host))")
        lastLoggedHostLevels = hostLevels
    }
}

var cycle = AgentCycle(autoHeal: options.autoHeal, lastHeal: StatusFile.readLastHeal(from: options.statusFile))
let world = AgentCycle.World(
    probe: probeGateway,
    gatewayLabel: {
        Launchd.gatewayLabel(explicit: options.gatewayLabel, selfLabel: options.selfLabel,
                             in: Launchd.userLaunchAgentsDir)
    },
    kickstart: { Launchd.kickstart(label: $0) },
    publish: { publish($0, checkedAt: $1, lastHeal: $2) },
    log: log,
    sleep: { Thread.sleep(forTimeInterval: $0) },
    now: { Date() })

while true {
    // Top-level code has no run loop to drain autoreleased Foundation objects,
    // so each iteration drains its own pool.
    autoreleasepool {
        if case .unobserved(let reason) = cycle.run(world) { restartAfterUnobserved(reason) }
        Thread.sleep(forTimeInterval: TimeInterval(options.interval))
    }
}
