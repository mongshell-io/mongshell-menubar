import Foundation
import UserNotifications

/// The app's one door to Notification Center. Callers decide *whether* to
/// announce (their watches and preference gates); this only delivers.
///
/// Main-actor bound like its callers, the models.
@MainActor
enum Notifier {
    /// UserNotifications requires a real app bundle; an unbundled `swift run`
    /// dev launch crashes on the first call into it. Every entry point below
    /// checks this, and callers whose gate also depends on it read it here.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// Asks for permission without waiting for the answer.
    static func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Delivers at once. A fixed `identifier` makes a newer notification
    /// replace the older one in Notification Center.
    static func post(identifier: String, title: String, body: String) {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().add(request(identifier: identifier, title: title, body: body))
    }

    /// Asks for permission first and delivers only once it is granted — for a
    /// rare, action-required event whose own prompt may never have run.
    static func postAfterAuthorizing(identifier: String, title: String, body: String) {
        guard isAvailable else { return }
        let request = request(identifier: identifier, title: title, body: body)
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(request)
        }
    }

    private static func request(identifier: String, title: String, body: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }
}
