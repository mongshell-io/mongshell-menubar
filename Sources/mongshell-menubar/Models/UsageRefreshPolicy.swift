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

/// A renewed own token the Keychain has not taken yet (#108). The refresh
/// token is single use: once renewed, the one in the Keychain is spent, and
/// dropping the new one would end the login at the next expiry.
struct PendingOwnToken: Equatable {
    let token: OAuthToken
    /// What the Keychain holds meanwhile — the item `token` is to replace.
    let keychain: KeychainExpectation
}

/// What the Keychain item should hold while polling with a given own token.
enum KeychainExpectation: Equatable {
    case holds(refreshToken: String?)
    /// A save of ours deleted the item and could not add the new one: an
    /// empty Keychain is then our doing, not a sign-out (#108).
    case maybeEmpty
}

/// What to do with a renewed own token.
enum AdoptStep: Equatable {
    /// The Keychain is as the refresh found it: store the new one.
    case store
    /// The Keychain cannot say: keep the new one in memory.
    case hold
    /// A sign-in, a sign-out or another instance moved things on.
    case drop
}

/// Whether the Keychain still holds the own token a refresh started from.
enum KeychainMatch: Equatable {
    case current
    /// Another sign-in, a sign-out or another instance has moved it on.
    case changed
    /// Locked or refused — it cannot say.
    case unknown
}

/// What to do with a pending own token at the start of a refresh.
enum PendingResolution: Equatable {
    case none
    /// The Keychain is back and still holds the spent token: store this one.
    case save(OAuthToken)
    /// The Keychain still cannot say: poll with this one, keep it pending.
    case useInMemory(OAuthToken)
    /// The Keychain moved on: the pending token must not overwrite it.
    case drop
}

/// What came of one refresh of the own token — before polling with an
/// expired one, or after a 401. Both paths read it through this policy.
enum OwnTokenRenewal: Equatable {
    case renewed(OAuthToken)
    /// The server rejected the refresh token for good — keeping it only
    /// buys a 400 every poll and blocks the CLI-token fallback.
    case sessionExpired
    /// Network or server trouble; the token may still be fine, so keep it.
    case transientFailure
}

enum UpFrontStep: Equatable {
    /// Poll with the new token.
    case useRenewed(OAuthToken)
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
    static func keychainMatch(own: OwnTokenLookup, expects: KeychainExpectation) -> KeychainMatch {
        switch (own, expects) {
        case (.unavailable, _), (.refused, _): return .unknown
        case (.found(let token), .holds(let refreshToken)): return token.refreshToken == refreshToken ? .current : .changed
        case (.missing, .holds): return .changed
        case (.found, .maybeEmpty): return .changed
        case (.missing, .maybeEmpty): return .current
        }
    }

    /// While polling with a held renewal, the Keychain still holds what that
    /// renewal is to replace; otherwise it holds the polling token itself.
    static func expectation(pending: PendingOwnToken?, polling token: OAuthToken) -> KeychainExpectation {
        if let pending, pending.token == token { return pending.keychain }
        return .holds(refreshToken: token.refreshToken)
    }

    /// `sameLogin` is false when a sign-in or sign-out happened while the
    /// refresh was out — it wins whatever the Keychain says (#108).
    static func adopt(match: KeychainMatch, sameLogin: Bool) -> AdoptStep {
        guard sameLogin else { return .drop }
        switch match {
        case .current: return .store
        case .unknown: return .hold
        case .changed: return .drop
        }
    }

    /// What stays held after a renewal was stored (`save`) or held without
    /// trying (`save` nil). `expected` is what the Keychain held before.
    static func pending(after save: OwnTokenSave?, renewed: OAuthToken,
                        expected: KeychainExpectation) -> PendingOwnToken? {
        switch save {
        case .saved: return nil
        case .failed, nil: return PendingOwnToken(token: renewed, keychain: expected)
        case .failedAfterDelete: return PendingOwnToken(token: renewed, keychain: .maybeEmpty)
        }
    }

    /// What stays held after a `.save` resolution tried to store `held`.
    /// The Keychain still holds what `held` was to replace — or may hold
    /// nothing, once a save of ours deleted the item (#108).
    static func pending(afterSaving held: PendingOwnToken, result: OwnTokenSave) -> PendingOwnToken? {
        pending(after: result, renewed: held.token, expected: held.keychain)
    }

    static func resolvePending(_ pending: PendingOwnToken?, own: OwnTokenLookup) -> PendingResolution {
        guard let pending else { return .none }
        // A refusal may not pass on its own, but a save can clear it — it
        // recreates an item this build may not update — so it is retried
        // every poll (#132). A refused read cannot show that the Keychain
        // moved on, and nothing new says it did: the own item is written by
        // this app alone, and a sign-in or sign-out here drops the held
        // renewal before the next poll (`signIn`/`signOut`, `adopt`'s
        // `sameLogin`). What is left is another build of the app signing in
        // while its item refuses us — accepted under the single-user,
        // single-account premise. A locked Keychain is still only waited out.
        // So is a prompt the user cancelled: that refusal was their answer,
        // and storing again every poll would put the dialog back each time.
        if case .refused(let status) = own {
            return status == errSecUserCanceled ? .useInMemory(pending.token) : .save(pending.token)
        }
        switch keychainMatch(own: own, expects: pending.keychain) {
        case .current: return .save(pending.token)
        case .changed: return .drop
        case .unknown: return .useInMemory(pending.token)
        }
    }

    static func shouldRenewUpFront(source: DataSource, tokenExpired: Bool) -> Bool {
        source == .oauthLogin && tokenExpired
    }

    static func step(afterUpFront renewal: OwnTokenRenewal) -> UpFrontStep {
        switch renewal {
        case .renewed(let token): return .useRenewed(token)
        case .sessionExpired: return .expireSession
        case .transientFailure: return .pollAnyway
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

    /// A held renewal the refresh is storing or keeps in memory is polled
    /// with ahead of whatever the Keychain read said (#108).
    static func chooseToken(resolution: PendingResolution, own: OwnTokenLookup,
                            cli: () -> OAuthToken?) -> UsageTokenChoice {
        switch resolution {
        case .save(let token), .useInMemory(let token): return .token(token, .oauthLogin)
        case .none, .drop: return chooseToken(own: own, cli: cli)
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
