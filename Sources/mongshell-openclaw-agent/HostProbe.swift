import Foundation
import IOKit.ps

/// How bad a host signal is. Declaration order is severity order — the
/// synthesized `Comparable` is what "worst of" relies on. No `down`: a host
/// that is down publishes nothing, and clients notice that by staleness.
enum HostLevel: Comparable {
    case ok
    case warning
    case critical
}

/// What the internal battery and the power adapter say, before any judgement.
struct PowerReading: Equatable {
    let pluggedIn: Bool
    let charging: Bool
    /// 0...100, or nil when the battery doesn't report a usable capacity.
    let batteryPercent: Int?
}

/// Free space on the volume holding the home directory, before any judgement.
struct DiskReading: Equatable {
    let availableBytes: Int64
}

/// The self-hosted GitHub Actions runners installed as LaunchDaemons, before
/// any judgement (#75). `total` is never 0 — no runner installed is no reading.
struct RunnersReading: Equatable {
    let running: Int
    let total: Int
}

/// The judged host signals (Decision #31). A signal that can't be read is nil;
/// a `HostStatus` exists only when at least one signal could be.
struct HostStatus: Equatable {
    struct Power: Equatable {
        let reading: PowerReading
        let level: HostLevel
    }

    struct Disk: Equatable {
        let reading: DiskReading
        let level: HostLevel
    }

    struct Runners: Equatable {
        let reading: RunnersReading
        let level: HostLevel
    }

    let power: Power?
    let disk: Disk?
    let runners: Runners?
    /// The worst level among the signals present.
    let level: HostLevel
}

/// The level of each signal, nil where there is none — what tells one host
/// verdict from another in the agent's log. The overall level follows from
/// the signals, so it isn't part of it.
struct HostSignalLevels: Equatable {
    let power: HostLevel?
    let disk: HostLevel?
    let runners: HostLevel?

    init(_ host: HostStatus?) {
        power = host?.power?.level
        disk = host?.disk?.level
        runners = host?.runners?.level
    }
}

/// Mechanism: reads the raw host signals. No thresholds here — see `HostRules`.
enum HostProbe {
    // MARK: Power

