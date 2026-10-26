import Foundation

// Regression tests for the usage response parser (`UsageAPIClient.parse`)
// and the snapshot it fills.
//
// Pinned here: the three known `limits` kinds keep reading as before; a kind
// the app does not know is kept as an `ExtraLimit` (name, percent, reset)
// instead of being dropped, without disturbing the known three; the flat
// fallback yields no extra limits; code-named top-level objects are noted
// while null keys and known-shape keys are not; the debug-log line is nil
// when there is nothing unknown and carries only kind/percent/reset times
// otherwise; its dedupe key ignores the moving numbers; hostile numbers
// (1e300, Int.max, non-numbers) fold to 100/0/nil without a trap; response
// strings reach labels and the log as one bounded line, and unknown rows
// stop at the cap; the status code maps onto the error the model branches
// on (401/403 → re-auth, 429 → back off with Retry-After, a refused 3xx →
// an HTTP error); only a 200 body is read and the real shape sits far under
// the response cap; a 429 holds both the poll and the manual refresh until
// the backoff or Retry-After (capped) runs out; a 401 refreshes only the
// own token, only a second 401 signs out, a blip on the refresh or the
// retry keeps the account behind an error, a 429 on the retry backs off,
// and a successful retry shows like any success (#92/#93/#95); and the `Meter`
// shows the mode's number with the risk color (or monochrome when color
// coding is off).
//
// Run with `./scripts/test.sh`, which compiles this against the real sources
// (the @MainActor model is left out, as for the other bundles).

var failures: [String] = []

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "  ok  " : " FAIL ") \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !ok { failures.append(label) }
}

func body(_ s: String) -> Data { Data(s.utf8) }

func iso(_ s: String) -> Date? {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fmt.date(from: s) ?? ISO8601DateFormatter().date(from: s)
}

/// The shape the real endpoint returned on 2026-10-21: the keys the app reads,
/// the three it does not read but knows the shape of (object / array / bool),
/// and the code-named keys trimmed to two nulls. `extraLimits` is spliced into
/// `limits`, `topLevel` after it.
func response(extraLimits: String = "", topLevel: String = "") -> Data {
    body("""
    {
      "five_hour": {"utilization": 4, "resets_at": "2026-10-21T06:10:00.825239+00:00"},
      "seven_day": {"utilization": 4, "resets_at": "2026-10-26T15:00:00+00:00"},
      "seven_day_breakdown": {"as_of": "2026-10-21T05:00:00+00:00",
                              "window_started_at": "2026-10-19T15:00:00+00:00", "rows": []},
      "weekly_scoped_shares": [],
      "member_dashboard_available": false,
      "nimbus_quill": null,
      "cinder_cove": null,
      "spend": null,
      "extra_usage": null,
      "limits": [
        {"kind":"session","group":"session","percent":4,"severity":"normal",
         "resets_at":"2026-10-21T06:10:00.825239+00:00","scope":null,"is_active":true},
        {"kind":"weekly_all","group":"weekly","percent":23,"severity":"normal",
         "resets_at":"2026-10-26T15:00:00+00:00","scope":null,"is_active":false},
        {"kind":"weekly_scoped","group":"weekly","percent":29,"severity":"normal",
         "resets_at":"2026-10-26T15:00:00+00:00",
         "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}
        \(extraLimits)
      ]
      \(topLevel)
    }
    """)
}

let sessionReset = iso("2026-10-21T06:10:00.825239+00:00")
let weeklyReset = iso("2026-10-26T15:00:00+00:00")

// MARK: (a) the real response shape

