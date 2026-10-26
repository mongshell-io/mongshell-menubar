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
    }

    enum BannerAction: Equatable {
        case none, signIn, retry
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
        case .none, .loading, .rateLimited, .cliAccount: return .none
        }
    }

    /// Only the app's own login can be signed out of, and it can whatever
    /// the connection is doing — a 429, an error or a fetch in flight (#90).
    var offersSignOut: Bool { account == .ownLogin }

    init(loadState: LoadState, accountSource: DataSource?, now: Date) {
        switch loadState {
        case .loaded:                     badge = .connected
        case .loading:                    badge = .syncing
        case .signedOut, .sessionExpired: badge = .sample
        case .rateLimited:                badge = .limited
        case .error:                      badge = .failed
        }
        switch loadState {
        case .signedOut:                  banner = .signedOut
        case .sessionExpired:             banner = .sessionExpired
        case .loading:                    banner = .loading
        case .rateLimited(let retryAt):   banner = .rateLimited(retryAt: retryAt)
        case .error(let message):         banner = .failed(message)
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
