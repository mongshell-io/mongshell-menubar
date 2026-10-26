import Foundation

/// POSTs to the OAuth token endpoint (code exchange and refresh) and maps the
/// response into an `OAuthToken`. Split from `AuthService`, which pulls in
/// AppKit and the loopback server, so `Tests/AuthTests` can pin how a
/// response is judged.
///
/// The request body carries the `refresh_token`, or the `code` and its
/// `code_verifier`, so it goes through `BoundedHTTP`: no redirect is followed
/// (a 307/308 would otherwise resend that body to wherever it points),
/// nothing is cached, and the body is read only up to
/// `Config.oauthTokenMaxResponseBytes`.
struct OAuthTokenClient {
    /// The endpoint answers in well under a second. Without a bound a stalled
    /// refresh would hold the poll that is waiting on it; past this the poll
    /// reports a failure, keeps the token and tries again next time.
    static let requestTimeout: TimeInterval = 30

    private static let session = BoundedHTTP.makeSession(timeout: requestTimeout)

    func post(_ body: [String: String]) async throws -> OAuthToken {
        var req = URLRequest(url: Config.oauthTokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(Config.userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await BoundedHTTP.download(
                req, session: Self.session, maxBytes: Config.oauthTokenMaxResponseBytes,
                readsBody: Self.readsBody(statusCode:))
        } catch is BoundedHTTP.ResponseTooLarge {
            // Not a verdict on the grant, so the caller keeps the token.
            throw AuthError.tokenExchangeFailed("응답 크기 상한 초과")
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        return try Self.interpret(statusCode: status, data: data)
    }

    /// A 200 carries the token. RFC 6749 §5.2 puts OAuth error bodies on a
    /// 400 — where `AuthError.tokenError` must see `invalid_grant` to drop a
    /// dead refresh token — or on a 401 for `invalid_client`. Every other
    /// code (the 3xx a refused redirect hands back, a gateway's 403/429, a
    /// 5xx) is judged on the code alone, so a large error page still surfaces
    /// as its status rather than tripping the size cap.
    static func readsBody(statusCode: Int) -> Bool {
        statusCode == 200 || statusCode == 400 || statusCode == 401
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
        if let secs = JSONNumber.finite(json["expires_in"]) { expires = now.addingTimeInterval(secs) }
        return OAuthToken(accessToken: access,
                          refreshToken: json["refresh_token"] as? String,
                          expiresAt: expires)
    }
}
