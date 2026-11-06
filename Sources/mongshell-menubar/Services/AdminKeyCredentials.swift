import Foundation
import Security

/// What reading the Admin key item found. "Couldn't read" is kept apart
/// from "no key": a locked Keychain at login must not read as the key having
/// been removed, which would hide the section until the next save.
enum AdminKeyLookup: Equatable, Sendable {
    case found(String)
    case missing
    case unavailable(OSStatus)
}

/// The Console Admin key for the cost report (Decision #162), in our own
/// Keychain item under `Config.ownKeychainService`. Modeled on the own GitHub
/// PAT: every entry point runs its Keychain calls on `KeychainQueue`, off the
/// main thread, and is `nonisolated(nonsending)` so calls reach the queue in
/// the order they were made (#141).
struct AdminKeyStore: Sendable {

    nonisolated(nonsending) func load() async -> AdminKeyLookup {
        await KeychainQueue.run { Self.loadBlocking() }
    }

    private static func loadBlocking() -> AdminKeyLookup {
        var query = Self.itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data,
                  let key = String(data: data, encoding: .utf8), !key.isEmpty
            else { return .missing }
            return .found(key)
        case errSecItemNotFound:
            return .missing
        default:
            return .unavailable(status)
        }
    }

    /// Replaces the key. Returns `SecItemAdd`'s status so the caller can say
    /// whether the key is stored. Delete then add, as for the GitHub PAT: an
    /// in-place update would write the key into an item another process
    /// created first (Decision #109, #126). One job, so no other Keychain
    /// call lands between the two.
    nonisolated(nonsending) func save(_ key: String) async -> OSStatus {
        await KeychainQueue.run {
            SecItemDelete(Self.itemQuery as CFDictionary)
            var attrs = Self.itemQuery
            attrs[kSecValueData as String] = Data(key.utf8)
            return SecItemAdd(attrs as CFDictionary, nil)
        }
    }

    nonisolated(nonsending) func clear() async {
        await KeychainQueue.run { _ = SecItemDelete(Self.itemQuery as CFDictionary) }
    }

    private static var itemQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Config.ownKeychainService,
         kSecAttrAccount as String: Config.adminKeyKeychainAccount]
    }
}