    /// The internal battery's state, or nil on a mac without one.
    static func readPower() -> PowerReading? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        let handles = (IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as [CFTypeRef]?) ?? []
        let sources = handles.compactMap { handle in
            IOPSGetPowerSourceDescription(blob, handle)?.takeUnretainedValue() as? [String: Any]
        }
        return interpretPower(providing: providing, sources: sources)
    }

    /// Turns IOKit's power-source dictionaries into a reading. Pure, so the
    /// battery-less shapes (no sources, UPS only, battery bay empty) are
    /// testable without the hardware.
    ///
    /// Only an internal battery counts; a UPS is out of scope. When nothing
    /// says where power comes from there is no reading.
    static func interpretPower(providing: String?, sources: [[String: Any]]) -> PowerReading? {
        let battery = sources.first { source in
            source[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
                && source[kIOPSIsPresentKey] as? Bool != false
        }
        guard let battery else { return nil }
        let batteryState = battery[kIOPSPowerSourceStateKey] as? String
        guard let pluggedIn = pluggedIn(providing: providing, batteryState: batteryState) else {
            return nil
        }
        return PowerReading(
            pluggedIn: pluggedIn,
            charging: battery[kIOPSIsChargingKey] as? Bool ?? false,
            batteryPercent: batteryPercent(
                current: battery[kIOPSCurrentCapacityKey] as? Int,
                max: battery[kIOPSMaxCapacityKey] as? Int))
    }

    /// `providing` is the system-wide answer and wins: anything but the
    /// internal battery (AC, or a UPS feeding the adapter) means the battery
    /// isn't what keeps the server up. The battery's own state is the
    /// fallback, and there only its two definite values count — any other
    /// ("Off Line") says the battery isn't supplying, not what is.
    private static func pluggedIn(providing: String?, batteryState: String?) -> Bool? {
        if let providing { return providing != kIOPMBatteryPowerKey }
        if batteryState == kIOPSACPowerValue { return true }
        if batteryState == kIOPSBatteryPowerValue { return false }
        return nil
    }

    static let fullPercent = 100

    /// Current capacity is only meaningful relative to max capacity (IOKit
    /// leaves the unit open), so without a positive max there is no percent.
    private static func batteryPercent(current: Int?, max: Int?) -> Int? {
        guard let current, let max, max > 0, current >= 0 else { return nil }
        let percent = (Double(current) / Double(max) * Double(fullPercent)).rounded()
        // Capped before the conversion: `Int(_:)` traps on a value past
        // `Int.max`, which a current far above max would produce.
        return Int(min(percent, Double(fullPercent)))
    }

    // MARK: Disk

    /// Free space on the volume holding the home directory — where openclaw
    /// and its logs live — or nil if the volume won't say.
    static func readDisk() -> DiskReading? {
        var home = FileManager.default.homeDirectoryForCurrentUser
        // URL caches resource values until the run loop turns, and this agent
        // has no run loop: without this a reused URL would repeat a stale size.
        home.removeAllCachedResourceValues()
        let values = try? home.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        return interpretDisk(
            importantUsage: values?.volumeAvailableCapacityForImportantUsage,
            available: values?.volumeAvailableCapacity.map(Int64.init))
    }

    /// Prefers the "important usage" figure (counts purgeable space, matches
    /// what Finder shows). It reads 0 or nil on volumes that don't support it,
    /// so a non-positive value falls back to the plain figure — where 0 is a
    /// real answer: the disk is full.
    static func interpretDisk(importantUsage: Int64?, available: Int64?) -> DiskReading? {
        if let importantUsage, importantUsage > 0 {
            return DiskReading(availableBytes: importantUsage)
        }
        if let available, available >= 0 {
            return DiskReading(availableBytes: available)
        }
        return nil
    }

    // MARK: CI runners (#75)

    /// Where the runner installer puts its LaunchDaemon plists, one per runner.
    static let launchDaemonsDir = URL(fileURLWithPath: "/Library/LaunchDaemons")
    /// Every runner's label starts with this (`com.github.actions-runner.org`,
    /// `…org-2`, …). Counted, not listed: the number of runners is whatever
    /// is installed.
    static let runnerLabelPrefix = "com.github.actions-runner."
    private static let plistSuffix = ".plist"
    /// The same binary `Launchd` (Heal.swift) kickstarts with; repeated here so
    /// the host probe doesn't pull in the heal code.
    static let launchctlPath = "/bin/launchctl"
    /// `launchctl print` answers from launchd's memory in well under a second.
    static let runnerPrintTimeout: TimeInterval = 5
    /// Budget for asking about every runner in one probe. Healthy, four
    /// runners take well under a second in all; asked one by one, a launchd
    /// that hangs on each would otherwise stack `runnerPrintTimeout` (plus
    /// `Probe.run`'s kill and read grace) per runner onto every cycle — and
    /// the gateway probe before it may already take 27s of a 30s minimum
    /// interval. Past the budget the remaining runners go unasked, which is
    /// "not heard" like any other (see `readRunners`). The budget bounds when
    /// the last question may start and how long it may wait, not the stage's
    /// wall time: a last question that hangs still gets `Probe.run`'s kill and
    /// read grace on top, so the stage can run about 2s past it.
    static let runnersDeadline: TimeInterval = 10

    /// How many runners are installed and how many launchd reports running,
    /// or nil when no runner is installed — or when launchctl couldn't be
    /// heard for one of them, or the runner budget ran out first.
    ///
    /// The second nil is deliberate: a runner we failed to ask about is
    /// neither running nor stopped as far as we know, and counting it either
    /// way would publish a verdict nobody measured (a spawn failure would read
    /// as "all runners down"). What dropping the whole signal costs: the app
    /// draws no runner row, and the overall `host` level is judged on the
    /// signals left — so for that cycle a server whose runners are all down
    /// can show green. Only the app's alert watch keeps the last runner level
    /// as its baseline. No false alarm, and no recovery alert either.
    static func readRunners() -> RunnersReading? {
        let labels = runnerLabels(in: launchDaemonsDir)
        guard !labels.isEmpty else { return nil }
        return countRunning(
            labels, deadline: runnersDeadline,
            clock: { ProcessInfo.processInfo.systemUptime }
        ) { label, timeout in
            interpretRunner(Probe.run(launchctlPath, ["print", "system/\(label)"], timeout: timeout))
        }
    }

    /// Asks `ask` about each label in turn — with a timeout no longer than
    /// what is left of `deadline` — and counts the running ones. nil as soon
    /// as one goes unheard or the deadline (measured on `clock`) has passed
    /// before a label is asked. Split from `readRunners` so the budget is
    /// testable without launchd or real time.
    static func countRunning(_ labels: [String], deadline: TimeInterval,
                             clock: () -> TimeInterval,
                             ask: (_ label: String, _ timeout: TimeInterval) -> Bool?)
        -> RunnersReading? {
        let start = clock()
        var running = 0
        for label in labels {
            let remaining = deadline - (clock() - start)
            guard remaining > 0 else { return nil }
            guard let isRunning = ask(label, min(runnerPrintTimeout, remaining)) else { return nil }
            if isRunning { running += 1 }
        }
        return RunnersReading(running: running, total: labels.count)
    }

    /// Runner labels from the plists in `dir`, sorted. An unreadable or
    /// missing directory is no runners.
    static func runnerLabels(in dir: URL) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files
            .filter { $0.hasPrefix(runnerLabelPrefix) && $0.hasSuffix(plistSuffix) }
            .map { String($0.dropLast(plistSuffix.count)) }
            .sorted()
    }

    /// One `launchctl print system/<label>` → running or not; nil when the
    /// agent didn't get to hear launchctl (it couldn't start, hung, died on a
    /// signal, or said nothing). Any answer that isn't a top-level
    /// `state = running` is "not running" — including launchctl's own "Could
    /// not find service" (plist present but not loaded), which exits non-zero
    /// with output.
    static func interpretRunner(_ result: Probe.RunResult) -> Bool? {
        if result.timedOut { return nil }
        switch result.termination {
        case .launchFailed, .signaled: return nil
        case .exited, .unknown: break
        }
        if result.stdout.allSatisfy(\.isWhitespace) { return nil }
        return isRunning(launchctlPrint: result.stdout)
    }

    /// The service's own `state` line sits one tab in; nested blocks
    /// (endpoints, spawn info) carry `state = active` and the like two or more
    /// tabs in, and must not count.
    static func isRunning(launchctlPrint output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { line in
            guard line.hasPrefix("\t"), !line.dropFirst().hasPrefix("\t") else { return false }
            return line.trimmingCharacters(in: .whitespaces) == "state = running"
        }
    }
}

