import Foundation
import Security

/// Whether an Admin key is stored, as last read. `.unknown` until the first
/// read lands — and kept through a read that could not reach the Keychain
/// (locked at login, say), so that is not taken for "no key".
enum APICreditKeyState: Equatable {
    case unknown
    case absent
    case saved
    /// The save was refused with this status; the old key is gone with it
    /// (delete then add).
    case saveFailed(OSStatus)
}

/// Owns the estimated API credit balance (Decision #162): the cycle's spend
/// from the Admin API cost report, when it was read, and why the last read
/// failed. Polls every `Config.apiCreditPollSeconds` while a key is stored,
/// plus once when the popover opens on an older value. With no key it parks:
/// no polling, nothing in the popover.
///
/// Not a singleton — AppDelegate owns it and hands it to the popover and the
/// settings window (Models/CLAUDE.md § 싱글턴).
@MainActor
final class APICreditModel: ObservableObject {
    @Published private(set) var keyState: APICreditKeyState = .unknown
    /// USD spent this cycle, in cents, and the cycle it was read for. The
    /// estimate shows it only while that is still the current cycle.
    @Published private(set) var spentCents: Decimal?
    @Published private(set) var spentCycleStart: Date?
    @Published private(set) var lastUpdated: Date?
    /// The last read's failure; the value read before it stays on screen.
    @Published private(set) var lastError: CostReportError?

    /// The popover section exists only with a stored key (PHILOSOPHY 원칙 2).
    var showsSection: Bool { keyState == .saved }

    private let prefs: Preferences
    private let store = AdminKeyStore()
    private let client = CostReportClient()
    private var pollTask: Task<Void, Never>?
    /// Bumped whenever a read in flight stops speaking for what is stored or
    /// asked for — a key saved or cleared, a renewal day changed. A read
    /// checks it after each await and drops its answer if it moved (#141).
    private var generation = 0
    /// The generation a read is out for, so a second read isn't started
    /// beside it — but one for a newer generation is.
    private var inFlightGeneration: Int?
    private var consecutiveRateLimits = 0
    private var retryAfter: TimeInterval?
    /// No popover-open refresh before this while backing off a 429.
    private var notBefore: Date?
    /// Set by `presentForSnapshot` so reference images never reach the
    /// Keychain or the network.
    private var frozen = false

    init(prefs: Preferences) {
        self.prefs = prefs
    }

    // MARK: Lifecycle

    /// The first Keychain read; with no key the loop ends right there.
    func start() {
        restartPolling()
    }

    /// Opening the popover refreshes once the value is older than
    /// `Config.apiCreditRefreshOnOpenAge` — or belongs to another cycle —
    /// unless a 429 backoff is running.
    func popoverOpened(now: Date = Date()) {
        guard !frozen, keyState == .saved else { return }
        if let notBefore, now < notBefore { return }
        let currentCycle = cycle(now: now).start
        let fresh = lastUpdated.map { now.timeIntervalSince($0) < Config.apiCreditRefreshOnOpenAge } ?? false
        guard !fresh || spentCycleStart != currentCycle else { return }
        refreshNow()
    }

    func refreshNow() {
        guard !frozen else { return }
        Task { await refreshOnce() }
    }

    // MARK: Settings

