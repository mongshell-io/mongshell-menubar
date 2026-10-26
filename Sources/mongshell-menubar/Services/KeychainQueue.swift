import Foundation

/// Where every `SecItem*` call of the app runs (#141). The calls block for
/// as long as a "키체인 접근 허용" prompt stays up, so they must not run on
/// the main thread, where the menu bar and the popover would stop with them.
///
/// One serial queue for all items: two calls on the same item never overlap,
/// and they run in the order they were asked for — the closure handed to
/// `withCheckedContinuation` runs at once, so the job is queued before the
/// caller suspends. A sign-in's save asked for after a poll's read therefore
/// lands after it.
enum KeychainQueue {
    private static let queue = DispatchQueue(label: "com.mongshell.menubar.keychain")

    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}
