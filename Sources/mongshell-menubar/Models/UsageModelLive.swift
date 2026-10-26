import Foundation

// The app's `UsageModel`, on the real boundaries. Kept out of
// `UsageModel.swift` so `scripts/test.sh` can compile the model without
// AuthService (AppKit, the loopback server), Notifier (UserNotifications) or
// Preferences (SwiftUI's @AppStorage) — the order tests hand it fakes (#150).

extension UsageModel {
    static let shared = UsageModel(boundaries: .live)
}

extension UsageModel.Boundaries {
    /// One `AuthService` for the life of the app, as the model held before.
    @MainActor static let live: Self = {
        let auth = AuthService()
        let api = UsageAPIClient()
        return Self(
            lookupOwnToken: CredentialStore.lookupOwnToken,
            saveOwnToken: CredentialStore.saveOwnToken,
            clearOwnToken: CredentialStore.clearOwnToken,
            loadClaudeCodeToken: CredentialStore.loadClaudeCodeToken,
            signIn: { try await auth.signIn() },
            refresh: { try await auth.refresh($0) },
            fetchUsage: { try await api.fetch(token: $0) },
            notificationsAvailable: { Notifier.isAvailable },
            requestNotificationAuthorization: { Notifier.requestAuthorization() },
            postNotification: { Notifier.post(identifier: $0, title: $1, body: $2) },
            postNotificationAfterAuthorizing: { Notifier.postAfterAuthorizing(identifier: $0, title: $1, body: $2) },
            notifyThresholds: { Preferences.shared.notifyThresholds },
            pollIntervalSeconds: { Preferences.shared.pollIntervalSeconds })
    }()
}
