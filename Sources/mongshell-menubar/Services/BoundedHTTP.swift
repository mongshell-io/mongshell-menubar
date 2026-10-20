import Foundation

/// The transport the read-only HTTPS clients share (`OpenClawStatusClient`,
/// `GitHubAPIClient`): a session that follows no redirect and keeps nothing on
/// disk, and a body read that gives up past a byte cap. Each client decides
/// its own cap, its own timeout and which status codes carry a body worth
/// reading — this only enforces what they decided.
enum BoundedHTTP {
    /// The body passed the caller's cap, by declared length or while
    /// streaming. Clients map this onto their own error type.
    struct ResponseTooLarge: Error, Equatable {}

    /// Ephemeral + no cache: every poll must see the resource as it is now — a
    /// cached copy would look fresh while the source is dead. Nothing
    /// (cookies, a token-bearing URL or header in a cache DB) is persisted to
    /// disk either. Redirects are refused (`RedirectRefuser`).
    static func makeSession(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        return URLSession(configuration: config, delegate: RedirectRefuser(), delegateQueue: nil)
    }

    /// Reads the body, giving up with `ResponseTooLarge` as soon as it's known
    /// to pass `maxBytes` — from the declared length when there is one,
    /// otherwise while streaming. A response whose status code the caller
    /// doesn't read a body for is returned with an empty body: the caller's
    /// `interpret` judges it on the code alone, so a large error page must
    /// still surface as its status code rather than as "too large".
    static func download(_ req: URLRequest, session: URLSession, maxBytes: Int64,
                         readsBody: (Int) -> Bool) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: req)
        if let http = response as? HTTPURLResponse, !readsBody(http.statusCode) {
            bytes.task.cancel()
            return (Data(), response)
        }
        guard !exceedsSizeLimit(response.expectedContentLength, maxBytes: maxBytes) else {
            bytes.task.cancel()
            throw ResponseTooLarge()
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if exceedsSizeLimit(Int64(data.count), maxBytes: maxBytes) {
                bytes.task.cancel()
                throw ResponseTooLarge()
            }
        }
        return (data, response)
    }

    /// Whether a byte count is over the cap. An unknown length (-1) isn't.
    static func exceedsSizeLimit(_ byteCount: Int64, maxBytes: Int64) -> Bool {
        byteCount > maxBytes
    }
}

/// Refuses every redirect. Each client talks to one host at one address, so a
/// 3xx is either a misconfiguration or something steering a token-bearing
/// request elsewhere. Returning nil hands the 3xx back as the response, which
/// the client's `interpret` reports as an HTTP error.
final class RedirectRefuser: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
