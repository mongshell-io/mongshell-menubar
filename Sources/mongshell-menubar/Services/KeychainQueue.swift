import Foundation

/// Where every `SecItem*` call of the app runs (#141). The calls block for
/// as long as a "키체인 접근 허용" prompt stays up, so they must not run on
/// the main thread, where the menu bar and the popover would stop with them.
///
/// One serial queue for all items: two calls on the same item never overlap,
/// and they run in the order they were asked for. That order holds because
/// `run` is `nonisolated(nonsending)`: it runs on the caller's actor without
/// a hop, and the closure handed to `withCheckedContinuation` runs at once,
/// so the job is queued before the caller first suspends. A plain
/// nonisolated `async func` would first hop to the global executor
/// (SE-0338), where calls made in order on the main actor reach the queue
/// in any order — a sign-in's save could then land before a poll's delete
/// asked for earlier. Every async entry point that leads here is
/// `nonisolated(nonsending)` too, for the same reason.
enum KeychainQueue {
    private static let queue = DispatchQueue(label: "com.mongshell.menubar.keychain")

    nonisolated(nonsending) static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    /// Calls `done` on the main thread once every job queued before this call
    /// has run, or once `timeout` has passed, whichever comes first — a
    /// prompt left up must not hold the caller forever.
    ///
    /// `done` is handed to the main run loop, not the main dispatch queue
    /// (`Task { @MainActor }`, `DispatchQueue.main`). The caller is quitting:
    /// AppKit waits for `reply(toApplicationShouldTerminate:)` by running the
    /// main run loop nested inside `terminate`, in `NSModalPanelRunLoopMode`
    /// (observed with `CFRunLoopCopyCurrentMode` while `.terminateLater` was
    /// pending). When `terminate` itself was called from a main-queue block
    /// — a `Task @MainActor` or `DispatchQueue.main.async` — the serial main
    /// queue cannot start another block until that one returns, so a reply
    /// sent through it never runs and the app never quits. A run-loop block
    /// in the common modes runs in any nested loop, whatever queue block it
    /// is inside; AppKit registers the modal-panel mode as a common mode.
    static func whenDrained(timeout: TimeInterval, _ done: @escaping @MainActor @Sendable () -> Void) {
        let drained = DispatchSemaphore(value: 0)
        queue.async { drained.signal() }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = drained.wait(timeout: .now() + timeout)
            let main = CFRunLoopGetMain()
            CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated { done() }
            }
            // A sleeping run loop does not look at its block list until woken.
            CFRunLoopWakeUp(main)
        }
    }
}
