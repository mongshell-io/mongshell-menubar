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
    /// cancelled the prompt: then it is only kept in memory.
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
}

/// How a save of our own token ended.
enum OwnTokenSave: Equatable {
    case saved
    /// The item is as it was before the save.
    case failed
    /// The old item was deleted and the new one could not be added — the
    /// Keychain may now hold nothing (#108).
    case failedAfterDelete
}

/// Reads/writes tokens. Priority for reads:
///   1. our own OAuth token (Keychain)
///   2. Claude Code CLI token (Keychain "Claude Code-credentials", else file)
enum CredentialStore {

    // MARK: Own OAuth token (read/write)

    /// Replaces the item in place. Deleting first and adding after lost the
    /// token for good whenever the add failed: the refresh token is single
    /// use, so the one just spent cannot be asked for again (#102). A
    /// failure is logged. An in-place update keeps the item's access list as
    /// it was.
    static func saveOwnToken(_ token: OAuthToken) -> OwnTokenSave {
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
        } else if status != errSecSuccess, !OwnTokenLookup.isTransient(status), status != errSecUserCanceled {
            // An item this build may not update — recreating it is the way
            // back to an item we own. Not while the Keychain is locked, nor
            // when the user just cancelled the prompt: the delete could land
            // and the add fail.
            AuthDebugLog.write("own token update refused status=\(status); recreating")
            deleted = SecItemDelete(query as CFDictionary) == errSecSuccess
            status = SecItemAdd(attrs as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            AuthDebugLog.write("own token save failed status=\(status)\(deleted ? " after delete" : "")")
            return deleted ? .failedAfterDelete : .failed
        }
        return .saved
    }

    static func lookupOwnToken() -> OwnTokenLookup {
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

    /// The token, or nil when there is none or it cannot be read right now.
    static func loadOwnToken() -> OAuthToken? {
        guard case .found(let token) = lookupOwnToken() else { return nil }
        return token
    }

    /// Whether the Keychain now holds no own token; a failure is logged.
    static func clearOwnToken() -> Bool {
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
    /// falling back to ~/.claude/.credentials.json. Returns nil if neither is
    /// present or readable (e.g. the user denies the Keychain prompt).
    static func loadClaudeCodeToken() -> OAuthToken? {
        if let t = readClaudeCodeKeychain() { return t }
        return readClaudeCodeFile()
    }

    private static func readClaudeCodeKeychain() -> OAuthToken? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Config.claudeCodeKeychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return parseClaudeCodeJSON(data)
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
