import Foundation
import Security

/// Why the gh CLI's Keychain item couldn't be read. The caller (`GitHubModel`)
/// remembers `.denied` for the session so the prompt doesn't come back on
/// every poll (Decision #45).
enum GHKeychainError: Error, Equatable, Sendable {
    /// No item under `Config.ghKeychainService` — gh isn't logged in here.
    case missing
    /// The user refused or dismissed the Keychain prompt, or no prompt could
    /// be shown.
    case denied
    case failure(OSStatus)
}

/// The gh CLI's token and the GitHub username it was stored under. The
/// account is the only part of this that may appear in the UI.
struct GitHubGHCredential: Equatable, Sendable {
    let token: String
    let account: String
}

/// GitHub tokens (Decision #45 (c)). Two Keychain items: our own PAT item
/// (read/write) and the gh CLI's (read-only — it is gh's, not ours). The
/// read order, PAT first, is applied by the model.
struct GitHubCredentialStore: Sendable {

    // MARK: Own PAT (read/write)

    func loadOwnPAT() -> String? {
        var query = Self.ownItemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty
        else { return nil }
        return token
    }

    /// Replaces the PAT. Returns `SecItemAdd`'s status — `errSecSuccess`
    /// when the new token is stored — so the caller can say so instead of
    /// polling on as if it were.
    func savePAT(_ token: String) -> OSStatus {
        SecItemDelete(Self.ownItemQuery as CFDictionary)
        var attrs = Self.ownItemQuery
        attrs[kSecValueData as String] = Data(token.utf8)
        return SecItemAdd(attrs as CFDictionary, nil)
    }

    func clearPAT() {
        SecItemDelete(Self.ownItemQuery as CFDictionary)
    }

    private static var ownItemQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Config.ownKeychainService,
         kSecAttrAccount as String: Config.githubPATKeychainAccount]
    }

    // MARK: gh CLI item (read-only)

    /// Reads gh's token — this is the call that prompts. Of several items
    /// under the service (multiple gh accounts) an arbitrary one is read.
    /// The go-keyring wrapping is undone here, so the token comes back
    /// ready to send.
    func loadGHToken() -> Result<GitHubGHCredential, GHKeychainError> {
        var query = Self.ghItemQuery
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let item = out as? [String: Any],
                  let data = item[kSecValueData as String] as? Data,
                  let raw = String(data: data, encoding: .utf8)
            else { return .failure(.failure(errSecDecode)) }
            let token = Self.decodeGHKeyringValue(raw)
            guard !token.isEmpty else { return .failure(.missing) }
            let account = item[kSecAttrAccount as String] as? String ?? ""
            return .success(GitHubGHCredential(token: token, account: account))
        case errSecItemNotFound:
            return .failure(.missing)
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
            return .failure(.denied)
        default:
            return .failure(.failure(status))
        }
    }

    private static var ghItemQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Config.ghKeychainService,
         kSecMatchLimit as String: kSecMatchLimitOne]
    }

    // MARK: go-keyring value (pure)

    /// gh stores through zalando/go-keyring, which wraps the secret:
    /// `go-keyring-base64:` + base64 (current), `go-keyring-encoded:` + hex
    /// (older), or the plain secret (older still). Whitespace and newlines
    /// around the value are dropped. A wrapped value that doesn't decode is
    /// returned as it is — a wrong token gets a 401 banner, which is more
    /// diagnosable than "no token".
    static func decodeGHKeyringValue(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let payload = value.removingPrefix(base64Prefix) {
            guard let data = Data(base64Encoded: payload),
                  let decoded = String(data: data, encoding: .utf8) else { return value }
            return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let payload = value.removingPrefix(hexPrefix) {
            guard let data = Data(hexEncoded: payload),
                  let decoded = String(data: data, encoding: .utf8) else { return value }
            return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private static let base64Prefix = "go-keyring-base64:"
    private static let hexPrefix = "go-keyring-encoded:"
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

private extension Data {
    /// Lowercase or uppercase hex, even length, nothing else.
    init?(hexEncoded hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
