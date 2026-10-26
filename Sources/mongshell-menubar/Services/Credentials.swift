import Foundation
import Security

/// A bearer token plus optional refresh material.
struct OAuthToken: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    /// When the user signed in through the app's own OAuth; carried across
    /// refreshes so a lapsed login can be dated. Optional so Keychain items
    /// written before this field existed still decode. nil for CLI tokens.
    var signedInAt: Date?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt.addingTimeInterval(-60) // 60s slack
    }
}

/// What reading our own token found. A locked Keychain is kept apart from
/// "none" so it is not shown as signed-out (#102).
enum OwnTokenLookup: Equatable {
    case found(OAuthToken)
    case missing
    /// The Keychain is locked or may not ask the user right now. The item is
    /// most likely there and a later read should work.
    case unavailable(OSStatus)
    /// Any other refusal — access denied, an item written under another
    /// signing identity. It may not pass on its own, so the token choice
    /// treats it as missing (the CLI token is next, and a fresh sign-in
    /// replaces the item) — except while a renewal is held: then the poll
    /// keeps that token and tries to store it again (#132), unless the user
    /// declined the prompt (`isUserRefusal`): then the app stops asking
    /// until the user acts (#143).
    case refused(OSStatus)

    /// An item that is there but no longer decodes counts as missing: no
    /// later read will fix it.
    init(status: OSStatus, data: Data?) {
        switch status {
        case errSecSuccess:
            if let data, let token = try? JSONDecoder().decode(OAuthToken.self, from: data) {
                self = .found(token)
            } else {
                self = .missing
            }
        case errSecItemNotFound:
            self = .missing
        case _ where Self.isTransient(status):
            self = .unavailable(status)
        default:
            self = .refused(status)
        }
    }

    /// The failures that pass by themselves. Reads keep the token through
    /// them, and writes leave the item alone.
    static func isTransient(_ status: OSStatus) -> Bool {
        status == errSecInteractionNotAllowed || status == errSecNotAvailable
    }

    /// The refusals that are the user's answer to a Keychain prompt (#143).
    /// Only `errSecUserCanceled`: it is what the prompt's Cancel/Deny hands
    /// back. `errSecAuthFailed` is left out on purpose — it is also what an
    /// item written under another signing identity refuses with, without
    /// any prompt, and a wrong Keychain password; nothing measured here ties
    /// it to the user's answer, and counting it would stop the save that
    /// recreates such an item (#132). `AuthDebugLog` records every refused
    /// status, so a real-device reading can widen this later.
    static func isUserRefusal(_ status: OSStatus) -> Bool {
        status == errSecUserCanceled
    }
}

/// How a save of our own token ended.
enum OwnTokenSave: Equatable {
    case saved
    /// The item is as it was before the save.
    case failed
    /// The user declined the Keychain prompt; the item is as it was. Kept
    /// apart from `failed` so the app stops asking until the user acts (#143).
    case cancelled
    /// The old item was deleted and the new one could not be added — the
    /// Keychain may now hold nothing (#108).
    case failedAfterDelete

    /// A possibly empty Keychain outranks the user's answer: it is what the
    /// next poll has to know about.
    init(status: OSStatus, deletedFirst: Bool) {
        if status == errSecSuccess {
            self = .saved
        } else if deletedFirst {
            self = .failedAfterDelete
        } else if OwnTokenLookup.isUserRefusal(status) {
            self = .cancelled
        } else {
            self = .failed
        }
    }
}

/// What reading the Claude Code CLI token found (#155).
struct ClaudeCodeTokenRead: Equatable {
    let token: OAuthToken?
    /// The user declined the prompt for Claude Code's Keychain item
    /// (`OwnTokenLookup.isUserRefusal`). Kept apart from "no token" so the
    /// app stops asking until the user acts, as for its own item (#143). The
    /// file may still have given a token.
    let keychainDeclined: Bool

    init(token: OAuthToken?, keychainDeclined: Bool) {
        self.token = token
        self.keychainDeclined = keychainDeclined
    }

    /// `keychainStatus` is nil when the Keychain item was not asked. The
    /// file is read only when the item gave no token.
    init(keychainStatus: OSStatus?, keychainToken: OAuthToken?, fileToken: () -> OAuthToken?) {
        self.init(token: keychainToken ?? fileToken(),
                  keychainDeclined: keychainStatus.map(OwnTokenLookup.isUserRefusal) ?? false)
    }
}

/// Reads/writes tokens. Priority for reads:
///   1. our own OAuth token (Keychain)
///   2. Claude Code CLI token (Keychain "Claude Code-credentials", else file)
///
/// The entry points are async: each runs its Keychain calls on
/// `KeychainQueue`, off the main thread, and hands back only the result
/// (#141). Each is `nonisolated(nonsending)` — it runs on the caller's
/// actor — so calls reach the queue in the order they were made (see
/// `KeychainQueue`). A
/// save's update/delete/add stay one job, so no other Keychain call lands
/// between them.
enum CredentialStore {

    // MARK: Own OAuth token (read/write)

    nonisolated(nonsending) static func saveOwnToken(_ token: OAuthToken) async -> OwnTokenSave {
        await KeychainQueue.run { saveOwnTokenBlocking(token) }
    }