do {
    let snap = try UsageAPIClient.parse(response())
    check("session → fiveHourPercent", snap.fiveHourPercent == 4, "\(snap.fiveHourPercent)")
    check("session → fiveHourResetAt", snap.fiveHourResetAt == sessionReset, "\(String(describing: snap.fiveHourResetAt))")
    check("weekly_all → weeklyAllPercent", snap.weeklyAllPercent == 23, "\(snap.weeklyAllPercent)")
    check("weekly_all → weeklyResetAt", snap.weeklyResetAt == weeklyReset, "\(String(describing: snap.weeklyResetAt))")
    check("weekly_scoped → one model row", snap.models.count == 1, "\(snap.models)")
    check("weekly_scoped → pretty name + percent",
          snap.models.first == ModelUsage(name: "Fable 5", percent: 29), "\(snap.models)")
    check("known kinds only → no extra limits", snap.extraLimits.isEmpty, "\(snap.extraLimits)")
    check("null and known-shape top-level keys → no unknown buckets",
          snap.unknownTopLevel.isEmpty, "\(snap.unknownTopLevel)")
    check("nothing unknown → log line nil", AuthDebugLog.usageUnknownLine(snap) == nil,
          AuthDebugLog.usageUnknownLine(snap) ?? "")
    check("nothing unknown → dedupe key nil", AuthDebugLog.usageUnknownKey(snap) == nil,
          AuthDebugLog.usageUnknownKey(snap) ?? "")
} catch {
    check("real response parses", false, "\(error)")
}

// MARK: (b) an unknown kind is kept, the known three are untouched

do {
    let snap = try UsageAPIClient.parse(response(extraLimits: """
        ,{"kind":"bonus_reset","group":"bonus","percent":12,"severity":"normal",
          "resets_at":"2026-11-05T07:59:00+00:00","scope":null,"is_active":true}
        """))
    check("unknown kind → one extra limit", snap.extraLimits.count == 1, "\(snap.extraLimits)")
    let extra = snap.extraLimits.first
    check("extra kind kept verbatim", extra?.kind == "bonus_reset", extra?.kind ?? "nil")
    check("extra id is the kind", extra?.id == "bonus_reset", extra?.id ?? "nil")
    check("extra name = kind with underscores spaced", extra?.name == "bonus reset", extra?.name ?? "nil")
    check("extra percent", extra?.percent == 12, "\(String(describing: extra?.percent))")
    check("extra resetAt", extra?.resetAt == iso("2026-11-05T07:59:00+00:00"),
          "\(String(describing: extra?.resetAt))")
    check("extra resetText is the popover phrasing",
          extra?.resetText == TimeText.resetsAt(iso("2026-11-05T07:59:00+00:00")), extra?.resetText ?? "nil")
    check("extra is_active carried", extra?.isActive == true, "\(String(describing: extra?.isActive))")
    check("known three unchanged: session", snap.fiveHourPercent == 4 && snap.fiveHourResetAt == sessionReset)
    check("known three unchanged: weekly_all", snap.weeklyAllPercent == 23 && snap.weeklyResetAt == weeklyReset)
    check("known three unchanged: weekly_scoped",
          snap.models == [ModelUsage(name: "Fable 5", percent: 29)], "\(snap.models)")
} catch {
    check("response with unknown kind parses", false, "\(error)")
}

do {
    // A scoped unknown kind shows the scope's model name in the same spelling
    // as the weekly_scoped row, next to its kind so the two rows differ; no
    // reset time leaves the caption empty rather than invented.
    let snap = try UsageAPIClient.parse(response(extraLimits: """
        ,{"kind":"bonus","percent":50,
          "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}
        """))
    let extra = snap.extraLimits.first
    check("scoped unknown kind → name is model (weekly_scoped spelling) · kind",
          extra?.name == "Fable 5 · bonus" && snap.models.first?.name == "Fable 5", extra?.name ?? "nil")
    check("scoped unknown kind → scopeModel alone matches the weekly_scoped row",
          extra?.scopeModel == snap.models.first?.name, extra?.scopeModel ?? "nil")
    check("no resets_at → resetAt nil", extra?.resetAt == nil, "\(String(describing: extra?.resetAt))")
    check("no resets_at → resetText empty", extra?.resetText == "", extra?.resetText ?? "nil")
    check("no is_active → nil", extra?.isActive == nil, "\(String(describing: extra?.isActive))")
} catch {
    check("response with scoped unknown kind parses", false, "\(error)")
}

