import Foundation
import Security

// Order tests for `UsageModel` (#150): what a sign-in, a sign-out, [다시 허용]
// or another refresh does when it lands while one of the model's awaits is
// out. The pure rules are pinned in Tests/UsageTests; these pin where the
// model re-checks its login generation (and decline allowance) after each
// await, which only the model itself can show.
//
// The model runs on fake boundaries. Like `KeychainQueue`, a fake Keychain
// call takes effect in the order it was made — its answer is fixed then —
// and only the reply is held: a test holds a reply open, lets the other
// action run to its end, then releases it. Each case below names the guard
// that, removed, makes it fail.
//
// Run with `./scripts/test.sh`, which compiles this against the real
// `UsageModel.swift` and the pure types it uses.

var failures: [String] = []

@MainActor func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "  ok  " : " FAIL ") \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !ok { failures.append(label) }
}

/// A token whose access/refresh values carry `name`, expired or not.
func token(_ name: String, expired: Bool = false) -> OAuthToken {
    OAuthToken(accessToken: "a-\(name)", refreshToken: "r-\(name)",
               expiresAt: Date().addingTimeInterval(expired ? -3600 : 3600), signedInAt: nil)
}

struct TransientRefreshFailure: Error {}

/// The model's outside world. Calls are numbered per kind from 1; a key such
/// as `"lookup#2"` in `holds` keeps that call's reply until `release`.
@MainActor final class Fake {
    /// The own-token Keychain item.
    var own: OAuthToken?
    var cli: OAuthToken?
    /// What the CLI file holds — read when the Keychain item gives nothing
    /// or is not asked (#155).
    var cliFile: OAuthToken?
    /// The nth read of the CLI Keychain item whose prompt the user declines.
    var cliDeclines: Set<Int> = []
    /// Replies for the nth own-token read, in place of what the item holds.
    var lookupReplies: [Int: OwnTokenLookup] = [:]
    /// Replies for the nth own-token save; missing means `.saved`.
    var saveReplies: [Int: OwnTokenSave] = [:]
    /// Replies for the nth delete; missing means it worked.
    var clearReplies: [Int: Bool] = [:]
    /// What `refresh` turns an access token into; missing means `invalid_grant`.
    var renewals: [String: OAuthToken] = [:]
    var signInToken: OAuthToken?

    var holds: Set<String> = []
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]

    private(set) var lookups = 0
    private(set) var saved: [String] = []
    private(set) var clears = 0
    private(set) var cliReads = 0
    /// CLI reads that asked the Keychain item — each could prompt.
    private(set) var cliKeychainReads = 0
    private(set) var renewCalls = 0
    private(set) var fetched: [String] = []
    private(set) var expiryNotices = 0

    func isHeld(_ key: String) -> Bool { waiting[key] != nil }

    func release(_ key: String) {
        holds.remove(key)
        waiting.removeValue(forKey: key)?.resume()
    }

    private func pass(_ key: String) async {
        guard holds.contains(key) else { return }
        await withCheckedContinuation { waiting[key] = $0 }
    }

    func lookup() async -> OwnTokenLookup {
        lookups += 1
        let n = lookups
        let reply = lookupReplies[n] ?? own.map(OwnTokenLookup.found) ?? .missing
        await pass("lookup#\(n)")
        return reply
    }

    func save(_ token: OAuthToken) async -> OwnTokenSave {
        saved.append(token.accessToken)
        let n = saved.count
        let reply = saveReplies[n] ?? .saved
        switch reply {
        case .saved: own = token
        case .failedAfterDelete: own = nil
        case .failed, .cancelled: break
        }
        await pass("save#\(n)")
        return reply
    }

    func clear() async -> Bool {
        clears += 1
        let n = clears
        let reply = clearReplies[n] ?? true
        if reply { own = nil }
        await pass("clear#\(n)")
        return reply
    }

    func readCLI(readingKeychain: Bool) async -> ClaudeCodeTokenRead {
        cliReads += 1
        let n = cliReads
        var keychain: OAuthToken?
        var declined = false
        if readingKeychain {
            cliKeychainReads += 1
            if cliDeclines.contains(cliKeychainReads) { declined = true } else { keychain = cli }
        }
        let reply = ClaudeCodeTokenRead(token: keychain ?? cliFile, keychainDeclined: declined)
        await pass("cli#\(n)")
        return reply
    }

    func renew(_ token: OAuthToken) async throws -> OAuthToken {
        renewCalls += 1
        await pass("refresh#\(renewCalls)")
        guard let renewed = renewals[token.accessToken] else { throw AuthError.invalidGrant("test") }
        return renewed
    }

    func fetch(_ token: OAuthToken) async -> UsageSnapshot {
        fetched.append(token.accessToken)
        await pass("fetch#\(fetched.count)")
        return .sample(now: Date())
    }

    func signIn() throws -> OAuthToken {
        guard let signInToken else { throw AuthError.cancelled }
        return signInToken
    }

    var boundaries: UsageModel.Boundaries {
        UsageModel.Boundaries(
            lookupOwnToken: { await self.lookup() },
            saveOwnToken: { await self.save($0) },
            clearOwnToken: { await self.clear() },
            loadClaudeCodeToken: { await self.readCLI(readingKeychain: $0) },
            signIn: { try self.signIn() },
            refresh: { try await self.renew($0) },
            fetchUsage: { await self.fetch($0) },
            notificationsAvailable: { true },
            requestNotificationAuthorization: {},
            postNotification: { _, _, _ in },
            postNotificationAfterAuthorizing: { identifier, _, _ in
                if identifier == "mongshell-menubar-session-expired" { self.expiryNotices += 1 }
            },
            // Threshold notices are pinned in Tests/UsageTests.
            notifyThresholds: { false },
            pollIntervalSeconds: { Config.minPollInterval })
    }
}

