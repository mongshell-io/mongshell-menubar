import Foundation

/// How one usage fetch ended, as far as the screen is concerned.
enum UsageFetchResult: Equatable {
    case ok(UsageSnapshot)
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    /// Network trouble, a 5xx or a body the parser could not read.
    case failed

    init(_ result: Result<UsageSnapshot, Error>) {
        switch result {
        case .success(let snap): self = .ok(snap)
        case .failure(APIError.unauthorized): self = .unauthorized
        case .failure(APIError.rateLimited(let retryAfter)): self = .rateLimited(retryAfter: retryAfter)
        case .failure: self = .failed
        }
    }
}

/// Which token a refresh polls with.
enum UsageTokenChoice: Equatable {
    case token(OAuthToken, DataSource)
    case none
    /// Our own token is there but the Keychain is locked — the CLI token
    /// would quietly switch accounts, so the refresh waits for the next poll.
    case ownUnavailable(OSStatus)
}

/// What came of refreshing an expired own token before polling with it.
enum UpFrontRenewal: Equatable {
    case renewed
    case sessionExpired
    case renewalFailed
}

enum UpFrontStep: Equatable {
    /// Poll with the new token.
    case useRenewed
    case expireSession
    /// Poll with the expired token anyway — a refresh blip is no reason to
    /// stop, and a 401 then earns the usual one refresh.
    case pollAnyway
}

/// What came of the one own-token refresh a 401 earns.
enum OwnTokenRetry: Equatable {
    /// The refresh worked and the usage was asked again with the new token.
    case refetched(UsageFetchResult)
    /// The server rejected the refresh token for good (`invalid_grant`).
    case sessionExpired
    /// Network or server trouble on the refresh; the token may still be fine.
    case renewalFailed
}

/// What the model shows at the end of a refresh.
enum UsageRefreshStep: Equatable {
    /// Show the numbers and check the usage thresholds (#95).
    case show(UsageSnapshot)
    /// Reject the last token tried and show signed-out.
    case signOut
    /// Drop the own token and show the lapsed-login notice.
    case expireSession
    case rateLimited(retryAfter: TimeInterval?)
    /// Keep the account and show the error banner — the next poll tries again.
    case failed
}

/// The 401 → refresh → retry branches of a usage refresh. Three regressions
/// in a row came from these (#92, #93, #95), and the model they live in is
/// tied to the Keychain and the network, so the rules are kept here where
/// `scripts/test.sh` can pin them (#97).
enum UsageRefreshPolicy {
    static func shouldRenewUpFront(source: DataSource, tokenExpired: Bool) -> Bool {
        source == .oauthLogin && tokenExpired
    }

    static func step(afterUpFront renewal: UpFrontRenewal) -> UpFrontStep {
        switch renewal {
        case .renewed: return .useRenewed
        case .sessionExpired: return .expireSession
        case .renewalFailed: return .pollAnyway
        }
    }

    /// Only the app's own token can be refreshed; a CLI token is re-read on
    /// the next poll instead (Claude Code may have rotated it).
    static func shouldRenew(after first: UsageFetchResult, source: DataSource) -> Bool {
        first == .unauthorized && source == .oauthLogin
    }

    /// Our own token first, then the CLI token — but only when ours is
    /// missing or refused, not while the Keychain is locked (#102).
    static func chooseToken(own: OwnTokenLookup, cli: () -> OAuthToken?) -> UsageTokenChoice {
        switch own {
        case .found(let token): return .token(token, .oauthLogin)
        case .unavailable(let status): return .ownUnavailable(status)
        case .missing, .refused: return cli().map { .token($0, .claudeCodeCLI) } ?? .none
        }
    }

    /// `retry` is nil when no refresh was tried.
    static func step(after first: UsageFetchResult, retry: OwnTokenRetry?) -> UsageRefreshStep {
        switch retry {
        case nil: return step(after: first)
        // A second 401 means the account is gone; a blip on the retry is not (#93).
        case .refetched(let second): return step(after: second)
        case .sessionExpired: return .expireSession
        // The own token is still in the Keychain and may renew on the next
        // poll — signed-out here put a login button in front of a blip (#92).
        case .renewalFailed: return .failed
        }
    }

    private static func step(after result: UsageFetchResult) -> UsageRefreshStep {
        switch result {
        case .ok(let snap): return .show(snap)
        case .unauthorized: return .signOut
        case .rateLimited(let retryAfter): return .rateLimited(retryAfter: retryAfter)
        case .failed: return .failed
        }
    }
}