do {
    // The same kind twice must not collide as `Identifiable` ids.
    let snap = try UsageAPIClient.parse(response(extraLimits: """
        ,{"kind":"bonus","percent":1},{"kind":"bonus","percent":2}
        """))
    let ids = snap.extraLimits.map(\.id)
    check("repeated kind → distinct ids", Set(ids).count == 2 && ids.first == "bonus", "\(ids)")
    check("repeated kind → response order kept", snap.extraLimits.map(\.percent) == [1, 2],
          "\(snap.extraLimits.map(\.percent))")
} catch {
    check("response with repeated kind parses", false, "\(error)")
}

// MARK: (c) flat fallback when `limits` is absent

do {
    let snap = try UsageAPIClient.parse(body("""
    {"five_hour": {"utilization": 64, "resets_at": "2026-10-21T06:10:00+00:00"},
     "seven_day": {"utilization": 23, "resets_at": "2026-10-26T15:00:00+00:00"}}
    """))
    check("flat fallback → five_hour read", snap.fiveHourPercent == 64, "\(snap.fiveHourPercent)")
    check("flat fallback → seven_day read", snap.weeklyAllPercent == 23, "\(snap.weeklyAllPercent)")
    check("flat fallback → no extra limits", snap.extraLimits.isEmpty, "\(snap.extraLimits)")
    check("flat fallback → no unknown buckets", snap.unknownTopLevel.isEmpty, "\(snap.unknownTopLevel)")
} catch {
    check("flat response parses", false, "\(error)")
}

// MARK: (d) unknown top-level objects are noted, null keys are not

do {
    let snap = try UsageAPIClient.parse(response(topLevel: """
        ,"iguana_necktie": {"utilization": 100, "resets_at": "2026-11-01T00:00:00+00:00",
                            "limit_dollars": 25, "used_dollars": 25, "remaining_dollars": 0,
                            "locked_reason": null},
         "zephyr_loom": {"locked_reason": "none"},
         "quiet_marsh": null
        """))
    let keys = snap.unknownTopLevel.map(\.key)
    check("object keys noted, sorted; null key skipped", keys == ["iguana_necktie", "zephyr_loom"], "\(keys)")
    let iguana = snap.unknownTopLevel.first
    check("bucket utilization read", iguana?.utilization == 100, "\(String(describing: iguana?.utilization))")
    check("bucket resetAt read", iguana?.resetAt == iso("2026-11-01T00:00:00+00:00"),
          "\(String(describing: iguana?.resetAt))")
    check("bucket without utilization → nil", snap.unknownTopLevel.last?.utilization == nil)
    check("known object keys (five_hour/seven_day) are not buckets",
          !keys.contains("five_hour") && !keys.contains("seven_day"), "\(keys)")
} catch {
    check("response with unknown top-level objects parses", false, "\(error)")
}

// MARK: (e) the debug-log line and its dedupe key

let bonusReset = iso("2026-11-05T07:59:00+00:00")

func unknownSnapshot(percent: Int = 12, kind: String = "bonus", resetAt: Date? = bonusReset,
                     utilization: Int? = 100) -> UsageSnapshot {
    var snap = UsageSnapshot.sample
    snap.extraLimits = [ExtraLimit(id: kind, kind: kind, scopeModel: nil, percent: percent,
                                   resetAt: resetAt, resetText: "", isActive: true)]
    snap.unknownTopLevel = [UnknownBucket(key: "iguana_necktie", utilization: utilization, resetAt: nil)]
    return snap
}

do {
    check("sample → log line nil", AuthDebugLog.usageUnknownLine(.sample) == nil)
    check("sample → dedupe key nil", AuthDebugLog.usageUnknownKey(.sample) == nil)

    let snap = unknownSnapshot()
    let line = AuthDebugLog.usageUnknownLine(snap) ?? ""
    let expected = "usage unknown limits kind=bonus percent=12 resets_at=\(AuthDebugLog.iso(bonusReset))"
        + " is_active=true scope=- | top-level iguana_necktie utilization=100 resets_at=none"
    check("log line format", line == expected, line)
    check("log line never names amounts", !line.contains("dollar"), line)

    var limitsOnly = snap
    limitsOnly.unknownTopLevel = []
    check("limits only → no top-level part",
          AuthDebugLog.usageUnknownLine(limitsOnly)?.contains("top-level") == false,
          AuthDebugLog.usageUnknownLine(limitsOnly) ?? "")
    limitsOnly.extraLimits = []
    check("emptied → log line nil again", AuthDebugLog.usageUnknownLine(limitsOnly) == nil)
}