/// Policy: the single home of the host thresholds (Decision #31). Clients only
/// display the levels this agent publishes. No hysteresis — a value sitting on
/// a threshold may flip between levels from one probe to the next.
enum HostRules {
    /// On battery at or below this, the server is about to go dark.
    static let criticalBatteryPercent = 20

    /// Decimal, like Finder and the disk's label — not GiB.
    static let bytesPerGB: Int64 = 1_000_000_000
    static let diskWarningBelowBytes = 20 * bytesPerGB
    static let diskCriticalBelowBytes = 5 * bytesPerGB

    /// Plugged in is fine whatever the charge. On battery is already worth a
    /// warning — an always-on server lost its adapter — and an unreadable
    /// charge stays a warning rather than guessing either way.
    static func level(for power: PowerReading) -> HostLevel {
        if power.pluggedIn { return .ok }
        guard let percent = power.batteryPercent else { return .warning }
        return percent <= criticalBatteryPercent ? .critical : .warning
    }

    static func level(for disk: DiskReading) -> HostLevel {
        if disk.availableBytes < diskCriticalBelowBytes { return .critical }
        if disk.availableBytes < diskWarningBelowBytes { return .warning }
        return .ok
    }

    /// Every runner up is fine, none up is CI stopped outright, anything in
    /// between still runs jobs, only slower (#75).
    static func level(for runners: RunnersReading) -> HostLevel {
        if runners.running >= runners.total { return .ok }
        return runners.running == 0 ? .critical : .warning
    }

    /// Judges each signal that could be read; nil when none could.
    static func judge(power: PowerReading?, disk: DiskReading?,
                      runners: RunnersReading? = nil) -> HostStatus? {
        let judgedPower = power.map { HostStatus.Power(reading: $0, level: level(for: $0)) }
        let judgedDisk = disk.map { HostStatus.Disk(reading: $0, level: level(for: $0)) }
        let judgedRunners = runners.map { HostStatus.Runners(reading: $0, level: level(for: $0)) }
        let levels = [judgedPower?.level, judgedDisk?.level, judgedRunners?.level]
        guard let worst = levels.compactMap({ $0 }).max() else { return nil }
        return HostStatus(power: judgedPower, disk: judgedDisk, runners: judgedRunners, level: worst)
    }
}
