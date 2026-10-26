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

/// What an `invalid_grant` on the own token does, by what the Keychain says.
enum LapseStep: Equatable {
    /// The Keychain holds the dead token: delete it and show the notice.
    case discard
    /// The Keychain cannot say (locked, refused, a declined prompt): show
    /// the notice, but leave the item — it may hold another login (#147).
    case noticeOnly
    /// A sign-in, a sign-out or another instance moved it on: that stands,
    /// and no notice goes up over it.
    case leave
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
        case .failed, .cancelled, nil: return PendingOwnToken(token: renewed, keychain: expected)
        case .failedAfterDelete: return PendingOwnToken(token: renewed, keychain: .maybeEmpty)
        }
    }

    /// What stays held after a `.save` resolution tried to store `held`.
    /// The Keychain still holds what `held` was to replace — or may hold
    /// nothing, once a save of ours deleted the item (#108).
    static func pending(afterSaving held: PendingOwnToken, result: OwnTokenSave) -> PendingOwnToken? {
        pending(after: result, renewed: held.token, expected: held.keychain)
    }

    /// The login lapsed whatever the Keychain says — the server turned its
    /// refresh token away — so a Keychain that cannot answer does not hide
    /// that from the user. It only keeps the item from being deleted: a read
    /// that did not happen cannot show the item still holds that login. Left
    /// quiet, the next poll fell through to the CLI token or the sample with
    /// no word of why (#147); with a decline remembered (#143), that was
    /// every `invalid_grant`.
    static func lapse(match: KeychainMatch) -> LapseStep {
        switch match {
        case .current: return .discard
        case .unknown: return .noticeOnly
        case .changed: return .leave
        }
    }

    /// The refresh tokens a lapse announces: the dead one, and — when the
    /// item is left (`noticeOnly`) while a held renewal was the one polled —
    /// the token the item still holds. That one was spent by the renewal, so
    /// it fails the same way once the Keychain reads again; without it here
    /// the second lapse after a CLI fetch took the notice down was news, and
    /// the same notification went out twice.
    static func announcedRefreshTokens(lapsed token: OAuthToken, expected: KeychainExpectation,
                                       step: LapseStep) -> [String] {
        var tokens = token.refreshToken.map { [$0] } ?? []
        if step == .noticeOnly, case .holds(let kept?) = expected, kept != token.refreshToken {
            tokens.append(kept)
        }
        return tokens
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
        // So is a prompt the user declined: that refusal was their answer,
        // and storing again every poll would put the dialog back each time
        // (`ownLookup` keeps giving this answer until the user acts, #143).
        if case .refused(let status) = own {
            return OwnTokenLookup.isUserRefusal(status) ? .useInMemory(pending.token) : .save(pending.token)
        }
        switch keychainMatch(own: own, expects: pending.keychain) {
        case .current: return .save(pending.token)
        case .changed: return .drop
        case .unknown: return .useInMemory(pending.token)
        }
    }

    // MARK: A declined Keychain prompt (#143)

    /// What the own-token item answers when the user already declined its
    /// prompt this session: no read — a read is what would put the dialog
    /// back. Everything downstream treats it as the refusal it was: a held
    /// renewal stays in memory (`resolvePending`, `adopt` via `.unknown`),
    /// nothing held falls through to the CLI token (`chooseToken`).
    static let rememberedRefusal = OwnTokenLookup.refused(errSecUserCanceled)

    /// The own-token read for a refresh while the user's decline stands —
    /// the remembered refusal — or nil: read the Keychain.
    static func ownLookup(declined: Bool) -> OwnTokenLookup? {
        declined ? rememberedRefusal : nil
    }

    /// Whether the decline stands after this read. It is only lifted by the
    /// user acting (sign-in, sign-out, a manual refresh — [다시 허용]) or a
    /// relaunch — never by a poll, which is what kept the dialog coming back.
    ///
    /// `declined` is the flag as it is when the read comes back, not as it
    /// was when the read went out: the read runs off the main thread (#141),
    /// and a save the user cancelled meanwhile set the flag — a `.found`
    /// from the read must not lift that. `sameAllowance` is false when the
    /// user lifted the decline while the read was out
    /// (`UsageSession.declineLifts`): a cancel from before the lift setting
    /// the flag again made [다시 허용] do nothing once (#146). A sign-in or
    /// sign-out is such a lift too — every place that bumps the model's
    /// login generation bumps `declineLifts` with it — so an answer about
    /// the item from before a new login does not set the flag either.
    static func declined(_ declined: Bool, after own: OwnTokenLookup, sameAllowance: Bool) -> Bool {
        guard sameAllowance else { return declined }
        if case .refused(let status) = own, OwnTokenLookup.isUserRefusal(status) { return true }
        return declined
    }

    /// Whether the decline stands after this save — under the same rules
    /// as after a read.
    static func declined(_ declined: Bool, afterSaving result: OwnTokenSave, sameAllowance: Bool) -> Bool {
        guard sameAllowance else { return declined }
        return result == .cancelled || declined
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
        chooseToken(resolution: .none, own: own, cli: cli)
    }

    /// A held renewal the refresh is storing or keeps in memory is polled
    /// with ahead of whatever the Keychain read said (#108).
    static func chooseToken(resolution: PendingResolution, own: OwnTokenLookup,
                            cli: () -> OAuthToken?) -> UsageTokenChoice {
        ownChoice(resolution: resolution, own: own) ?? cliChoice(cli())
    }

    /// The choice `chooseToken` makes without the CLI token, or nil when the
    /// CLI token is next. Split out so the model reads that token — a
    /// Keychain read that may prompt — only then, and off the main thread
    /// (#141).
    static func ownChoice(resolution: PendingResolution, own: OwnTokenLookup) -> UsageTokenChoice? {
        switch resolution {
        case .save(let token), .useInMemory(let token): return .token(token, .oauthLogin)
        case .none, .drop: break
        }
        switch own {
        case .found(let token): return .token(token, .oauthLogin)
        case .unavailable(let status): return .ownUnavailable(status)
        case .missing, .refused: return nil
        }
    }

    static func cliChoice(_ cli: OAuthToken?) -> UsageTokenChoice {
        cli.map { .token($0, .claudeCodeCLI) } ?? .none
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
