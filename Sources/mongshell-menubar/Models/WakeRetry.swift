import Foundation

/// When a poll loop asks again after a failure that came right after the mac
/// woke (#156). `Task.sleep` counts on `ContinuousClock`, which runs while
/// the mac sleeps, so a poll that fell due during sleep goes out the moment
/// it wakes — usually before the network is back. Waiting the full interval
/// after that failure left the error badge up for up to three minutes.
/// After the mac slept — through a wait, or through the request after it — a
/// failed poll is retried after `Config.wakeRetrySeconds`; a success, or
/// `Config.wakeRetryAttempts` failures in a row, puts the loop back on its
/// normal interval.
///
/// Sleep is told from the poll loop's own time — `SuspendingClock` stops
/// while the mac sleeps, `ContinuousClock` does not — rather than from
/// `NSWorkspace.didWakeNotification`: that arrives in no set order with the
/// poll that fell due, and a failure handled before it would get the full
/// wait. One value per poll loop; the usage, GitHub and openclaw loops use
/// the same rule.
struct WakeRetry: Equatable {
    /// Below this the two clocks drift apart without any sleep.
    static let sleptThreshold: Duration = .seconds(2)

    private(set) var retriesLeft = 0

    /// Whether the mac slept during a wait that took `continuous` on the
    /// clock that counts sleep and `suspending` on the one that does not.
    static func slept(continuous: Duration, suspending: Duration) -> Bool {
        continuous - suspending > sleptThreshold
    }

    /// Both clocks as a wait begins. Read once the next poll has come back,
    /// so it spans the wait and that request: a mac that sleeps mid-request
    /// fails it on waking just the same.
    struct Mark {
        private let continuous = ContinuousClock.now
        private let suspending = SuspendingClock.now

        var sleptSince: Bool {
            WakeRetry.slept(continuous: continuous.duration(to: .now),
                            suspending: suspending.duration(to: .now))
        }
    }

    /// The wait before the next poll: `normal`, or the short retry while
    /// retries are left after a failure.
    func wait(normal: Int, failed: Bool) -> Int {
        failed && retriesLeft > 0 ? min(normal, Config.wakeRetrySeconds) : normal
    }

    /// A poll's outcome: a failure spends a retry, a success ends them.
    mutating func polled(failed: Bool) {
        retriesLeft = failed ? max(retriesLeft - 1, 0) : 0
    }

    /// A poll came back; sleep since the last mark arms the retries. Called
    /// before `wait`, so the failure that sleep caused is the first retried.
    mutating func armIfSlept(_ slept: Bool) {
        if slept { retriesLeft = Config.wakeRetryAttempts }
    }
}