do {
    // The key is the set of unknown things, not their numbers: a percentage
    // or utilization that moves between polls must not write a line each time.
    let base = AuthDebugLog.usageUnknownKey(unknownSnapshot())
    check("dedupe key present when something is unknown", base != nil)
    check("percent moved → same key",
          AuthDebugLog.usageUnknownKey(unknownSnapshot(percent: 40)) == base,
          AuthDebugLog.usageUnknownKey(unknownSnapshot(percent: 40)) ?? "nil")
    check("utilization moved → same key",
          AuthDebugLog.usageUnknownKey(unknownSnapshot(utilization: 50)) == base)
    check("kind changed → different key",
          AuthDebugLog.usageUnknownKey(unknownSnapshot(kind: "reset")) != base)
    check("resets_at changed → different key",
          AuthDebugLog.usageUnknownKey(unknownSnapshot(resetAt: iso("2026-11-06T07:59:00+00:00"))) != base)
    var bucketGone = unknownSnapshot()
    bucketGone.unknownTopLevel = []
    check("bucket set changed → different key", AuthDebugLog.usageUnknownKey(bucketGone) != base)
}

// MARK: (f) hostile numbers fold instead of trapping

do {
    let snap = try UsageAPIClient.parse(response(extraLimits: """
        ,{"kind":"huge","percent":1e300},
         {"kind":"negative","percent":-1e300},
         {"kind":"intmax","percent":9223372036854775807},
         {"kind":"text","percent":"NaN"}
        """, topLevel: """
        ,"iguana_necktie": {"utilization": 1e300, "resets_at": null},
         "zephyr_loom": {"utilization": "NaN"}
        """))
    let byKind = Dictionary(uniqueKeysWithValues: snap.extraLimits.map { ($0.kind, $0.percent) })
    check("percent 1e300 → 100", byKind["huge"] == 100, "\(String(describing: byKind["huge"]))")
    check("percent -1e300 → 0", byKind["negative"] == 0, "\(String(describing: byKind["negative"]))")
    check("percent Int.max → 100", byKind["intmax"] == 100, "\(String(describing: byKind["intmax"]))")
    check("percent non-number → 0", byKind["text"] == 0, "\(String(describing: byKind["text"]))")
    let utilizations = snap.unknownTopLevel.map(\.utilization)
    check("utilization 1e300 → 100, non-number → nil", utilizations == [100, nil], "\(utilizations)")
} catch {
    check("response with hostile numbers parses", false, "\(error)")
}

// MARK: (g) response strings are bounded single lines; rows stop at the cap

do {
    let longKind = String(repeating: "k", count: 10_000)
    let longName = String(repeating: "n", count: 10_000)
    let longKey = String(repeating: "z", count: 10_000)
    let snap = try UsageAPIClient.parse(response(extraLimits: """
        ,{"kind":"\(longKind)","percent":1},
         {"kind":"a\\nb\\tc","percent":2,"scope":{"model":{"display_name":"\(longName)"}}}
        """, topLevel: """
        ,"\(longKey)": {"utilization": 5},
         "line\\nbreak": {"utilization": 6}
        """))
    let long = snap.extraLimits.first
    check("10k-char kind → label within the limit",
          long?.name.count == Config.usageDisplayTextLimit, "\(String(describing: long?.name.count))")
    let scoped = snap.extraLimits.last
    check("kind with line breaks → single-line label",
          scoped?.kind == "a b c" && scoped?.name.contains("\n") == false, scoped?.name ?? "nil")
    check("10k-char display_name → bounded (prettified afterwards)",
          (scoped?.scopeModel?.count ?? .max) <= Config.usageDisplayTextLimit,
          "\(String(describing: scoped?.scopeModel?.count))")
    let keys = snap.unknownTopLevel.map(\.key)
    check("top-level keys → single line, within the limit",
          keys.allSatisfy { !$0.contains("\n") && $0.count <= Config.usageDisplayTextLimit }, "\(keys)")
    let line = AuthDebugLog.usageUnknownLine(snap) ?? ""
    check("log line stays one line", !line.contains("\n"), line)
    check("log line bounded", line.count < 4 * Config.usageDisplayTextLimit + 200, "\(line.count)")
} catch {
    check("response with long strings parses", false, "\(error)")
}

