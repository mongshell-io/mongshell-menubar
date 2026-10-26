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
}