    nonisolated(nonsending) static func lookupOwnToken() async -> OwnTokenLookup {
        await KeychainQueue.run { lookupOwnTokenBlocking() }
    }

    /// Whether the Keychain now holds no own token; a failure is logged.
    nonisolated(nonsending) static func clearOwnToken() async -> Bool {
        await KeychainQueue.run { clearOwnTokenBlocking() }
    }

    /// Replaces the item in place. Deleting first and adding after lost the
    /// token for good whenever the add failed: the refresh token is single
    /// use, so the one just spent cannot be asked for again (#102). A
    /// failure is logged. An in-place update keeps the item's access list as
    /// it was.
    private static func saveOwnTokenBlocking(_ token: OAuthToken) -> OwnTokenSave {
        guard let data = try? JSONEncoder().encode(token) else { return .failed }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Config.ownKeychainService,
            kSecAttrAccount as String: Config.ownKeychainAccount
        ]
        var attrs = query
        attrs[kSecValueData as String] = data
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        var deleted = false
        if status == errSecItemNotFound {
            status = SecItemAdd(attrs as CFDictionary, nil)
        } else if status != errSecSuccess, !OwnTokenLookup.isTransient(status), !OwnTokenLookup.isUserRefusal(status) {
            // An item this build may not update — recreating it is the way
            // back to an item we own. Not while the Keychain is locked, nor
            // when the user just cancelled the prompt: the delete could land
            // and the add fail.
            AuthDebugLog.write("own token update refused status=\(status); recreating")
            (status, deleted) = recreate(delete: { SecItemDelete(query as CFDictionary) },
                                         add: { SecItemAdd(attrs as CFDictionary, nil) })
        }
        if status != errSecSuccess {
            AuthDebugLog.write("own token save failed status=\(status)\(deleted ? " after delete" : "")")
        }
        return OwnTokenSave(status: status, deletedFirst: deleted)
    }

    /// The delete-then-add of a save that could not update the item. The
    /// delete can prompt too: when the user cancels that prompt the item is
    /// as it was, the add is not tried — it would only fail as a duplicate
    /// and pass for a plain failure, so the decline would not be remembered
    /// and the next poll would ask again (#143). Returns the status the save
    /// ends with and whether the old item is gone.
    static func recreate(delete: () -> OSStatus, add: () -> OSStatus) -> (status: OSStatus, deleted: Bool) {
        let deleteStatus = delete()
        if OwnTokenLookup.isUserRefusal(deleteStatus) { return (deleteStatus, false) }
        return (add(), deleteStatus == errSecSuccess)
    }

    private static func lookupOwnTokenBlocking() -> OwnTokenLookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Config.ownKeychainService,
            kSecAttrAccount as String: Config.ownKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        return OwnTokenLookup(status: status, data: out as? Data)
    }

    private static func clearOwnTokenBlocking() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Config.ownKeychainService,
            kSecAttrAccount as String: Config.ownKeychainAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            AuthDebugLog.write("own token delete failed status=\(status)")
            return false
        }
        return true
    }

    // MARK: Claude Code CLI token (read-only fallback)

    /// Attempts to read the Claude Code OAuth access token from the Keychain,
    /// falling back to ~/.claude/.credentials.json; no token if neither is
    /// present or readable. A declined Keychain prompt is told apart (#155).
    /// `readingKeychain` false leaves the Keychain item — and its prompt —
    /// alone while the user's decline stands; the file is read either way.
    /// The file fallback rides the same job: it is only read once the
    /// Keychain has answered.
    nonisolated(nonsending) static func loadClaudeCodeToken(readingKeychain: Bool) async -> ClaudeCodeTokenRead {
        await KeychainQueue.run {
            let keychain = readingKeychain ? readClaudeCodeKeychain() : nil
            return ClaudeCodeTokenRead(keychainStatus: keychain?.status, keychainToken: keychain?.token,
                                       fileToken: readClaudeCodeFile)
        }
    }

    private static func readClaudeCodeKeychain() -> (status: OSStatus, token: OAuthToken?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Config.claudeCodeKeychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return (status, nil) }
        return (status, parseClaudeCodeJSON(data))
    }

    private static func readClaudeCodeFile() -> OAuthToken? {
        guard let data = try? Data(contentsOf: Config.claudeCodeCredentialsFile) else { return nil }
        return parseClaudeCodeJSON(data)
    }

    /// Claude Code stores `{ "claudeAiOauth": { accessToken, refreshToken, expiresAt } }`.
    /// `expiresAt` is epoch milliseconds. Decoded defensively — a JSON bool
    /// is not a time (#135).
    static func parseClaudeCodeJSON(_ data: Data) -> OAuthToken? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let oauth = (root["claudeAiOauth"] as? [String: Any]) ?? root
        guard let access = oauth["accessToken"] as? String, !access.isEmpty else { return nil }
        let refresh = oauth["refreshToken"] as? String
        var expires: Date?
        if let ms = JSONNumber.finite(oauth["expiresAt"]) {
            expires = Date(timeIntervalSince1970: ms / 1000)
        }
        return OAuthToken(accessToken: access, refreshToken: refresh, expiresAt: expires)
    }
}