do {
    let over = Config.usageExtraLimitsCap + 1
    let limits = (0..<over).map { #",{"kind":"k\#($0)","percent":\#($0)}"# }.joined()
    let buckets = (0..<over).map { #","b\#($0)": {"utilization": \#($0)}"# }.joined()
    let snap = try UsageAPIClient.parse(response(extraLimits: limits, topLevel: buckets))
    check("\(over) unknown kinds → \(Config.usageExtraLimitsCap) kept, in order",
          snap.extraLimits.count == Config.usageExtraLimitsCap && snap.extraLimits.first?.kind == "k0",
          "\(snap.extraLimits.count)")
    check("\(over) unknown objects → \(Config.usageUnknownTopLevelCap) kept",
          snap.unknownTopLevel.count == Config.usageUnknownTopLevelCap, "\(snap.unknownTopLevel.count)")
    check("known rows survive the overflow", snap.fiveHourPercent == 4 && snap.models.count == 1)
} catch {
    check("response over the caps parses", false, "\(error)")
}

// MARK: a top-level key that flattens to nothing is not a bucket

do {
    let snap = try! UsageAPIClient.parse(Data(#"{"limits":[],"\n\t ":{"utilization":5},"nimbus_quill":{"utilization":5}}"#.utf8))
    check("blank top-level key → skipped, named key kept",
          snap.unknownTopLevel.map(\.key) == ["nimbus_quill"], "\(snap.unknownTopLevel.map(\.key))")
}

// MARK: status code → snapshot or the error the model branches on

func interpretError(_ status: Int, retryAfter: String? = nil, _ data: Data = Data()) -> APIError? {
    do {
        _ = try UsageAPIClient.interpret(statusCode: status, retryAfter: retryAfter, data: data)
        return nil
    } catch {
        return error as? APIError
    }
}

do {
    let snap = try? UsageAPIClient.interpret(statusCode: 200, retryAfter: nil, data: response())
    check("200 → parsed snapshot", snap?.fiveHourPercent == 4 && snap?.weeklyAllPercent == 23)
    check("200 with a broken body → badResponse", interpretError(200, body("not json")) == .badResponse)
    check("401 → unauthorized", interpretError(401) == .unauthorized)
    check("403 → unauthorized", interpretError(403) == .unauthorized)
    check("429 + Retry-After → rateLimited(seconds)",
          interpretError(429, retryAfter: "120") == .rateLimited(retryAfter: 120))
    check("429 without Retry-After → rateLimited(nil)",
          interpretError(429) == .rateLimited(retryAfter: nil))
    check("429 with a non-numeric Retry-After → rateLimited(nil)",
          interpretError(429, retryAfter: "Wed, 21 Oct 2026 07:28:00 GMT") == .rateLimited(retryAfter: nil))
    check("500 → http(500)", interpretError(500) == .http(500))
    // `RedirectRefuser` hands a 3xx back as the response itself; this pins
    // only how that response maps, not the refusal.
    check("3xx handed back by the refused redirect → http(302)", interpretError(302) == .http(302))
}

// MARK: transport — only a 200 body is read, and the real shape fits the cap

do {
    check("200 reads the body", UsageAPIClient.readsBody(statusCode: 200))
    // A large 401/429 page must still surface as re-auth / back-off, not as
    // "too large" — the size cap only applies to bodies that are read.
    check("401/403/429/302/500 are judged on the code alone",
          [401, 403, 429, 302, 500].allSatisfy { !UsageAPIClient.readsBody(statusCode: $0) })
    let real = Int64(response().count)
    check("real-shaped response is far under the cap",
          real * 100 < Config.usageMaxResponseBytes, "\(real) bytes vs \(Config.usageMaxResponseBytes)")
}

// MARK: usage meter — number follows the mode, color follows risk and the toggle

do {
    let used = Meter(usedPercent: 90, showRemaining: false, colorCoding: true)
    let remaining = Meter(usedPercent: 90, showRemaining: true, colorCoding: true)
    let mono = Meter(usedPercent: 90, showRemaining: true, colorCoding: false)
    check("consumed mode shows the used percent", used.displayPercent == 90)
    check("remaining mode shows 100 - used", remaining.displayPercent == 10)
    check("90% used → red", used.color == Palette.red)
    check("remaining mode keeps the risk color (10% left is still red)",
          remaining.color == Palette.red)
    check("color coding off → mono, not a risk color", mono.color == Palette.mono)
    check("color coding off with 10% used → still mono",
          Meter(usedPercent: 10, showRemaining: false, colorCoding: false).color == Palette.mono)
}

// MARK: rate-limit window — poll and manual refresh wait it out (#86)

do {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    check("no backoff → the user's interval", UsageRetryPolicy.pollWait(base: 180, backoff: 0) == 180)
    check("backoff doubles per 429", UsageRetryPolicy.pollWait(base: 180, backoff: 2) == 720)
    check("backoff caps at an hour", UsageRetryPolicy.pollWait(base: 180, backoff: 4) == 2880
          && UsageRetryPolicy.pollWait(base: 600, backoff: 4) == 3600)
    check("no Retry-After → retry at the backoff wait",
          UsageRetryPolicy.retryAt(now: now, base: 180, backoff: 1, retryAfter: nil) == now.addingTimeInterval(360))
    check("Retry-After longer than backoff → it wins",
          UsageRetryPolicy.retryAt(now: now, base: 180, backoff: 1, retryAfter: 900) == now.addingTimeInterval(900))
    check("Retry-After shorter than backoff → backoff kept",
          UsageRetryPolicy.retryAt(now: now, base: 180, backoff: 1, retryAfter: 5) == now.addingTimeInterval(360))
    check("hostile Retry-After → capped at an hour",
          UsageRetryPolicy.retryAt(now: now, base: 180, backoff: 1, retryAfter: 1e12) == now.addingTimeInterval(3600))
    check("negative Retry-After → backoff kept",
          UsageRetryPolicy.retryAt(now: now, base: 180, backoff: 1, retryAfter: -50) == now.addingTimeInterval(360))

    let retryAt = now.addingTimeInterval(300)
    check("inside the window → manual refresh blocked until retryAt",
          UsageRetryPolicy.manualRefreshBlocked(until: .rateLimited(retryAt: retryAt), now: now) == retryAt)
    check("window over → manual refresh open",
          UsageRetryPolicy.manualRefreshBlocked(until: .rateLimited(retryAt: retryAt), now: retryAt) == nil)
    check("not rate limited → manual refresh open",
          UsageRetryPolicy.manualRefreshBlocked(until: .error("x"), now: now) == nil
          && UsageRetryPolicy.manualRefreshBlocked(until: .loaded(.oauthLogin), now: now) == nil)
    check("minutes left round up, never under one",
          TimeText.minutesLeft(until: now.addingTimeInterval(61), now: now) == 2
          && TimeText.minutesLeft(until: now, now: now) == 1)
}

// MARK: 401 → refresh → retry (#92, #93, #95)

do {
    let snap = UsageSnapshot.sample
    let none: OwnTokenRetry? = nil
    check("error mapping: 401 / 429 / anything else",
          UsageFetchResult(.failure(APIError.unauthorized)) == .unauthorized
          && UsageFetchResult(.failure(APIError.rateLimited(retryAfter: 30))) == .rateLimited(retryAfter: 30)
          && UsageFetchResult(.failure(APIError.http(503))) == .failed
          && UsageFetchResult(.failure(URLError(.notConnectedToInternet))) == .failed
          && UsageFetchResult(.success(snap)) == .ok(snap))

    check("401 on the own token → refresh it",
          UsageRefreshPolicy.shouldRenew(after: .unauthorized, source: .oauthLogin))
    check("401 on a CLI token → no refresh",
          !UsageRefreshPolicy.shouldRenew(after: .unauthorized, source: .claudeCodeCLI))
    check("no 401 → no refresh",
          !UsageRefreshPolicy.shouldRenew(after: .failed, source: .oauthLogin)
          && !UsageRefreshPolicy.shouldRenew(after: .ok(snap), source: .oauthLogin)
          && !UsageRefreshPolicy.shouldRenew(after: .rateLimited(retryAfter: nil), source: .oauthLogin))

    check("first fetch ok → show (thresholds checked)",
          UsageRefreshPolicy.step(after: .ok(snap), retry: none) == .show(snap))
    check("401 with no refresh (CLI token) → signed out",
          UsageRefreshPolicy.step(after: .unauthorized, retry: none) == .signOut)
    check("first fetch 429 → back off",
          UsageRefreshPolicy.step(after: .rateLimited(retryAfter: 60), retry: none) == .rateLimited(retryAfter: 60))
    check("first fetch blip → error",
          UsageRefreshPolicy.step(after: .failed, retry: none) == .failed)

    check("refresh blip → error, not signed out (#92)",
          UsageRefreshPolicy.step(after: .unauthorized, retry: .renewalFailed) == .failed)
    check("refresh rejected for good → lapsed login",
          UsageRefreshPolicy.step(after: .unauthorized, retry: .sessionExpired) == .expireSession)
    check("retry 401 → signed out",
          UsageRefreshPolicy.step(after: .unauthorized, retry: .refetched(.unauthorized)) == .signOut)
    check("retry blip → error, not signed out (#93)",
          UsageRefreshPolicy.step(after: .unauthorized, retry: .refetched(.failed)) == .failed)
    check("retry 429 → back off with its Retry-After (#93)",
          UsageRefreshPolicy.step(after: .unauthorized, retry: .refetched(.rateLimited(retryAfter: 90)))
              == .rateLimited(retryAfter: 90))
    check("retry ok → show like any success (#95)",
          UsageRefreshPolicy.step(after: .unauthorized, retry: .refetched(.ok(snap))) == .show(snap))
}

// MARK: which token a refresh polls with (#102)

do {
    let own = OAuthToken(accessToken: "own", refreshToken: "r", expiresAt: nil)
    let cli = OAuthToken(accessToken: "cli", refreshToken: nil, expiresAt: nil)
    check("own token found → own, CLI not even read",
          UsageRefreshPolicy.chooseToken(own: .found(own), cli: { nil }) == .token(own, .oauthLogin))
    check("own token missing → CLI token",
          UsageRefreshPolicy.chooseToken(own: .missing, cli: { cli }) == .token(cli, .claudeCodeCLI))
    check("own token refused → CLI token (a denial does not trap the user)",
          UsageRefreshPolicy.chooseToken(own: .refused(errSecAuthFailed), cli: { cli }) == .token(cli, .claudeCodeCLI))
    check("Keychain locked → wait, no quiet switch to the CLI account",
          UsageRefreshPolicy.chooseToken(own: .unavailable(errSecInteractionNotAllowed), cli: { cli })
              == .ownUnavailable(errSecInteractionNotAllowed))
    check("nothing anywhere → none",
          UsageRefreshPolicy.chooseToken(own: .missing, cli: { nil }) == UsageTokenChoice.none)
}

// MARK: result

if failures.isEmpty {
    print("\nUsage tests: all passed")
    exit(0)
} else {
    print("\nUsage tests: \(failures.count) failed")
    failures.forEach { print("  - \($0)") }
    exit(1)
}
