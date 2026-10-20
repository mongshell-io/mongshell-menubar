import Foundation

/// Central place for the (unofficial) endpoint + OAuth parameters.
///
/// ⚠️ These target Claude's *subscription* usage, for which there is no public
/// API. Values below mirror what the Claude Code CLI uses. They are unverified
/// placeholders where noted — see Phase 0 in the plan: capture a real
/// oauth/usage response and confirm the exact client_id / headers / schema
/// before shipping. Nothing here is transmitted anywhere except Anthropic's
/// own hosts; tokens live only in the local Keychain.
enum Config {
    /// Subscription usage endpoint (same data as Claude Code `/usage`).
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// The `claude-code/<version>` User-Agent is REQUIRED — without it the
    /// endpoint drops into an aggressively rate-limited bucket (persistent 429).
    static let userAgent = "claude-code/1.0.0"

    /// OAuth beta header Claude Code sends with subscription requests.
    static let anthropicBeta = "oauth-2025-04-20"

    // MARK: OAuth (Authorization Code + PKCE)
    // These are Claude Code's own OAuth parameters. Anthropic does not issue
    // client IDs to third parties, so reusing this one is a ToS grey area
    // (see README). The manual-paste redirect below is what Claude Code uses:
    // the browser lands on a console page showing `code#state` to paste back.
    static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let oauthAuthorizeURL = URL(string: "https://claude.ai/oauth/authorize")!
    // Anthropic migrated console.anthropic.com → platform.claude.com; the
    // token exchange + callback now live on the new host.
    static let oauthTokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let oauthRedirectURI = "https://platform.claude.com/oauth/code/callback"
    static let oauthScopes = "org:create_api_key user:profile user:inference"

    // MARK: Local credential sources
    /// Keychain generic-password service name Claude Code stores its creds under.
    static let claudeCodeKeychainService = "Claude Code-credentials"
    /// Fallback file path some installs use.
    static var claudeCodeCredentialsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
    }

    /// Our own Keychain item for OAuth-login tokens.
    static let ownKeychainService = "com.mongshell.menubar.tokens"
    static let ownKeychainAccount = "oauth"

    static let minPollInterval: Int = 180

    // MARK: GitHub (Decision #45)

    /// The one host the GitHub client talks to. GraphQL, because one request
    /// carries both searches plus `rateLimit`; cost is per node, not per
    /// request, so bundling costs nothing extra.
    static let githubGraphQLURL = URL(string: "https://api.github.com/graphql")!

    /// GitHub rejects requests without a User-Agent (403). The version is the
    /// bundle's `CFBundleShortVersionString`; a bare binary (snapshot render,
    /// tests) has no bundle and sends "dev".
    static let githubUserAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "mongshell-menubar/\(version ?? "dev")"
    }()

    /// Where the gh CLI keeps its token: a generic password under this service,
    /// account = GitHub username (so lookups go by service alone). gh stores
    /// it through zalando/go-keyring, which prefixes the value with
    /// `go-keyring-base64:` + base64 (older: `go-keyring-encoded:` + hex, older
    /// still: plain) — `GitHubCredentialStore.decodeGHKeyringValue` undoes that.
    /// Read-only: the item is gh's, not ours.
    static let ghKeychainService = "gh:github.com"

    /// Our own PAT item lives under `ownKeychainService` next to the OAuth
    /// token, under this account.
    static let githubPATKeychainAccount = "github-pat"

    /// Background poll interval, seconds. 1 minute is already 60 requests an
    /// hour (each costing a few points of the 5,000/hour budget); 10 minutes
    /// is where the list stops being "current".
    static let githubPollRange = 60...600
    static let githubDefaultPollSeconds = 180
    /// While a check on one of my PRs is running, popover open or not — the
    /// hover and popover tick elapsed times every second, and the state
    /// should keep up. About 120 points an hour at one point a request.
    static let githubFastPollSeconds = 30
    /// A running check older than this no longer holds the fast cadence: a
    /// runner that never reports back would otherwise keep it forever.
    /// Most CI runs end well inside an hour; past it, base is soon enough.
    static let githubFastPollMaxRunningAge: TimeInterval = 3600
    /// How far in the future a check's start may lie and still count as
    /// fresh: a runner's clock can run a little ahead of ours. Past this the
    /// start time is not believed — counted as fresh, it would hold the
    /// fast cadence for as long as the clock stays wrong, past the age cap.
    static let githubFastPollClockSkew: TimeInterval = 300
    /// Points left at which polling backs off: enough for gh and the browser
    /// to keep working on the same token.
    static let githubRateLimitReserve = 200

    /// Rows shown per popover section; past these a trailing "외 N건" row.
    static let githubSectionCaps = (mine: 8, merged: 3)
    /// How far back "recently merged" looks.
    static let githubMergedWindowDays = 7

    /// Largest GraphQL response read. Sixty PRs with thirty check contexts
    /// each come to a few hundred KB; the cap keeps a surprising answer from
    /// filling memory.
    static let githubMaxResponseBytes: Int64 = 4 * 1024 * 1024

    /// Append-only OAuth diagnostics (`AuthDebugLog`). A debugging aid, not
    /// user data, so it lives in the per-user temporary directory ($TMPDIR —
    /// mode 0700, emptied on reboot) rather than the shared /tmp: that one is
    /// world-readable, and a fixed path there can be pre-planted as a symlink
    /// by any local user to redirect our appends.
    static let authDebugLogURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mongshell-menubar_auth.log")
}
