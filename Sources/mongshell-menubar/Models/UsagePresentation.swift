import Foundation

/// What the usage surfaces show and offer for a state (#104). Wording and
/// colors stay in the views; this decides the badge, the banner, the button
/// on it, the settings' account row and whether "로그아웃" is offered — the
/// choices #90 got wrong while each view switched on `loadState` by itself.
struct UsagePresentation: Equatable {
    enum Badge: Equatable {
        case connected, syncing, sample, limited, failed
    }

    /// The banner under the popover header; `.none` when cleanly loaded with
    /// the app's own login.
    enum Banner: Equatable {
        case none
        case signedOut
        case sessionExpired
        case loading
        case rateLimited(retryAt: Date)
        case failed(String)
        case cliAccount
        /// Loaded, but the 5-hour or weekly limit was missing from the
        /// response — its gauge is grey, not 0% (#130).
        case unreadLimits
        /// The user declined the own-token Keychain prompt and the app
        /// remembers it (#143): says so, and what is shown meanwhile (#146).
        /// `limitsUnread` carries the format notice it takes the place of,
        /// so a grey gauge keeps its reason.
        case keychainDeclined(DeclinedFallback, limitsUnread: Bool)
    }

    /// What the popover shows while the own item goes unread (#146).
    enum DeclinedFallback: Equatable {
        /// The Claude Code CLI account — possibly not the app's login.
        case cliAccount
        /// An own token the Keychain did not take, held in memory — a
        /// renewal (#108) or a sign-in (#151).
        case heldLogin
        case sample
    }

    enum BannerAction: Equatable {
        case none, signIn, retry
        /// Ask the Keychain again — the manual refresh, which lifts the
        /// remembered decline (#143).
        case allowKeychain
    }

    /// The settings' account row.
    enum Account: Equatable {
        case ownLogin, cliAccount, signedOut
    }

    let badge: Badge
    let banner: Banner
    let account: Account
    /// When the popover's manual refresh opens again, nil while it is open
    /// (#86).
    let manualRefreshBlockedUntil: Date?

    var bannerAction: BannerAction {
        switch banner {
        case .signedOut, .sessionExpired: return .signIn
        case .failed: return .retry
        case .keychainDeclined: return .allowKeychain
        // Asking again would read the same shape; the next poll does anyway.
        case .none, .loading, .rateLimited, .cliAccount, .unreadLimits: return .none
        }
    }

    /// Only the app's own login can be signed out of, and it can whatever
    /// the connection is doing — a 429, an error or a fetch in flight (#90).
    var offersSignOut: Bool { account == .ownLogin }

    /// `limitsUnread` is `UsageSnapshot.hasUnreadLimit` of the snapshot on
    /// screen. It outranks the CLI-account notice — a gauge with no value is
    /// what needs explaining — but not the states that have their own banner.
    ///
    /// `keychainDeclined` is the remembered decline (#143). Its banner takes
    /// the place of what is shown in its stead — the sample, the CLI
    /// account, a held renewal — and of the format notice: whose numbers
    /// these are, and the button that ends it, come first (#146); the format
    /// notice rides along on it rather than going unsaid. It stays
    /// under the states that already speak for this poll: a lapsed login
    /// (signing in also asks again), loading, a rate limit (the manual
    /// refresh behind its button is blocked until then) and an error (its
    /// retry is that same refresh).
    ///
    /// `cliKeychainDeclined` is the remembered decline of the Claude Code
    /// CLI item's prompt (#155). It only speaks where it is the reason for
    /// what is shown — the sample, with nothing to poll with — and says it
    /// with the same banner: the CLI account it would have shown is not up,
    /// and [다시 허용] asks both items again. A CLI token that still came
    /// from its file, or the own login, leaves it unsaid.
    ///
    /// `holdsUnsavedLogin` is whether the model holds an own token the
    /// Keychain did not take (`UsageModel.pendingOwnToken`). Under a decline
    /// the own login is polled only through that token, so it — not a
    /// `.loaded(.oauthLogin)` left on screen — says the held login is what
    /// is shown. Without one, that state is a poll that read the decline and
    /// is falling through to the CLI token or the sample; until it lands the
    /// banner is the one a clean load shows (#151, #156).
    init(loadState: LoadState, accountSource: DataSource?, limitsUnread: Bool,
         keychainDeclined: Bool, cliKeychainDeclined: Bool, holdsUnsavedLogin: Bool, now: Date) {
        switch loadState {
        case .loaded:                     badge = .connected
        case .loading:                    badge = .syncing
        case .signedOut, .sessionExpired: badge = .sample
        case .rateLimited:                badge = .limited
        case .error:                      badge = .failed
        }
        switch loadState {
        case .signedOut where keychainDeclined || cliKeychainDeclined:
            banner = .keychainDeclined(.sample, limitsUnread: false)
        case .signedOut:                  banner = .signedOut
        case .sessionExpired:             banner = .sessionExpired
        case .loading:                    banner = .loading
        case .rateLimited(let retryAt):   banner = .rateLimited(retryAt: retryAt)
        case .error(let message):         banner = .failed(message)
        case .loaded(.claudeCodeCLI) where keychainDeclined:
            banner = .keychainDeclined(.cliAccount, limitsUnread: limitsUnread)
        case .loaded(.oauthLogin) where keychainDeclined && holdsUnsavedLogin:
            banner = .keychainDeclined(.heldLogin, limitsUnread: limitsUnread)
        case .loaded(.sample) where keychainDeclined:
            banner = .keychainDeclined(.sample, limitsUnread: limitsUnread)
        case .loaded where limitsUnread:  banner = .unreadLimits
        case .loaded(.claudeCodeCLI):     banner = .cliAccount
        case .loaded:                     banner = .none
        }
        switch accountSource {
        case .oauthLogin:    account = .ownLogin
        case .claudeCodeCLI: account = .cliAccount
        case .sample, nil:   account = .signedOut
        }
        manualRefreshBlockedUntil = UsageRetryPolicy.manualRefreshBlocked(until: loadState, now: now)
    }
}