    /// Why a typed-in key would be refused, or nil when it can be saved.
    static func keyInputProblem(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return "" }
        guard key.hasPrefix(Config.adminKeyPrefix) else {
            return "Admin 키(\(Config.adminKeyPrefix)…)만 사용할 수 있습니다"
        }
        return nil
    }

    /// Stores a new key and reads the cost report with it. Whatever was read
    /// with the old key is dropped — the new one may be another organization.
    func saveKey(_ raw: String) async {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.keyInputProblem(key) == nil else { return }
        stopPolling()
        clearReading()
        let savedIn = generation
        let status = await store.save(key)
        guard savedIn == generation else { return }
        guard status == errSecSuccess else {
            keyState = .saveFailed(status)
            return
        }
        keyState = .saved
        restartPolling()
    }

    func clearKey() async {
        stopPolling()
        clearReading()
        keyState = .absent
        await store.clear()
    }

    func setMonthlyCredit(_ usd: Int) {
        let range = Config.apiCreditMonthlyUSDRange
        prefs.apiCreditMonthlyUSD = min(max(usd, range.lowerBound), range.upperBound)
    }

    /// A new renewal day is a new cycle: the read in flight is for the old
    /// one, so it is dropped and the new cycle is read at once.
    func setRenewalDay(_ day: Int) {
        let days = APICreditCycle.renewalDays
        let clamped = min(max(day, days.lowerBound), days.upperBound)
        guard clamped != prefs.apiCreditRenewalDay else { return }
        prefs.apiCreditRenewalDay = clamped
        generation += 1
        if keyState == .saved { refreshNow() }
    }

    // MARK: Reading

    func cycle(now: Date) -> APICreditCycle {
        APICreditCycle.current(renewalDay: prefs.apiCreditRenewalDay, now: now)
    }

    func estimate(now: Date) -> APICreditEstimate? {
        APICreditEstimate.make(monthlyUSD: prefs.apiCreditMonthlyUSD, spentCents: spentCents,
                               spentCycleStart: spentCycleStart,
                               currentCycleStart: cycle(now: now).start)
    }

    /// Snapshot hook: a stored key and a canned spend, no Keychain, no network.
    func presentForSnapshot(spentCents: Decimal?, error: CostReportError?, now: Date) {
        stopPolling()
        frozen = true
        keyState = .saved
        self.spentCents = spentCents
        spentCycleStart = spentCents == nil ? nil : cycle(now: now).start
        lastUpdated = spentCents == nil ? nil : now
        lastError = error
    }

    // MARK: Polling

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        generation += 1
    }

    private func restartPolling() {
        stopPolling()
        guard !frozen else { return }
        pollTask = Task { [weak self] in await self?.pollLoop() }
    }

    private func pollLoop() async {
        var wake = WakeRetry()
        var mark = WakeRetry.Mark()
        while !Task.isCancelled {
            await refreshOnce()
            if keyState == .absent { return }
            wake.armIfSlept(mark.sleptSince)
            let failed = lastError != nil && consecutiveRateLimits == 0
            let secs = wake.wait(normal: APICreditPollPolicy.wait(consecutiveRateLimits: consecutiveRateLimits,
                                                                  retryAfter: retryAfter),
                                 failed: failed)
            wake.polled(failed: failed)
            mark = WakeRetry.Mark()
            try? await Task.sleep(for: .seconds(secs))
        }
    }

    /// One read: the key from the Keychain, then the cycle's cost report.
    /// The loop runs it, and so do the popover-open and renewal-day
    /// refreshes — a second read for the same generation is skipped rather
    /// than sent twice.
    private func refreshOnce() async {
        let readIn = generation
        guard inFlightGeneration != readIn else { return }
        inFlightGeneration = readIn
        defer { if inFlightGeneration == readIn { inFlightGeneration = nil } }

        let lookup = await store.load()
        guard readIn == generation else { return }
        let key: String
        switch lookup {
        case .found(let found):
            key = found
            keyState = .saved
        case .missing:
            keyState = .absent
            clearReading()
            return
        case .unavailable:
            // Not "no key": try again on the next poll, showing what we had.
            return
        }

        let now = Date()
        let cycleStart = cycle(now: now).start
        let range = CostReportClient.queryRange(cycleStart: cycleStart, now: now)
        let outcome: Result<Decimal, CostReportError>
        do {
            outcome = .success(try await client.fetchSpentCents(adminKey: key, range: range))
        } catch {
            outcome = .failure(error)
        }
        guard readIn == generation else { return }

        switch outcome {
        case .success(let cents):
            spentCents = cents
            spentCycleStart = cycleStart
            lastUpdated = Date()
            lastError = nil
            consecutiveRateLimits = 0
            retryAfter = nil
            notBefore = nil
        case .failure(.cancelled):
            return
        case .failure(let error):
            lastError = error
            if case .rateLimited(let after) = error {
                consecutiveRateLimits += 1
                retryAfter = after
                let wait = APICreditPollPolicy.wait(consecutiveRateLimits: consecutiveRateLimits,
                                                    retryAfter: after)
                notBefore = Date().addingTimeInterval(TimeInterval(wait))
            } else {
                consecutiveRateLimits = 0
                retryAfter = nil
                notBefore = nil
            }
        }
    }

    private func clearReading() {
        spentCents = nil
        spentCycleStart = nil
        lastUpdated = nil
        lastError = nil
        consecutiveRateLimits = 0
        retryAfter = nil
        notBefore = nil
    }
}
