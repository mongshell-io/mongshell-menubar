import Foundation

/// POSTs to the OAuth token endpoint (code exchange and refresh) and maps the
/// response into an `OAuthToken`. Split from `AuthService`, which pulls in
/// AppKit and the loopback server, so `Tests/AuthTests` can pin how a
/// response is judged.
struct OAuthTokenClient {
    func post(_ body: [String: String]) async throws -> OAuthToken {
        var req = URLRequest(url: Config.oauthTokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(Config.userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        return try Self.interpret(statusCode: status, data: data)
    }

    /// Status code + body → token, or the `AuthError.tokenError`
    /// classification for anything that isn't a 200 carrying `access_token`.
    static func interpret(statusCode: Int, data: Data, now: Date = Date()) throws -> OAuthToken {
        guard statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String
        else {
            throw AuthError.tokenError(status: statusCode, body: data)
        }

        var expires: Date?
        if let secs = json["expires_in"] as? Double { expires = now.addingTimeInterval(secs) }
        return OAuthToken(accessToken: access,
                          refreshToken: json["refresh_token"] as? String,
                          expiresAt: expires)
    }
}
