import Foundation

/// What the GitHub connection surfaces show and offer for a state (#117),
/// the GitHub counterpart of `UsagePresentation`. Wording and colors stay in
/// the views; this decides the popover's badge, its banner and the button on
/// it, and the settings' token row and its button — choices each view used
/// to make by switching on `loadState` itself.
struct GitHubPresentation: Equatable {
    enum Badge: Equatable {
        case syncing, connected, noToken, denied, limited, unauthorized, failed
    }

    /// The banner under the popover header.
    enum Banner: Equatable {
        case loading
        case ghAccount(String)
        case pat
        case noToken
        case keychainDenied
        case rateLimited(retryAt: Date)
        case unauthorized
        case patSaveFailed(OSStatus)
        case failed(String)
    }

    enum BannerAction: Equatable {
        case none, openSettings, retryGHKeychain, retry
    }

    /// The settings' token row. `rejected` is a 401 on that token.
    enum Token: Equatable {
        case pat(rejected: Bool)
        /// A PAT just given could not be stored (#124). What the Keychain
        /// holds now is unknown — the save may have deleted the old item, or
        /// failed to (locked, refused, an item another build owns) — but it
        /// is not the token just given, so nothing is shown as "in use". No
        /// clear button: clearing is the same delete that just failed. The
        /// next refresh reads the Keychain again and the row follows it.
        case patSaveFailed(OSStatus)
        case ghAccount(String, rejected: Bool)
        case keychainDenied
        case checking
        case none
    }

    enum TokenAction: Equatable {
        case none, clearPAT, retryGHKeychain
    }

    let badge: Badge
    let banner: Banner
    let token: Token

    var bannerAction: BannerAction {
        switch banner {
        case .noToken:                                  return .openSettings
        case .keychainDenied:                           return .retryGHKeychain
        case .unauthorized, .patSaveFailed, .failed:    return .retry
        case .loading, .ghAccount, .pat, .rateLimited:  return .none
        }
    }

    /// A PAT can be cleared whatever the connection is doing; gh's item is
    /// retried only while it was refused.
    var tokenAction: TokenAction {
        switch token {
        case .pat:                         return .clearPAT
        case .keychainDenied:              return .retryGHKeychain
        case .ghAccount, .patSaveFailed, .checking, .none: return .none
        }
    }

    init(loadState: GitHubLoadState, tokenSource: GitHubTokenSource?) {
        switch loadState {
        case .off, .loading:         badge = .syncing
        case .loaded:                badge = .connected
        case .noToken:               badge = .noToken
        case .keychainDenied:        badge = .denied
        case .rateLimited:           badge = .limited
        case .unauthorized:          badge = .unauthorized
        case .patSaveFailed, .error: badge = .failed
        }
        switch loadState {
        case .off, .loading:                 banner = .loading
        case .loaded(.ghCLI(let account)):   banner = .ghAccount(account)
        case .loaded(.pat):                  banner = .pat
        case .noToken:                       banner = .noToken
        case .keychainDenied:                banner = .keychainDenied
        case .rateLimited(let retryAt):      banner = .rateLimited(retryAt: retryAt)
        case .unauthorized:                  banner = .unauthorized
        case .patSaveFailed(let status):     banner = .patSaveFailed(status)
        case .error(let message):            banner = .failed(message)
        }
        switch (tokenSource, loadState) {
        case (_, .patSaveFailed(let status)):       token = .patSaveFailed(status)
        case (.pat?, .unauthorized):                token = .pat(rejected: true)
        case (.pat?, _):                            token = .pat(rejected: false)
        case (.ghCLI(let account)?, .unauthorized): token = .ghAccount(account, rejected: true)
        case (.ghCLI(let account)?, _):             token = .ghAccount(account, rejected: false)
        case (nil, .keychainDenied):                token = .keychainDenied
        case (nil, .loading):                       token = .checking
        case (nil, _):                              token = .none
        }
    }
}