/// Lets the other main-actor tasks run until `done` holds. Every fake reply
/// is immediate unless held, so this only waits for scheduling.
@MainActor func until(_ what: String, _ done: () -> Bool) async {
    for _ in 0..<100_000 {
        if done() { return }
        await Task.yield()
    }
    check("reached: \(what)", false)
}

/// Gives queued main-actor tasks (a `refreshNow()` refresh) their turn.
@MainActor func settle() async {
    for _ in 0..<1_000 { await Task.yield() }
}

@MainActor func run() async {
    // MARK: (a) a sign-out lands while a refresh's read is out

    do {
        // Removing the generation check right after `lookupOwnToken` in
        // `performRefresh`: the refresh goes on to read the CLI item, which
        // can put up a Keychain prompt after the user signed out.
        let fake = Fake()
        fake.cli = token("C")
        fake.holds = ["lookup#1"]
        let model = UsageModel(boundaries: fake.boundaries)
        let refresh = Task { await model.refreshOnce() }
        await until("own read held") { fake.isHeld("lookup#1") }
        await model.signOut()
        fake.release("lookup#1")
        await refresh.value
        check("(a) sign-out during the own read: no CLI read, no fetch, signed out",
              fake.cliReads == 0 && fake.fetched.isEmpty && model.loadState == .signedOut,
              "cliReads=\(fake.cliReads) fetched=\(fake.fetched) state=\(model.loadState)")
    }

    do {
        // Removing the check after `currentToken`: the CLI token is polled
        // and shown after the sign-out.
        let fake = Fake()
        fake.cli = token("C")
        fake.holds = ["cli#1"]
        let model = UsageModel(boundaries: fake.boundaries)
        let refresh = Task { await model.refreshOnce() }
        await until("CLI read held") { fake.isHeld("cli#1") }
        await model.signOut()
        fake.release("cli#1")
        await refresh.value
        check("(a) sign-out during the CLI read: nothing fetched or shown",
              fake.fetched.isEmpty && model.loadState == .signedOut && model.accountSource == nil,
              "fetched=\(fake.fetched) state=\(model.loadState)")
    }

    do {
        // Removing the check before `apply`: the numbers fetched with the
        // signed-out token are shown as loaded.
        let fake = Fake()
        fake.own = token("T")
        fake.holds = ["fetch#1"]
        let model = UsageModel(boundaries: fake.boundaries)
        let refresh = Task { await model.refreshOnce() }
        await until("fetch held") { fake.isHeld("fetch#1") }
        await model.signOut()
        fake.release("fetch#1")
        await refresh.value
        check("(a) sign-out during the fetch: its numbers are not shown",
              model.loadState == .signedOut && model.accountSource == nil && fake.saved.isEmpty,
              "state=\(model.loadState) saved=\(fake.saved)")
    }

    // MARK: (b) a sign-in lands while a renewal is being adopted

    do {
        // Removing the check after the save in `adoptRenewed`: the refresh
        // goes on polling with the renewal the sign-in replaced.
        let fake = Fake()
        fake.own = token("T", expired: true)
        fake.renewals = ["a-T": token("R")]
        fake.signInToken = token("N")
        fake.holds = ["save#1"]
        let model = UsageModel(boundaries: fake.boundaries)
        let refresh = Task { await model.refreshOnce() }
        await until("renewal save held") { fake.isHeld("save#1") }
        await model.signIn()
        fake.release("save#1")
        await refresh.value
        check("(b) sign-in during the renewal's save: the new login stays, the renewal is not used",
              fake.own?.accessToken == "a-N" && fake.fetched == ["a-N"]
                  && model.loadState == .loaded(.oauthLogin),
              "own=\(fake.own?.accessToken ?? "nil") fetched=\(fake.fetched) state=\(model.loadState)")
    }

    do {
        // Passing `sameLogin: true` to `adopt` in `adoptRenewed`: the
        // renewal is saved over the fresh login.
        let fake = Fake()
        fake.own = token("T", expired: true)
        fake.renewals = ["a-T": token("R")]
        fake.signInToken = token("N")
        fake.holds = ["lookup#2"]
        let model = UsageModel(boundaries: fake.boundaries)
        let refresh = Task { await model.refreshOnce() }
        await until("adopt's Keychain check held") { fake.isHeld("lookup#2") }
        await model.signIn()
        fake.release("lookup#2")
        await refresh.value
        check("(b) sign-in during adopt's Keychain check: the renewal is dropped, not saved",
              fake.own?.accessToken == "a-N" && fake.saved == ["a-N"] && fake.fetched == ["a-N"],
              "own=\(fake.own?.accessToken ?? "nil") saved=\(fake.saved) fetched=\(fake.fetched)")
    }

    // MARK: (c) a sign-in lands while a lapsed login is being dropped

    do {
        // Removing the check after the match in `expireSession`: the dead
        // token's delete runs after the sign-in and deletes the new login.
        let fake = Fake()
        fake.own = token("T", expired: true)
        fake.signInToken = token("N")
        fake.holds = ["lookup#2"]
        let model = UsageModel(boundaries: fake.boundaries)
        let refresh = Task { await model.refreshOnce() }
        await until("expireSession's Keychain check held") { fake.isHeld("lookup#2") }
        await model.signIn()
        fake.release("lookup#2")
        await refresh.value
        check("(c) sign-in during expireSession's check: the new login is not deleted, no notice",
              fake.clears == 0 && fake.own?.accessToken == "a-N" && fake.expiryNotices == 0
                  && model.loadState == .loaded(.oauthLogin),
              "clears=\(fake.clears) own=\(fake.own?.accessToken ?? "nil") notices=\(fake.expiryNotices) state=\(model.loadState)")
    }

    do {
        // Removing the check after the delete in `expireSession`: the
        // lapsed notice and its notification go up over the new login.
        let fake = Fake()
        fake.own = token("T", expired: true)
        fake.signInToken = token("N")
        fake.holds = ["clear#1"]
        let model = UsageModel(boundaries: fake.boundaries)
        let refresh = Task { await model.refreshOnce() }
        await until("dead token's delete held") { fake.isHeld("clear#1") }
        await model.signIn()
        fake.release("clear#1")
        await refresh.value
        check("(c) sign-in during the dead token's delete: its save stands, no lapse notice",
              fake.own?.accessToken == "a-N" && fake.expiryNotices == 0 && model.loadState == .loaded(.oauthLogin),
              "own=\(fake.own?.accessToken ?? "nil") notices=\(fake.expiryNotices) state=\(model.loadState)")
    }

    // MARK: (d) [다시 허용] while a read that the user cancelled is out

    do {
        // Passing `sameAllowance: true` in `lookupOwnToken`: the cancel from
        // before [다시 허용] is remembered again, and the next read is
        // skipped — the button did nothing.
        let fake = Fake()
        fake.own = token("T")
        fake.lookupReplies = [1: .refused(errSecUserCanceled)]
        fake.holds = ["lookup#1"]
        let model = UsageModel(boundaries: fake.boundaries)
        let refresh = Task { await model.refreshOnce() }
        await until("cancelled read held") { fake.isHeld("lookup#1") }
        model.refreshNow()
        await settle()
        fake.release("lookup#1")
        await refresh.value
        await settle()
        check("(d) [다시 허용] during a cancelled read: the decline is not brought back, the Keychain is read again",
              !model.keychainDeclined && fake.lookups == 2 && model.loadState == .loaded(.oauthLogin),
              "declined=\(model.keychainDeclined) lookups=\(fake.lookups) state=\(model.loadState)")
    }

    // MARK: every login-generation bump is a decline lift too

    do {
        // `declined` folds in by allowance alone, so a sign-out that bumps
        // the login generation without `declineLifts` (in
        // `UsageSession.signedOut`) lets the cancel from before it be
        // remembered — over the sign-out that should have cleared it.
        let fake = Fake()
        fake.own = token("T")
        fake.lookupReplies = [1: .refused(errSecUserCanceled)]
        fake.holds = ["lookup#1"]
        let model = UsageModel(boundaries: fake.boundaries)
        let refresh = Task { await model.refreshOnce() }
        await until("cancelled read held") { fake.isHeld("lookup#1") }
        await model.signOut()
        fake.release("lookup#1")
        await refresh.value
        check("sign-out during a cancelled read: the decline is not remembered",
              !model.keychainDeclined && model.loadState == .signedOut,
              "declined=\(model.keychainDeclined) state=\(model.loadState)")
    }

    do {
        // Likewise a sign-in without `allowKeychainAgain()`: the old cancel
        // is remembered and the new login's own item is never read.
        let fake = Fake()
        fake.own = token("T")
        fake.signInToken = token("N")
        fake.lookupReplies = [1: .refused(errSecUserCanceled)]
        fake.holds = ["lookup#1"]
        let model = UsageModel(boundaries: fake.boundaries)
        let refresh = Task { await model.refreshOnce() }
        await until("cancelled read held") { fake.isHeld("lookup#1") }
        await model.signIn()
        fake.release("lookup#1")
        await refresh.value
        check("sign-in during a cancelled read: the decline is not remembered, the new login is read",
              !model.keychainDeclined && fake.lookups == 2 && fake.fetched == ["a-N"],
              "declined=\(model.keychainDeclined) lookups=\(fake.lookups) fetched=\(fake.fetched)")
    }

    // MARK: (e) the same dead token lapses again

    do {
        // Computing `lapseIsNews` after `session.expired` (no notification
        // at all), or ignoring the announced tokens (a second one).
        let fake = Fake()
        fake.own = token("T", expired: true)
        fake.cli = token("C")
        fake.lookupReplies = [
            2: .unavailable(errSecInteractionNotAllowed), // the lapse cannot be confirmed: item kept
            3: .refused(errSecAuthFailed),                // not the user: falls to the CLI token
        ]
        let model = UsageModel(boundaries: fake.boundaries)
        await model.refreshOnce()
        let first = (model.loadState, fake.expiryNotices, fake.clears)
        await model.refreshOnce()
        let between = model.loadState
        await model.refreshOnce()
        check("(e) first lapse, Keychain cannot say: notice and one notification, item kept",
              first.0 == .sessionExpired && first.1 == 1 && first.2 == 0,
              "state=\(first.0) notices=\(first.1) clears=\(first.2)")
        check("(e) a CLI fetch takes the notice down in between", between == .loaded(.claudeCodeCLI),
              "state=\(between)")
        check("(e) the same token lapses again: deleted, notice up, no second notification",
              fake.expiryNotices == 1 && fake.clears == 1 && model.loadState == .sessionExpired,
              "notices=\(fake.expiryNotices) clears=\(fake.clears) state=\(model.loadState)")
    }

    // MARK: (f) refreshes asked for while one is out

    do {
        // Removing the `refreshInFlight` guard (a second refresh reads
        // alongside), or the follow-up loop (the request is lost).
        let fake = Fake()
        fake.own = token("T")
        fake.holds = ["lookup#1"]
        let model = UsageModel(boundaries: fake.boundaries)
        let refresh = Task { await model.refreshOnce() }
        await until("first read held") { fake.isHeld("lookup#1") }
        await model.refreshOnce()
        await model.refreshOnce()
        let whileHeld = fake.lookups
        fake.release("lookup#1")
        await refresh.value
        check("(f) refreshes asked for mid-flight do not overlap it", whileHeld == 1, "lookups=\(whileHeld)")
        check("(f) they fold into one follow-up refresh",
              fake.lookups == 2 && fake.fetched == ["a-T", "a-T"],
              "lookups=\(fake.lookups) fetched=\(fake.fetched)")
    }

    // MARK: (g) a sign-in the Keychain did not take is held (#151)

    do {
        // The old `signIn` dropped the token on a failed save and showed an
        // error whose [재시도] only re-read the Keychain.
        let fake = Fake()
        fake.cli = token("C")
        fake.signInToken = token("N")
        fake.saveReplies = [1: .cancelled]
        let model = UsageModel(boundaries: fake.boundaries)
        await model.signIn()
        check("(g) sign-in save cancelled: polled with the held login, not the CLI token",
              fake.fetched == ["a-N"] && fake.cliReads == 0 && model.loadState == .loaded(.oauthLogin)
                  && model.holdsUnsavedLogin && model.keychainDeclined,
              "fetched=\(fake.fetched) cliReads=\(fake.cliReads) state=\(model.loadState) held=\(model.holdsUnsavedLogin)")
        check("(g) …and the banner says so, with [다시 허용]",
              model.presentation.banner == .keychainDeclined(.heldLogin, limitsUnread: false)
                  && model.presentation.bannerAction == .allowKeychain,
              "banner=\(model.presentation.banner)")
        let lookupsBefore = fake.lookups
        await model.refreshOnce()
        check("(g) a poll under the decline neither reads nor stores the item again",
              fake.lookups == lookupsBefore && fake.saved == ["a-N"] && fake.fetched == ["a-N", "a-N"],
              "lookups=\(fake.lookups) saved=\(fake.saved) fetched=\(fake.fetched)")
        model.refreshNow()
        await settle()
        check("(g) [다시 허용] stores the held login, and the banner clears",
              fake.saved == ["a-N", "a-N"] && fake.own?.accessToken == "a-N" && !model.holdsUnsavedLogin
                  && !model.keychainDeclined && model.presentation.banner == UsagePresentation.Banner.none,
              "saved=\(fake.saved) own=\(fake.own?.accessToken ?? "nil") held=\(model.holdsUnsavedLogin) banner=\(model.presentation.banner)")
    }

    do {
        // Removing the check after the save in `signIn`: the sign-in the
        // user signed out of is held and polled — and stored — after all.
        let fake = Fake()
        fake.signInToken = token("N")
        fake.saveReplies = [1: .cancelled]
        fake.holds = ["save#1"]
        let model = UsageModel(boundaries: fake.boundaries)
        let signIn = Task { await model.signIn() }
        await until("sign-in save held") { fake.isHeld("save#1") }
        await model.signOut()
        fake.release("save#1")
        await signIn.value
        await model.refreshOnce()
        check("(g) sign-out during the sign-in save: nothing held, nothing stored or polled",
              !model.holdsUnsavedLogin && fake.saved == ["a-N"] && fake.fetched.isEmpty
                  && fake.own == nil && model.loadState == .signedOut,
              "held=\(model.holdsUnsavedLogin) saved=\(fake.saved) fetched=\(fake.fetched) state=\(model.loadState)")
    }

    do {
        // Same check, another sign-in: the first sign-in's token is held
        // and stored over the second login.
        let fake = Fake()
        fake.signInToken = token("N")
        fake.saveReplies = [1: .cancelled]
        fake.holds = ["save#1"]
        let model = UsageModel(boundaries: fake.boundaries)
        let first = Task { await model.signIn() }
        await until("first sign-in save held") { fake.isHeld("save#1") }
        fake.signInToken = token("M")
        await model.signIn()
        fake.release("save#1")
        await first.value
        await model.refreshOnce()
        check("(g) another sign-in during the sign-in save: the second login stays, the first is not held",
              fake.own?.accessToken == "a-M" && fake.saved == ["a-N", "a-M"] && fake.fetched == ["a-M", "a-M"]
                  && !model.holdsUnsavedLogin,
              "own=\(fake.own?.accessToken ?? "nil") saved=\(fake.saved) fetched=\(fake.fetched)")
    }

    do {
        // Clearing `pendingOwnToken` on `.drop` in `adoptRenewed` without the
        // generation check: a refresh that started before the sign-in drops
        // the sign-in's held token, and the login falls through to nothing.
        let fake = Fake()
        fake.own = token("T", expired: true)
        fake.renewals = ["a-T": token("R")]
        fake.signInToken = token("N")
        fake.saveReplies = [1: .cancelled]
        fake.holds = ["lookup#2"]
        let model = UsageModel(boundaries: fake.boundaries)
        let refresh = Task { await model.refreshOnce() }
        await until("adopt's Keychain check held") { fake.isHeld("lookup#2") }
        await model.signIn()
        fake.release("lookup#2")
        await refresh.value
        check("(g) sign-in (save cancelled) during adopt's check: the old refresh leaves the held sign-in alone",
              model.holdsUnsavedLogin && fake.saved == ["a-N"] && fake.fetched == ["a-N"]
                  && model.loadState == .loaded(.oauthLogin),
              "held=\(model.holdsUnsavedLogin) saved=\(fake.saved) fetched=\(fake.fetched) state=\(model.loadState)")
    }

    // MARK: (i) a declined prompt for the Claude Code CLI item (#155)

    do {
        // Without the CLI decline (the read folded to "no token"), every
        // poll asked the item again — a dialog every 180 seconds.
        let fake = Fake()
        fake.cli = token("C")
        fake.cliDeclines = [1]
        let model = UsageModel(boundaries: fake.boundaries)
        await model.refreshOnce()
        check("(i) CLI prompt declined: remembered, sample with the declined banner and [다시 허용]",
              model.cliKeychainDeclined && model.loadState == .signedOut
                  && model.presentation.banner == .keychainDeclined(.sample, limitsUnread: false)
                  && model.presentation.bannerAction == .allowKeychain,
              "declined=\(model.cliKeychainDeclined) state=\(model.loadState) banner=\(model.presentation.banner)")
        await model.refreshOnce()
        check("(i) a poll under the decline does not ask the CLI item again",
              fake.cliKeychainReads == 1 && fake.cliReads == 2 && model.cliKeychainDeclined,
              "keychainReads=\(fake.cliKeychainReads) reads=\(fake.cliReads)")
        model.refreshNow()
        await settle()
        check("(i) [다시 허용] asks the CLI item again and lifts the decline",
              fake.cliKeychainReads == 2 && !model.cliKeychainDeclined && fake.fetched == ["a-C"]
                  && model.loadState == .loaded(.claudeCodeCLI),
              "keychainReads=\(fake.cliKeychainReads) declined=\(model.cliKeychainDeclined) state=\(model.loadState)")
    }

    do {
        // The decline leaves the CLI file alone: a token there is polled.
        let fake = Fake()
        fake.cliFile = token("F")
        fake.cliDeclines = [1]
        let model = UsageModel(boundaries: fake.boundaries)
        await model.refreshOnce()
        await model.refreshOnce()
        check("(i) under the CLI decline the file is still read, the item is not",
              fake.cliKeychainReads == 1 && fake.fetched == ["a-F", "a-F"] && model.cliKeychainDeclined
                  && model.presentation.banner == .cliAccount,
              "keychainReads=\(fake.cliKeychainReads) fetched=\(fake.fetched) banner=\(model.presentation.banner)")
    }

    do {
        // Passing `sameAllowance: true` in `loadClaudeCodeToken`: the cancel
        // from before [다시 허용] is remembered again and the button did
        // nothing once.
        let fake = Fake()
        fake.cli = token("C")
        fake.cliDeclines = [1]
        fake.holds = ["cli#1"]
        let model = UsageModel(boundaries: fake.boundaries)
        let refresh = Task { await model.refreshOnce() }
        await until("cancelled CLI read held") { fake.isHeld("cli#1") }
        model.refreshNow()
        await settle()
        fake.release("cli#1")
        await refresh.value
        await settle()
        check("(i) [다시 허용] during a cancelled CLI read: the decline is not brought back, the item is read again",
              !model.cliKeychainDeclined && fake.cliKeychainReads == 2 && model.loadState == .loaded(.claudeCodeCLI),
              "declined=\(model.cliKeychainDeclined) keychainReads=\(fake.cliKeychainReads) state=\(model.loadState)")
    }

    do {
        // A sign-out while the cancelled CLI read is out lifts it too.
        let fake = Fake()
        fake.cli = token("C")
        fake.cliDeclines = [1]
        fake.holds = ["cli#1"]
        let model = UsageModel(boundaries: fake.boundaries)
        let refresh = Task { await model.refreshOnce() }
        await until("cancelled CLI read held") { fake.isHeld("cli#1") }
        await model.signOut()
        fake.release("cli#1")
        await refresh.value
        check("(i) sign-out during a cancelled CLI read: the decline is not remembered",
              !model.cliKeychainDeclined && model.loadState == .signedOut,
              "declined=\(model.cliKeychainDeclined) state=\(model.loadState)")
    }

    // MARK: (h) the guards #150 left unpinned

    do {
        // Removing the check after the delete in `signOut`: a delete that
        // failed reports its error over the login that came after it.
        let fake = Fake()
        fake.own = token("T")
        fake.signInToken = token("N")
        fake.clearReplies = [1: false]
        fake.holds = ["clear#1"]
        let model = UsageModel(boundaries: fake.boundaries)
        let signOut = Task { await model.signOut() }
        await until("sign-out delete held") { fake.isHeld("clear#1") }
        await model.signIn()
        fake.release("clear#1")
        await signOut.value
        check("(h) sign-in during a failing sign-out delete: no delete error over the new login",
              model.loadState == .loaded(.oauthLogin) && fake.own?.accessToken == "a-N",
              "state=\(model.loadState) own=\(fake.own?.accessToken ?? "nil")")
    }

    do {
        // Removing the check after the save in `resolvePendingToken`: the
        // held renewal is held again after the sign-out, its Keychain
        // expectation "maybe empty", and the next poll stores it — the
        // signed-out login comes back.
        let fake = Fake()
        fake.own = token("T", expired: true)
        fake.renewals = ["a-T": token("R")]
        fake.saveReplies = [1: .failed, 2: .failedAfterDelete]
        let model = UsageModel(boundaries: fake.boundaries)
        await model.refreshOnce()
        let heldFirst = model.holdsUnsavedLogin
        fake.holds = ["save#2"]
        let refresh = Task { await model.refreshOnce() }
        await until("held renewal's save held") { fake.isHeld("save#2") }
        await model.signOut()
        fake.release("save#2")
        await refresh.value
        await model.refreshOnce()
        check("(h) the renewal is held after its save failed", heldFirst)
        check("(h) sign-out during the held renewal's save: it is not held or stored again",
              !model.holdsUnsavedLogin && fake.saved == ["a-R", "a-R"] && fake.fetched == ["a-R"]
                  && fake.own == nil && model.loadState == .signedOut,
              "held=\(model.holdsUnsavedLogin) saved=\(fake.saved) fetched=\(fake.fetched) state=\(model.loadState)")
    }
}

await run()

// MARK: result

if failures.isEmpty {
    print("\nUsage model order tests: all passed")
    exit(0)
} else {
    print("\nUsage model order tests: \(failures.count) failed")
    failures.forEach { print("  - \($0)") }
    exit(1)
}
