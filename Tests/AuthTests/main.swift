import Foundation

// Regression tests for the OAuth token path.
//
// Pinned here: how a token-endpoint response becomes a token, and the
// classification that decides whether a dead refresh token is discarded
// (invalid_grant) or kept (anything else). Getting this wrong either leaves a dead token retrying every poll (the bug this
// pins) or throws away a live token on a transient error. Also the Keychain
// decoding of tokens saved before `signedInAt` existed, and the age format
// the diagnostic log prints.
//
// Run with `./scripts/test.sh`, which compiles this against the real sources.

var failures: [String] = []

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "  ok  " : " FAIL ") \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !ok { failures.append(label) }
}

func body(_ s: String) -> Data { Data(s.utf8) }

// MARK: invalid_grant classification

do {
    let err = AuthError.tokenError(
        status: 400,
        body: body(#"{"error":"invalid_grant","error_description":"Refresh token expired"}"#))
    if case .invalidGrant(let desc) = err {
        check("400 invalid_grant → invalidGrant", true)
        check("invalidGrant carries error_description", desc == "Refresh token expired", desc)
    } else {
        check("400 invalid_grant → invalidGrant", false, "\(err)")
    }
}

do {
    let err = AuthError.tokenError(status: 400, body: body(#"{"error":"invalid_grant"}"#))
    if case .invalidGrant(let desc) = err {
        check("invalid_grant without description → empty description", desc.isEmpty, desc)
    } else {
        check("invalid_grant without description → invalidGrant", false, "\(err)")
    }
}

do {
    let err = AuthError.tokenError(status: 400, body: body(#"{"error":"invalid_request"}"#))
    if case .tokenExchangeFailed(let detail) = err {
        check("400 other error → tokenExchangeFailed (token kept)", true)
        check("detail names status and error field only",
              detail == "status=400 error=invalid_request", detail)
    } else {
        check("400 other error → tokenExchangeFailed (token kept)", false, "\(err)")
    }
}

do {
    // Only a 400 says the grant itself is dead; a 5xx echoing the same word is
    // not a verdict on our token.
    let err = AuthError.tokenError(status: 503, body: body(#"{"error":"invalid_grant"}"#))
    if case .tokenExchangeFailed = err {
        check("503 with invalid_grant body → tokenExchangeFailed (token kept)", true)
    } else {
        check("503 with invalid_grant body → tokenExchangeFailed (token kept)", false, "\(err)")
    }
}

do {
    let err = AuthError.tokenError(status: 400, body: body("<html>bad gateway</html>"))
    if case .tokenExchangeFailed(let detail) = err {
        check("non-JSON body → tokenExchangeFailed", true)
        check("non-JSON detail carries status", detail.contains("400"), detail)
    } else {
        check("non-JSON body → tokenExchangeFailed", false, "\(err)")
    }
}

do {
    let err = AuthError.tokenError(status: -1, body: Data())
    if case .tokenExchangeFailed = err {
        check("empty body → tokenExchangeFailed", true)
    } else {
        check("empty body → tokenExchangeFailed", false, "\(err)")
    }
}

check("invalidGrant has a Korean user message",
      AuthError.invalidGrant("x").errorDescription?.contains("다시 로그인") == true)

check("invalidGrant log summary names the error and description",
      AuthError.invalidGrant("Refresh token expired").logSummary
          == "status=400 error=invalid_grant (Refresh token expired)")

// MARK: token response → token or classification

func interpretError(_ status: Int, _ data: Data) -> AuthError? {
    do {
        _ = try OAuthTokenClient.interpret(statusCode: status, data: data)
        return nil
    } catch {
        return error as? AuthError
    }
}

do {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let token = try? OAuthTokenClient.interpret(
        statusCode: 200,
        data: body(#"{"access_token":"acc","refresh_token":"ref","expires_in":3600,"token_type":"Bearer"}"#),
        now: now)
    check("200 with access_token → token", token?.accessToken == "acc")
    check("200 carries refresh_token", token?.refreshToken == "ref")
    check("expires_in counts from now", token?.expiresAt == now.addingTimeInterval(3600))
    check("signedInAt is left to the caller", token != nil && token?.signedInAt == nil)

    let bare = try? OAuthTokenClient.interpret(statusCode: 200, data: body(#"{"access_token":"acc"}"#))
    check("200 without refresh_token/expires_in still yields a token",
          bare?.accessToken == "acc" && bare?.refreshToken == nil && bare?.expiresAt == nil)
}

do {
    if case .tokenExchangeFailed = interpretError(200, body(#"{"token_type":"Bearer"}"#)) {
        check("200 without access_token → tokenExchangeFailed", true)
    } else {
        check("200 without access_token → tokenExchangeFailed", false)
    }
    if case .tokenExchangeFailed = interpretError(200, body("<html>ok</html>")) {
        check("200 with a non-JSON body → tokenExchangeFailed", true)
    } else {
        check("200 with a non-JSON body → tokenExchangeFailed", false)
    }
    // A 2xx other than 200 is not a token, even with one in the body.
    if case .tokenExchangeFailed = interpretError(201, body(#"{"access_token":"acc"}"#)) {
        check("201 with access_token → tokenExchangeFailed", true)
    } else {
        check("201 with access_token → tokenExchangeFailed", false)
    }
    // A 200 in a shape we don't read is most likely still a token response:
    // nothing of its body may reach the log line or the user-facing message.
    let wrapped = interpretError(200, body(#"{"data":{"access_token":"SECRET","refresh_token":"SECRET"}}"#))
    if case .tokenExchangeFailed(let detail) = wrapped {
        check("200 in an unknown shape → detail names the keys only", detail == "status=200 keys=data", detail)
    } else {
        check("200 in an unknown shape → tokenExchangeFailed", false, String(describing: wrapped))
    }
    check("200 in an unknown shape leaks nothing into the log line",
          wrapped?.logSummary.contains("SECRET") == false)
    check("200 in an unknown shape leaks nothing into the user message",
          wrapped?.errorDescription?.contains("SECRET") == false)
    let flat = interpretError(200, body(#"{"accessToken":"SECRET"}"#))
    check("200 with a renamed token key → key name, not the value",
          flat?.logSummary == "status=200 keys=accessToken", flat?.logSummary ?? "nil")
    let raw = interpretError(200, body("SECRET"))
    check("200 with a non-JSON body → size only",
          raw?.logSummary == "status=200 body=6 bytes", raw?.logSummary ?? "nil")

    if case .invalidGrant = interpretError(400, body(#"{"error":"invalid_grant"}"#)) {
        check("400 invalid_grant reaches invalidGrant through interpret", true)
    } else {
        check("400 invalid_grant reaches invalidGrant through interpret", false)
    }
}

// MARK: transport — which bodies are read, and the real shape fits the cap

do {
    check("200 reads the body (the token)", OAuthTokenClient.readsBody(statusCode: 200))
    // invalid_grant is judged from the 400 body; judged on the code alone it
    // would keep retrying a dead refresh token every poll.
    check("400 reads the body (invalid_grant lives there)", OAuthTokenClient.readsBody(statusCode: 400))
    check("401 reads the body (invalid_client)", OAuthTokenClient.readsBody(statusCode: 401))
    check("3xx/403/429/5xx are judged on the code alone",
          [301, 302, 307, 308, 403, 429, 500, 503].allSatisfy { !OAuthTokenClient.readsBody(statusCode: $0) })

    // The shape the endpoint returns, with token-length strings.
    let access = String(repeating: "a", count: 108)
    let refresh = String(repeating: "r", count: 108)
    let real = body(#"{"token_type":"Bearer","access_token":"\#(access)","expires_in":28800,"#
        + #""refresh_token":"\#(refresh)","scope":"user:inference user:profile"}"#)
    check("real-shaped token response is far under the cap",
          Int64(real.count) * 16 < Config.oauthTokenMaxResponseBytes,
          "\(real.count) bytes vs \(Config.oauthTokenMaxResponseBytes)")
}

do {
    // A refused redirect comes back as the 3xx itself with no body read. It
    // must not pass for a token, and must not throw the token away either.
    let err = interpretError(307, Data())
    if case .tokenExchangeFailed(let detail) = err {
        check("307 handed back by the refused redirect → tokenExchangeFailed (token kept)", true)
        check("307 detail carries the status", detail == "status=307 body=", detail)
    } else {
        check("307 handed back by the refused redirect → tokenExchangeFailed (token kept)", false,
              String(describing: err))
    }
}

// MARK: OAuthToken Keychain decoding

do {
    // A token saved by a build that predates `signedInAt`.
    let legacy = body(#"{"accessToken":"a","refreshToken":"r","expiresAt":1000}"#)
    let token = try? JSONDecoder().decode(OAuthToken.self, from: legacy)
    check("legacy token without signedInAt still decodes", token != nil)
    check("legacy token has nil signedInAt", token?.signedInAt == nil)
    check("legacy token keeps its fields", token?.accessToken == "a" && token?.refreshToken == "r")
}

do {
    let signedIn = Date(timeIntervalSince1970: 1_700_000_000)
    let original = OAuthToken(accessToken: "a", refreshToken: "r", expiresAt: nil, signedInAt: signedIn)
    let data = try! JSONEncoder().encode(original)
    let decoded = try? JSONDecoder().decode(OAuthToken.self, from: data)
    check("signedInAt survives an encode/decode round trip", decoded == original)
}

// MARK: Diagnostic log formatting

do {
    let start = Date(timeIntervalSince1970: 0)
    check("age 0 → 0d0h", AuthDebugLog.age(from: start, to: start) == "0d0h")
    check("age 1d3h", AuthDebugLog.age(from: start, to: start.addingTimeInterval(27 * 3600)) == "1d3h")
    check("age rounds hours down",
          AuthDebugLog.age(from: start, to: start.addingTimeInterval(27 * 3600 + 3599)) == "1d3h")
    check("age never negative", AuthDebugLog.age(from: start.addingTimeInterval(60), to: start) == "0d0h")

    let token = OAuthToken(accessToken: "a", refreshToken: nil, expiresAt: nil, signedInAt: nil)
    check("session without signedInAt says unknown", AuthDebugLog.session(token) == "signed_in=unknown")
    var dated = token
    dated.signedInAt = start
    let line = AuthDebugLog.session(dated, now: start.addingTimeInterval(49 * 3600))
    check("session line carries signed_in and age",
          line.hasPrefix("signed_in=") && line.hasSuffix(" age=2d1h"), line)
    check("session line never contains the token", !line.contains("a\"") && !line.contains("accessToken"))
}

// MARK: result

if failures.isEmpty {
    print("\nAuth tests: all passed")
    exit(0)
} else {
    print("\nAuth tests: \(failures.count) failed")
    failures.forEach { print("  - \($0)") }
    exit(1)
}
