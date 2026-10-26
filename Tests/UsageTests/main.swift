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
// (1e300, Int.max, non-numbers) fold to 100/0/nil without a trap, and a
// JSON bool is not a percentage (#135); response
// strings reach labels and the log as one bounded line, and unknown rows
// stop at the cap; the status code maps onto the error the model branches
// on (401/403 → re-auth, 429 → back off with Retry-After, a refused 3xx →
// an HTTP error); only a 200 body is read and the real shape sits far under
// the response cap; a 429 holds both the poll and the manual refresh until
// the backoff or Retry-After (capped) runs out; a 401 refreshes only the
// own token, only a second 401 signs out, a blip on the refresh or the
// retry keeps the account behind an error, a 429 on the retry backs off,
// and a successful retry shows like any success (#92/#93/#95); the session
// flags across refreshes (#44, #86, #90) and the threshold notifications;
// which badge, banner, banner button and account row each state gets (#104);
// and the `Meter`
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
    check("session → fiveHourPercent", snap.fiveHourPercent == 4, String(describing: snap.fiveHourPercent))
    check("session → fiveHourResetAt", snap.fiveHourResetAt == sessionReset, "\(String(describing: snap.fiveHourResetAt))")
    check("weekly_all → weeklyAllPercent", snap.weeklyAllPercent == 23, String(describing: snap.weeklyAllPercent))
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
    check("flat fallback → five_hour read", snap.fiveHourPercent == 64, String(describing: snap.fiveHourPercent))
    check("flat fallback → seven_day read", snap.weeklyAllPercent == 23, String(describing: snap.weeklyAllPercent))
    check("flat fallback → no extra limits", snap.extraLimits.isEmpty, "\(snap.extraLimits)")
    check("flat fallback → no unknown buckets", snap.unknownTopLevel.isEmpty, "\(snap.unknownTopLevel)")
} catch {
    check("flat response parses", false, "\(error)")
}

// MARK: (c2) a 5-hour/weekly limit the response no longer names is unread, not 0% (#130)

do {
    let renamed = try UsageAPIClient.parse(body("""
    {"limits": [
      {"kind":"session_v2","percent":64,"resets_at":"2026-10-21T06:10:00+00:00"},
      {"kind":"weekly_all","percent":23,"resets_at":"2026-10-26T15:00:00+00:00"}]}
    """))
    check("renamed session kind → 5-hour unread, not 0%", renamed.fiveHourPercent == nil,
          String(describing: renamed.fiveHourPercent))
    check("renamed session kind → weekly still read", renamed.weeklyAllPercent == 23,
          String(describing: renamed.weeklyAllPercent))
    check("renamed session kind → snapshot reports an unread limit", renamed.hasUnreadLimit)

    let noWeekly = try UsageAPIClient.parse(body("""
    {"limits": [{"kind":"session","percent":64,"resets_at":"2026-10-21T06:10:00+00:00"}]}
    """))
    check("weekly_all missing → weekly unread, not 0%", noWeekly.weeklyAllPercent == nil,
          String(describing: noWeekly.weeklyAllPercent))
    check("weekly_all missing → 5-hour still read", noWeekly.fiveHourPercent == 64)

    let noPercent = try UsageAPIClient.parse(body("""
    {"limits": [{"kind":"session","resets_at":"2026-10-21T06:10:00+00:00"},
                {"kind":"weekly_all","percent":"23%"}]}
    """))
    check("session row without a number → unread, not 0%",
          noPercent.fiveHourPercent == nil && noPercent.weeklyAllPercent == nil,
          "\(String(describing: noPercent.fiveHourPercent)) \(String(describing: noPercent.weeklyAllPercent))")

    let noPercentWithResets = try UsageAPIClient.parse(body("""
    {"limits": [{"kind":"session","resets_at":"2026-10-21T06:10:00+00:00"},
                {"kind":"weekly_all","percent":"23%","resets_at":"2026-10-26T15:00:00+00:00"}]}
    """))
    check("row without a number, no flat fallback → its reset is unread too",
          noPercentWithResets.fiveHourResetAt == nil && noPercentWithResets.weeklyResetAt == nil,
          "\(String(describing: noPercentWithResets.fiveHourResetAt)) \(String(describing: noPercentWithResets.weeklyResetAt))")

    let empty = try UsageAPIClient.parse(body("{}"))
    check("nothing recognisable → both unread", empty.fiveHourPercent == nil && empty.weeklyAllPercent == nil)

    // The flat objects mirror session/weekly_all, so a renamed row falls
    // back to its own window's flat object before giving up.
    let mirrored = try UsageAPIClient.parse(body("""
    {"five_hour": {"utilization": 41, "resets_at": "2026-10-21T06:10:00+00:00"},
     "limits": [
      {"kind":"session_v2","percent":64},
      {"kind":"weekly_all","percent":23}]}
    """))
    check("renamed session kind with five_hour present → five_hour read",
          mirrored.fiveHourPercent == 41 && mirrored.fiveHourResetAt == iso("2026-10-21T06:10:00+00:00"),
          String(describing: mirrored.fiveHourPercent))
    check("weekly_all row wins over the flat seven_day", mirrored.weeklyAllPercent == 23)

    check("real response shape → nothing unread", !(try UsageAPIClient.parse(response())).hasUnreadLimit)
} catch {
    check("unread-limit responses parse", false, "\(error)")
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
    var snap = UsageSnapshot.sample(now: Date())
    snap.extraLimits = [ExtraLimit(id: kind, kind: kind, scopeModel: nil, percent: percent,
                                   resetAt: resetAt, isActive: true)]
    snap.unknownTopLevel = [UnknownBucket(key: "iguana_necktie", utilization: utilization, resetAt: nil)]
    return snap
}

do {
    check("sample → log line nil", AuthDebugLog.usageUnknownLine(.sample(now: Date())) == nil)
    check("sample → dedupe key nil", AuthDebugLog.usageUnknownKey(.sample(now: Date())) == nil)

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

// MARK: (f2) a JSON bool is not a percentage (#135)

// JSONSerialization hands `true` back as an NSNumber worth 1, which `as? Double`
// reads as 1% — the openclaw and GitHub readers already refused it.
do {
    let limits = try UsageAPIClient.parse(body("""
        {"limits": [{"kind":"session","percent":true},
                    {"kind":"weekly_all","percent":false},
                    {"kind":"weekly_scoped","percent":true,
                     "scope":{"model":{"display_name":"Opus"}}},
                    {"kind":"bonus","percent":true}]}
        """))
    check("session percent true → unread, not 1%", limits.fiveHourPercent == nil,
          "\(String(describing: limits.fiveHourPercent))")
    check("weekly_all percent false → unread, not 0%", limits.weeklyAllPercent == nil,
          "\(String(describing: limits.weeklyAllPercent))")
    check("scoped / extra percent true → 0, not 1",
          limits.models.first?.percent == 0 && limits.extraLimits.first?.percent == 0,
          "\(limits.models.map(\.percent)) \(limits.extraLimits.map(\.percent))")

    let flat = try UsageAPIClient.parse(body(#"{"five_hour": {"utilization": true}, "seven_day": {"utilization": false}}"#))
    check("flat utilization bool → unread", flat.fiveHourPercent == nil && flat.weeklyAllPercent == nil,
          "\(String(describing: flat.fiveHourPercent)) \(String(describing: flat.weeklyAllPercent))")
} catch {
    check("response with bool percents parses", false, "\(error)")
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
    let snap = UsageSnapshot.sample(now: Date())
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

// MARK: session flags across refreshes (#44, #86, #90, #92, #103)

do {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    var snap = UsageSnapshot.sample(now: now)
    snap.fiveHourPercent = 42

    var s = UsageSession()
    s.begin(accessToken: "own", source: .oauthLogin)
    check("first refresh: signed-out → loading, account named", s.loadState == .loading && s.accountSource == .oauthLogin)
    s.loaded(snap, source: .oauthLogin)
    check("load → numbers and account", s.loadState == .loaded(.oauthLogin) && s.snapshot == snap)

    // #90 — the account row survives 429, error and the next fetch in flight.
    s.rateLimited(retryAfter: nil, now: now, pollBase: 180)
    check("429 keeps the account (#90)", s.accountSource == .oauthLogin)
    s.failed("x", now: now)
    check("error keeps the account and the numbers (#90, #92)", s.accountSource == .oauthLogin && s.snapshot == snap)
    s.begin(accessToken: "own", source: .oauthLogin)
    check("a fetch in flight does not go back to loading or drop the account",
          s.loadState == .error("x") && s.accountSource == .oauthLogin)

    // #86 — backoff climbs per 429, caps, and a load resets it.
    var b = UsageSession()
    for _ in 0..<6 { b.rateLimited(retryAfter: nil, now: now, pollBase: 180) }
    check("backoff caps", b.backoff == UsageSession.backoffCap)
    if case .rateLimited(let at) = b.loadState {
        check("retry time follows the capped backoff", at == UsageRetryPolicy.retryAt(now: now, base: 180, backoff: 4, retryAfter: nil))
    } else { check("retry time follows the capped backoff", false) }
    b.loaded(snap, source: .claudeCodeCLI)
    check("a load resets backoff", b.backoff == 0)

    // A rejected CLI token is not named as the account on its next try.
    var c = UsageSession()
    c.begin(accessToken: "cli", source: .claudeCodeCLI)
    c.rejected(accessToken: "cli", now: now)
    check("401 → signed out, no account", c.loadState == .signedOut && c.accountSource == nil)
    c.begin(accessToken: "cli", source: .claudeCodeCLI)
    check("the same rejected token is not named again", c.accountSource == nil)
    var c2 = c
    c2.loaded(snap, source: .claudeCodeCLI)
    check("the rejected token working again names the account", c2.accountSource == .claudeCodeCLI)
    c2.begin(accessToken: "cli", source: .claudeCodeCLI)
    check("…and it is no longer treated as rejected", c2.accountSource == .claudeCodeCLI)
    c.begin(accessToken: "cli2", source: .claudeCodeCLI)
    check("a rotated token is named", c.accountSource == .claudeCodeCLI)

    // #44 — the lapsed-login notice outlives the polls after it.
    var e = UsageSession()
    e.loaded(snap, source: .oauthLogin)
    e.expired(now: now)
    check("invalid_grant → lapsed notice, sample numbers",
          e.loadState == .sessionExpired && e.snapshot == .sample(now: now) && e.accountSource == nil)
    e.noToken(now: now)
    check("no token afterwards → notice kept (#44)", e.loadState == .sessionExpired)
    e.begin(accessToken: "cli", source: .claudeCodeCLI)
    e.rejected(accessToken: "cli", now: now)
    check("CLI 401 afterwards → notice kept, not plain signed-out (#44)", e.loadState == .sessionExpired)
    e.rateLimited(retryAfter: nil, now: now, pollBase: 180)
    e.noToken(now: now)
    check("a 429 in between does not wear the notice off (#44)", e.loadState == .sessionExpired)
    var e2 = e
    e2.loaded(snap, source: .claudeCodeCLI)
    e2.noToken(now: now)
    check("a successful fetch resolves the notice", e2.loadState == .signedOut)
    var e3 = e
    e3.signedIn()
    e3.noToken(now: now)
    check("signing in resolves the notice", e3.loadState == .signedOut)
    var e4 = e
    e4.signedOut(now: now)
    check("signing out resolves the notice", e4.loadState == .signedOut && e4.snapshot == .sample(now: now))
    e4.noToken(now: now)
    check("…and it stays resolved", e4.loadState == .signedOut)

    var p = UsageSession()
    p.present(snap, state: .loaded(.oauthLogin))
    check("snapshot hook names the account only for a loaded state", p.accountSource == .oauthLogin)
    p.present(snap, state: .rateLimited(retryAt: now))
    check("snapshot hook clears the account otherwise", p.accountSource == nil)
}

// MARK: expired own token refreshed before polling (#103)

do {
    check("only an expired own token is refreshed up front",
          UsageRefreshPolicy.shouldRenewUpFront(source: .oauthLogin, tokenExpired: true)
          && !UsageRefreshPolicy.shouldRenewUpFront(source: .oauthLogin, tokenExpired: false)
          && !UsageRefreshPolicy.shouldRenewUpFront(source: .claudeCodeCLI, tokenExpired: true))
    let renewedUpFront = OAuthToken(accessToken: "a2", refreshToken: "r2", expiresAt: nil)
    check("up-front refresh worked → poll with the new token",
          UsageRefreshPolicy.step(afterUpFront: .renewed(renewedUpFront)) == .useRenewed(renewedUpFront))
    check("up-front refresh rejected for good → lapsed login",
          UsageRefreshPolicy.step(afterUpFront: .sessionExpired) == .expireSession)
    check("up-front refresh blip → poll anyway",
          UsageRefreshPolicy.step(afterUpFront: .transientFailure) == .pollAnyway)
}

// MARK: usage threshold notifications (#95, #103)

do {
    var w = UsageThresholdWatch()
    check("under 25% → nothing", w.observe(percent: 10) == nil)
    check("crossing 25% → 25", w.observe(percent: 30) == 25)
    check("same level again → nothing", w.observe(percent: 40) == nil)
    check("jump past two levels → the highest only", w.observe(percent: 80) == 75)
    check("falling back within the window → nothing", w.observe(percent: 60) == nil)
    check("90% → 90", w.observe(percent: 95) == 90)
    check("window reset (under 25%) → nothing, but rearmed", w.observe(percent: 5) == nil && w.lastNotifiedLevel == 0)
    check("after the reset 25% fires again", w.observe(percent: 26) == 25)
}

// MARK: a renewal the Keychain could not take is held, not dropped (#108)

do {
    let old = OAuthToken(accessToken: "a1", refreshToken: "r1", expiresAt: nil)
    let renewed = OAuthToken(accessToken: "a2", refreshToken: "r2", expiresAt: nil)
    let other = OAuthToken(accessToken: "b", refreshToken: "rb", expiresAt: nil)
    let locked = OwnTokenLookup.unavailable(errSecInteractionNotAllowed)

    let holdsR1 = KeychainExpectation.holds(refreshToken: "r1")
    check("Keychain holds the token we started from → current",
          UsageRefreshPolicy.keychainMatch(own: .found(old), expects: holdsR1) == .current)
    check("Keychain holds another login → changed",
          UsageRefreshPolicy.keychainMatch(own: .found(other), expects: holdsR1) == .changed)
    check("Keychain emptied (signed out elsewhere) → changed",
          UsageRefreshPolicy.keychainMatch(own: .missing, expects: holdsR1) == .changed)
    check("Keychain locked or refused → unknown, not changed",
          UsageRefreshPolicy.keychainMatch(own: locked, expects: holdsR1) == .unknown
          && UsageRefreshPolicy.keychainMatch(own: .refused(errSecAuthFailed), expects: holdsR1) == .unknown)
    check("our own failed save emptied it → still current, not a sign-out",
          UsageRefreshPolicy.keychainMatch(own: .missing, expects: .maybeEmpty) == .current)
    check("…but anything written there since → changed",
          UsageRefreshPolicy.keychainMatch(own: .found(other), expects: .maybeEmpty) == .changed)

    let pending = PendingOwnToken(token: renewed, keychain: holdsR1)
    check("nothing held → nothing to do",
          UsageRefreshPolicy.resolvePending(nil, own: .found(old)) == PendingResolution.none)
    check("Keychain back, still holding the spent token → store the held one",
          UsageRefreshPolicy.resolvePending(pending, own: .found(old)) == .save(renewed))
    check("Keychain still locked → keep polling with the held one",
          UsageRefreshPolicy.resolvePending(pending, own: locked) == .useInMemory(renewed))
    check("Keychain moved on to another login → drop, never overwrite it",
          UsageRefreshPolicy.resolvePending(pending, own: .found(other)) == .drop)
    check("Keychain emptied by a sign-out → drop, never resurrect the login",
          UsageRefreshPolicy.resolvePending(pending, own: .missing) == .drop)
    check("Keychain already holds the held one (another instance stored it) → drop the copy",
          UsageRefreshPolicy.resolvePending(pending, own: .found(renewed)) == .drop)
    check("held after our own delete, Keychain still empty → store it",
          UsageRefreshPolicy.resolvePending(PendingOwnToken(token: renewed, keychain: .maybeEmpty), own: .missing)
              == .save(renewed))

    // Renewing again while polling with a held renewal keeps pointing at
    // what the Keychain really holds.
    check("polling with a plain token → expect that token",
          UsageRefreshPolicy.expectation(pending: nil, polling: old) == holdsR1)
    check("polling with the held renewal → expect what it replaces, not itself",
          UsageRefreshPolicy.expectation(pending: pending, polling: renewed) == holdsR1)
    check("a held renewal of some other token does not apply",
          UsageRefreshPolicy.expectation(pending: pending, polling: other) == .holds(refreshToken: "rb"))

    check("adopt: Keychain as found → store",
          UsageRefreshPolicy.adopt(match: .current, sameLogin: true) == .store)
    check("adopt: Keychain cannot say → hold",
          UsageRefreshPolicy.adopt(match: .unknown, sameLogin: true) == .hold)
    check("adopt: Keychain moved on → drop",
          UsageRefreshPolicy.adopt(match: .changed, sameLogin: true) == .drop)
    check("adopt: a sign-in or sign-out meanwhile → drop, even while locked",
          UsageRefreshPolicy.adopt(match: .unknown, sameLogin: false) == .drop
          && UsageRefreshPolicy.adopt(match: .current, sameLogin: false) == .drop)

    let newer = OAuthToken(accessToken: "a3", refreshToken: "r3", expiresAt: nil)
    check("stored → nothing held",
          UsageRefreshPolicy.pending(after: .saved, renewed: newer, expected: holdsR1) == nil)
    check("save failed, item untouched → held, Keychain still as before",
          UsageRefreshPolicy.pending(after: .failed, renewed: newer, expected: holdsR1)
              == PendingOwnToken(token: newer, keychain: holdsR1))
    check("held without trying → Keychain still as before",
          UsageRefreshPolicy.pending(after: nil, renewed: newer, expected: holdsR1)
              == PendingOwnToken(token: newer, keychain: holdsR1))
    check("save failed after our delete → held, Keychain may be empty",
          UsageRefreshPolicy.pending(after: .failedAfterDelete, renewed: newer, expected: holdsR1)
              == PendingOwnToken(token: newer, keychain: .maybeEmpty))

    // Storing a held renewal at the start of a refresh (#131): what stays
    // held keeps pointing at what the Keychain really holds.
    check("held renewal stored → nothing held",
          UsageRefreshPolicy.pending(afterSaving: pending, result: .saved) == nil)
    check("held renewal still not taken → Keychain still holds the spent token, not the held one",
          UsageRefreshPolicy.pending(afterSaving: pending, result: .failed) == pending)
    check("held renewal lost the item on our delete → Keychain may be empty",
          UsageRefreshPolicy.pending(afterSaving: pending, result: .failedAfterDelete)
              == PendingOwnToken(token: renewed, keychain: .maybeEmpty))
    let heldAfterDelete = PendingOwnToken(token: renewed, keychain: .maybeEmpty)
    check("held after our delete, save fails again → still maybe empty (carried over)",
          UsageRefreshPolicy.pending(afterSaving: heldAfterDelete, result: .failed) == heldAfterDelete)

    // The held renewal is polled with whatever the Keychain read said.
    let cliToken = OAuthToken(accessToken: "c", refreshToken: nil, expiresAt: nil)
    check("storing the held renewal → poll with it, not the spent token",
          UsageRefreshPolicy.chooseToken(resolution: .save(renewed), own: .found(old), cli: { cliToken })
              == .token(renewed, .oauthLogin))
    check("Keychain locked with a held renewal → poll with it, not wait",
          UsageRefreshPolicy.chooseToken(resolution: .useInMemory(renewed), own: locked, cli: { cliToken })
              == .token(renewed, .oauthLogin))
    check("held renewal dropped → the Keychain read decides",
          UsageRefreshPolicy.chooseToken(resolution: .drop, own: .missing, cli: { cliToken })
              == .token(cliToken, .claudeCodeCLI)
          && UsageRefreshPolicy.chooseToken(resolution: .none, own: .found(other), cli: { cliToken })
              == .token(other, .oauthLogin))
}

// MARK: what the usage surfaces show and offer (#90, #104)

do {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let retryAt = now.addingTimeInterval(600)
    func p(_ state: LoadState, _ source: DataSource?, limitsUnread: Bool = false) -> UsagePresentation {
        UsagePresentation(loadState: state, accountSource: source, limitsUnread: limitsUnread, now: now)
    }

    // #90 — the own login keeps "로그아웃" and never gets a login button
    // while a 429, an error or a fetch replaces the loaded state.
    for state in [LoadState.rateLimited(retryAt: retryAt), .error("x"), .loading, .loaded(.oauthLogin)] {
        let shown = p(state, .oauthLogin)
        check("own login in \(state): sign-out offered, account row is the login (#90)",
              shown.offersSignOut && shown.account == .ownLogin)
        check("own login in \(state): no login button on the banner (#90)", shown.bannerAction != .signIn)
    }
    check("CLI account: no sign-out (nothing of ours to sign out of)",
          !p(.loaded(.claudeCodeCLI), .claudeCodeCLI).offersSignOut
          && p(.loaded(.claudeCodeCLI), .claudeCodeCLI).account == .cliAccount)
    check("no account: the settings row offers a login",
          p(.signedOut, nil).account == .signedOut && p(.signedOut, .sample).account == .signedOut)

    check("signed out → sample badge, login button",
          p(.signedOut, nil).badge == .sample && p(.signedOut, nil).bannerAction == .signIn)
    check("lapsed login → its own banner, login button",
          p(.sessionExpired, nil).banner == .sessionExpired && p(.sessionExpired, nil).bannerAction == .signIn)
    check("error → retry button with the message",
          p(.error("x"), .oauthLogin).banner == .failed("x") && p(.error("x"), .oauthLogin).bannerAction == .retry)
    check("rate limited → no button on the banner, the poll retries by itself (#86)",
          p(.rateLimited(retryAt: retryAt), .oauthLogin).banner == .rateLimited(retryAt: retryAt)
          && p(.rateLimited(retryAt: retryAt), .oauthLogin).bannerAction == UsagePresentation.BannerAction.none)
    check("rate limited → manual refresh blocked until the retry time (#86)",
          p(.rateLimited(retryAt: retryAt), .oauthLogin).manualRefreshBlockedUntil == retryAt
          && p(.error("x"), .oauthLogin).manualRefreshBlockedUntil == nil)
    check("loading → no button", p(.loading, nil).bannerAction == UsagePresentation.BannerAction.none)
    check("loaded with own login → no banner, connected",
          p(.loaded(.oauthLogin), .oauthLogin).banner == UsagePresentation.Banner.none
          && p(.loaded(.oauthLogin), .oauthLogin).badge == .connected)
    check("loaded with the CLI token → the CLI banner, no button",
          p(.loaded(.claudeCodeCLI), .claudeCodeCLI).banner == .cliAccount
          && p(.loaded(.claudeCodeCLI), .claudeCodeCLI).bannerAction == UsagePresentation.BannerAction.none)
    check("badges: limited / failed / syncing",
          p(.rateLimited(retryAt: retryAt), nil).badge == .limited
          && p(.error("x"), nil).badge == .failed && p(.loading, nil).badge == .syncing)

    // #130 — a limit the response did not carry is explained, not shown as 0%.
    check("loaded with an unread limit → the format banner, no button, still connected",
          p(.loaded(.oauthLogin), .oauthLogin, limitsUnread: true).banner == .unreadLimits
          && p(.loaded(.oauthLogin), .oauthLogin, limitsUnread: true).bannerAction == UsagePresentation.BannerAction.none
          && p(.loaded(.oauthLogin), .oauthLogin, limitsUnread: true).badge == .connected)
    check("unread limit outranks the CLI-account notice",
          p(.loaded(.claudeCodeCLI), .claudeCodeCLI, limitsUnread: true).banner == .unreadLimits)
    check("unread limit does not hide an error or a rate limit",
          p(.error("x"), .oauthLogin, limitsUnread: true).banner == .failed("x")
          && p(.rateLimited(retryAt: retryAt), .oauthLogin, limitsUnread: true).banner == .rateLimited(retryAt: retryAt))
}

// MARK: #134 — a 401 sign-out drops the last real numbers like every other sign-out

do {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    var snap = UsageSnapshot.sample(now: now)
    snap.fiveHourPercent = 42

    var r = UsageSession()
    r.begin(accessToken: "cli", source: .claudeCodeCLI)
    r.loaded(snap, source: .claudeCodeCLI)
    r.rejected(accessToken: "cli", now: now)
    check("401 after real numbers → sample, signed out (#134)",
          r.snapshot == .sample(now: now) && r.loadState == .signedOut && r.accountSource == nil)

    // Every sign-out path agrees on what the user sees after real numbers.
    let paths: [(String, (inout UsageSession) -> Void)] = [
        ("noToken", { $0.noToken(now: now) }),
        ("rejected", { $0.rejected(accessToken: "cli", now: now) }),
        ("expired", { $0.expired(now: now) }),
        ("signedOut", { $0.signedOut(now: now) }),
    ]
    for (name, event) in paths {
        var x = UsageSession()
        x.loaded(snap, source: .claudeCodeCLI)
        event(&x)
        check("\(name) after real numbers → sample, no account (#134)",
              x.snapshot == .sample(now: now) && x.accountSource == nil)
    }
}

// MARK: #133 — the sample countdown is counted from the latest sign-out, not launch

do {
    let launch = Date(timeIntervalSince1970: 1_790_000_000)
    let later = launch.addingTimeInterval(10 * 3600)
    let samplePhrase = "3시간 8분 후 초기화"
    check("sample built at a moment reads 3시간 8분 then",
          TimeText.resetsIn(UsageSnapshot.sample(now: later).fiveHourResetAt, now: later) == samplePhrase)

    // Signed out at launch, still signed out ten hours on: a sample pinned to
    // launch would read 곧 초기화 by now and stay there.
    let paths: [(String, (inout UsageSession) -> Void)] = [
        ("noToken", { $0.noToken(now: later) }),
        ("rejected", { $0.rejected(accessToken: "cli", now: later) }),
        ("expired", { $0.expired(now: later) }),
        ("signedOut", { $0.signedOut(now: later) }),
    ]
    for (name, event) in paths {
        var x = UsageSession()
        x.present(.sample(now: launch), state: .signedOut)
        event(&x)
        let phrase = TimeText.resetsIn(x.snapshot.fiveHourResetAt, now: later)
        check("\(name) ten hours after launch → sample still reads 3시간 8분 (#133)",
              phrase == samplePhrase, phrase)
    }
}

// MARK: #133 — a locked Keychain while signed out keeps the sample counting from now

do {
    let launch = Date(timeIntervalSince1970: 1_790_000_000)
    let later = launch.addingTimeInterval(10 * 3600)
    let samplePhrase = "3시간 8분 후 초기화"

    var x = UsageSession()
    x.present(.sample(now: launch), state: .signedOut)
    x.failed("Keychain 이 잠겨 있어 로그인 정보를 읽지 못했습니다", now: later)
    let phrase = TimeText.resetsIn(x.snapshot.fiveHourResetAt, now: later)
    check("failed over a sample ten hours on → sample still reads 3시간 8분 (#133)",
          phrase == samplePhrase && x.loadState == .error("Keychain 이 잠겨 있어 로그인 정보를 읽지 못했습니다"),
          phrase)
    x.failed("again", now: later.addingTimeInterval(3600))
    check("failed again over the sample → rebuilt again",
          x.snapshot == .sample(now: later.addingTimeInterval(3600)))

    let real = UsageSnapshot(fiveHourPercent: 40, fiveHourResetAt: launch.addingTimeInterval(600),
                             weeklyAllPercent: 10, weeklyResetAt: nil, models: [], extraLimits: [],
                             unknownTopLevel: [], creditsText: nil, lastUpdated: launch)
    var y = UsageSession()
    y.loaded(real, source: .oauthLogin)
    y.failed("x", now: later)
    check("failed over real numbers → numbers kept as they were", y.snapshot == real)

    // Signed in, first poll 429s: the sample stays up through the backoff.
    var z = UsageSession()
    z.present(.sample(now: launch), state: .signedOut)
    z.rateLimited(retryAfter: nil, now: later, pollBase: 60)
    let limitedPhrase = TimeText.resetsIn(z.snapshot.fiveHourResetAt, now: later)
    check("rateLimited over a sample ten hours on → sample still reads 3시간 8분 (#133)",
          limitedPhrase == samplePhrase, limitedPhrase)
    var w = UsageSession()
    w.loaded(real, source: .oauthLogin)
    w.rateLimited(retryAfter: nil, now: later, pollBase: 60)
    check("rateLimited over real numbers → numbers kept as they were", w.snapshot == real)
}

// MARK: #132 — a held renewal is stored again while the Keychain refuses

do {
    let renewed = OAuthToken(accessToken: "a2", refreshToken: "r2", expiresAt: nil)
    let refused = OwnTokenLookup.refused(errSecAuthFailed)
    let held = PendingOwnToken(token: renewed, keychain: .holds(refreshToken: "r1"))
    let heldAfterDelete = PendingOwnToken(token: renewed, keychain: .maybeEmpty)
    check("Keychain refuses with a held renewal → try to store it again, every poll",
          UsageRefreshPolicy.resolvePending(held, own: refused) == .save(renewed)
          && UsageRefreshPolicy.resolvePending(heldAfterDelete, own: refused) == .save(renewed))
    check("Keychain locked with a held renewal → still only kept in memory",
          UsageRefreshPolicy.resolvePending(held, own: .unavailable(errSecInteractionNotAllowed))
              == .useInMemory(renewed))
    check("prompt cancelled with a held renewal → kept in memory, not stored again",
          UsageRefreshPolicy.resolvePending(held, own: .refused(errSecUserCanceled)) == .useInMemory(renewed))
    check("refused with nothing held → nothing to do",
          UsageRefreshPolicy.resolvePending(nil, own: refused) == PendingResolution.none)
    let cliToken = OAuthToken(accessToken: "c", refreshToken: nil, expiresAt: nil)
    check("retrying the store while refused → poll with the held renewal, not the CLI token",
          UsageRefreshPolicy.chooseToken(resolution: UsageRefreshPolicy.resolvePending(held, own: refused),
                                         own: refused, cli: { cliToken })
              == .token(renewed, .oauthLogin))
}

// MARK: #143 — a declined Keychain prompt is not put back by the polls

do {
    let old = OAuthToken(accessToken: "a1", refreshToken: "r1", expiresAt: nil)
    let renewed = OAuthToken(accessToken: "a2", refreshToken: "r2", expiresAt: nil)
    let cliToken = OAuthToken(accessToken: "c", refreshToken: nil, expiresAt: nil)
    let held = PendingOwnToken(token: renewed, keychain: .holds(refreshToken: "r1"))
    let cancelled = OwnTokenLookup.refused(errSecUserCanceled)

    // Which statuses are the user's answer.
    check("errSecUserCanceled is the user's answer to the prompt",
          OwnTokenLookup.isUserRefusal(errSecUserCanceled))
    check("errSecAuthFailed is not counted as the user's answer (also a no-prompt ACL refusal, #132)",
          !OwnTokenLookup.isUserRefusal(errSecAuthFailed))

    // The save result keeps a cancelled prompt apart from a plain failure.
    check("save: success → saved", OwnTokenSave(status: errSecSuccess, deletedFirst: false) == .saved)
    check("save: prompt cancelled → cancelled, not failed",
          OwnTokenSave(status: errSecUserCanceled, deletedFirst: false) == .cancelled)
    check("save: other refusal → failed", OwnTokenSave(status: errSecAuthFailed, deletedFirst: false) == .failed)
    check("save: cancelled after our delete → failedAfterDelete (an empty Keychain outranks the answer)",
          OwnTokenSave(status: errSecUserCanceled, deletedFirst: true) == .failedAfterDelete)

    // A save that recreates the item: the delete's prompt cancelled → no add,
    // and the save reads as the user's answer (not a duplicate-item failure).
    var adds = 0
    let cancelledDelete = CredentialStore.recreate(delete: { errSecUserCanceled },
                                                   add: { adds += 1; return errSecDuplicateItem })
    check("recreate: delete prompt cancelled → add not tried, save cancelled",
          adds == 0 && OwnTokenSave(status: cancelledDelete.status, deletedFirst: cancelledDelete.deleted) == .cancelled,
          "\(adds) adds, status \(cancelledDelete.status)")
    let recreated = CredentialStore.recreate(delete: { errSecSuccess }, add: { adds += 1; return errSecSuccess })
    check("recreate: delete and add pass → saved", adds == 1 && recreated == (errSecSuccess, true))
    let lostAfterDelete = CredentialStore.recreate(delete: { errSecSuccess }, add: { errSecIO })
    check("recreate: add fails after the delete → failedAfterDelete",
          OwnTokenSave(status: lostAfterDelete.status, deletedFirst: lostAfterDelete.deleted) == .failedAfterDelete)
    let refusedDelete = CredentialStore.recreate(delete: { errSecAuthFailed }, add: { errSecDuplicateItem })
    check("recreate: delete refused otherwise → add still tried, a plain failure",
          OwnTokenSave(status: refusedDelete.status, deletedFirst: refusedDelete.deleted) == .failed)

    // Remembering the decline.
    check("read cancelled → decline remembered", UsageRefreshPolicy.declined(false, after: cancelled, sameLogin: true))
    check("read refused otherwise → no decline (the #132 store retry stays)",
          !UsageRefreshPolicy.declined(false, after: .refused(errSecAuthFailed), sameLogin: true))
    check("read found / missing / locked → no decline",
          !UsageRefreshPolicy.declined(false, after: .found(old), sameLogin: true)
          && !UsageRefreshPolicy.declined(false, after: .missing, sameLogin: true)
          && !UsageRefreshPolicy.declined(false, after: .unavailable(errSecInteractionNotAllowed), sameLogin: true))
    check("save cancelled → decline remembered", UsageRefreshPolicy.declined(false, afterSaving: .cancelled, sameLogin: true))
    check("save failed / saved → no decline",
          !UsageRefreshPolicy.declined(false, afterSaving: .failed, sameLogin: true)
          && !UsageRefreshPolicy.declined(false, afterSaving: .saved, sameLogin: true)
          && !UsageRefreshPolicy.declined(false, afterSaving: .failedAfterDelete, sameLogin: true))
    check("a poll does not lift a standing decline, whatever it reads or saves",
          UsageRefreshPolicy.declined(true, after: .found(old), sameLogin: true)
          && UsageRefreshPolicy.declined(true, after: .missing, sameLogin: true)
          && UsageRefreshPolicy.declined(true, afterSaving: .saved, sameLogin: true))

    // While declined, a poll reads nothing from the Keychain…
    var reads = 0
    let read: () -> OwnTokenLookup = { reads += 1; return .found(old) }
    let whileDeclined = UsageRefreshPolicy.ownLookup(declined: true) ?? read()
    check("declined → the own item is not read (no prompt)", reads == 0, "\(reads) reads")
    check("declined → the read answers as the refusal it was", whileDeclined == cancelled)
    // …and stores nothing.
    check("declined with a held renewal → kept in memory, not stored",
          UsageRefreshPolicy.resolvePending(held, own: whileDeclined) == .useInMemory(renewed))
    check("declined with a held renewal → polls with it, not the CLI token",
          UsageRefreshPolicy.chooseToken(resolution: .useInMemory(renewed), own: whileDeclined, cli: { cliToken })
              == .token(renewed, .oauthLogin))
    check("declined with nothing held → the CLI token, as a refusal did before",
          UsageRefreshPolicy.chooseToken(resolution: UsageRefreshPolicy.resolvePending(nil, own: whileDeclined),
                                         own: whileDeclined, cli: { cliToken })
              == .token(cliToken, .claudeCodeCLI))
    check("declined while adopting a renewal → held, not stored",
          UsageRefreshPolicy.adopt(match: UsageRefreshPolicy.keychainMatch(own: whileDeclined, expects: held.keychain),
                                   sameLogin: true) == .hold)
    check("save cancelled → the renewal stays held against the item as it was",
          UsageRefreshPolicy.pending(afterSaving: held, result: .cancelled) == held)

    // The user acting (sign-in, a manual refresh) lifts the flag: the read happens again.
    let afterUserActs = UsageRefreshPolicy.ownLookup(declined: false) ?? read()
    check("decline lifted → the own item is read again", reads == 1 && afterUserActs == .found(old), "\(reads) reads")
    check("decline lifted, Keychain found → a held renewal is stored again",
          UsageRefreshPolicy.resolvePending(held, own: afterUserActs) == .save(renewed))
}

// MARK: #141 — Keychain calls off the main thread: what may land between the awaits

do {
    let old = OAuthToken(accessToken: "a1", refreshToken: "r1", expiresAt: nil)
    let renewed = OAuthToken(accessToken: "a2", refreshToken: "r2", expiresAt: nil)
    let cancelled = OwnTokenLookup.refused(errSecUserCanceled)

    // A poll read is out; meanwhile the sign-in's save is cancelled and sets
    // the flag. The read then comes back `.found` — folded into the flag as it
    // is now (true), the decline stands; folded into the value captured when
    // the read went out (false), it would be lifted and the dialog come back.
    check("save cancelled while a poll read was out → the read's .found keeps the decline",
          UsageRefreshPolicy.declined(true, after: .found(old), sameLogin: true)
          && !UsageRefreshPolicy.declined(false, after: .found(old), sameLogin: true))
    // A read or save that went out before a sign-in or sign-out: the sign-in
    // lifted the flag, and an answer about the item before it sets nothing.
    check("answer from before a sign-in → does not set the decline again",
          !UsageRefreshPolicy.declined(false, after: cancelled, sameLogin: false)
          && !UsageRefreshPolicy.declined(false, afterSaving: .cancelled, sameLogin: false))
    check("answer from before a sign-in → does not lift a decline set since",
          UsageRefreshPolicy.declined(true, after: .found(old), sameLogin: false)
          && UsageRefreshPolicy.declined(true, afterSaving: .saved, sameLogin: false))

    // The CLI token (another Keychain read, which can prompt) is read only
    // when the choice falls through to it.
    check("own token found / held renewal / locked → no CLI read",
          UsageRefreshPolicy.ownChoice(resolution: .none, own: .found(old)) == .token(old, .oauthLogin)
          && UsageRefreshPolicy.ownChoice(resolution: .useInMemory(renewed), own: cancelled) == .token(renewed, .oauthLogin)
          && UsageRefreshPolicy.ownChoice(resolution: .save(renewed), own: .missing) == .token(renewed, .oauthLogin)
          && UsageRefreshPolicy.ownChoice(resolution: .none, own: .unavailable(errSecInteractionNotAllowed))
              == .ownUnavailable(errSecInteractionNotAllowed))
    check("own token missing / refused / dropped → the CLI token is next",
          UsageRefreshPolicy.ownChoice(resolution: .none, own: .missing) == nil
          && UsageRefreshPolicy.ownChoice(resolution: .none, own: cancelled) == nil
          && UsageRefreshPolicy.ownChoice(resolution: .drop, own: .missing) == nil)
    check("CLI token read → that token, or none",
          UsageRefreshPolicy.cliChoice(old) == .token(old, .claudeCodeCLI)
          && UsageRefreshPolicy.cliChoice(nil) == UsageTokenChoice.none)

    // The queue every SecItem call runs on: off the main thread, one job at a
    // time, in the order asked for from one caller.
    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private(set) var peak = 0
        private(set) var order: [Int] = []
        private(set) var onMain = false
        func job(_ index: Int, pause: TimeInterval = 0.005) -> Int {
            lock.lock()
            active += 1
            peak = max(peak, active)
            if Thread.isMainThread { onMain = true }
            lock.unlock()
            Thread.sleep(forTimeInterval: pause)
            lock.lock()
            active -= 1
            order.append(index)
            lock.unlock()
            return index
        }
    }
    let probe = Probe()
    let jobCount = 8
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        await withTaskGroup(of: Int.self) { group in
            for index in 0..<jobCount {
                group.addTask { await KeychainQueue.run { probe.job(index) } }
            }
        }
        for index in 0..<jobCount { _ = await KeychainQueue.run { probe.job(100 + index) } }
        done.signal()
    }
    done.wait()
    check("Keychain queue: never two jobs at once", probe.peak == 1, "peak \(probe.peak)")
    check("Keychain queue: not on the main thread", !probe.onMain)
    check("Keychain queue: one caller's jobs run in the order asked",
          Array(probe.order.suffix(jobCount)) == (0..<jobCount).map { 100 + $0 }, "\(probe.order)")

    // Calls started one after another on the main actor, no await between
    // them, run on the queue in that order: each is queued before its task
    // first suspends, on the caller's actor — not after a hop to the global
    // executor, where the order is lost. This is what lets a sign-in's save
    // land after a poll's delete asked for before it.
    let ordered = Probe()
    let orderedCount = 64
    var finished = 0
    MainActor.assumeIsolated {
        for index in 0..<orderedCount {
            Task { @MainActor in
                _ = await KeychainQueue.run { ordered.job(index, pause: 0) }
                finished += 1
            }
        }
    }
    let deadline = Date().addingTimeInterval(10)
    while finished < orderedCount, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    check("Keychain queue: calls from the main actor run in the order made",
          ordered.order == Array(0..<orderedCount), "\(ordered.order)")

    // Quitting waits for queued work, but not past the cap.
    @MainActor final class Drains {
        var afterSlow: [Int]?
        var cappedAt: Date?
    }
    let drains = MainActor.assumeIsolated { Drains() }
    // Each job signals once it is running, so the drain below is queued after
    // it by construction rather than by a sleep that a loaded machine outruns.
    let slow = Probe()
    let slowStarted = DispatchSemaphore(value: 0)
    Task.detached { _ = await KeychainQueue.run { slowStarted.signal(); return slow.job(1, pause: 0.05) } }
    slowStarted.wait()
    KeychainQueue.whenDrained(timeout: 5) { drains.afterSlow = slow.order }
    let blocker = DispatchSemaphore(value: 0)
    let blockerStarted = DispatchSemaphore(value: 0)
    Task.detached { _ = await KeychainQueue.run { blockerStarted.signal(); blocker.wait() } }
    blockerStarted.wait()
    let cappedStart = Date()
    KeychainQueue.whenDrained(timeout: 0.2) { drains.cappedAt = Date() }
    let drainDeadline = Date().addingTimeInterval(5)
    while MainActor.assumeIsolated({ drains.afterSlow == nil || drains.cappedAt == nil }), Date() < drainDeadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    blocker.signal()
    let (afterSlow, cappedAt) = MainActor.assumeIsolated { (drains.afterSlow, drains.cappedAt) }
    check("Keychain queue: drain waits for the job queued before it", afterSlow == [1], "\(String(describing: afterSlow))")
    check("Keychain queue: drain gives up at the cap while a job hangs (a prompt left up)",
          cappedAt.map { (0.15..<2).contains($0.timeIntervalSince(cappedStart)) } ?? false,
          "\(String(describing: cappedAt.map { $0.timeIntervalSince(cappedStart) }))")
}

// MARK: #133 — reset phrases are made at draw time; flat fallbacks are logged

do {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let reset = now.addingTimeInterval(3 * 3600 + 8 * 60)
    check("countdown follows the clock it is drawn with",
          TimeText.resetsIn(reset, now: now) == "3시간 8분 후 초기화"
          && TimeText.resetsIn(reset, now: now.addingTimeInterval(3 * 3600)) == "8분 후 초기화",
          TimeText.resetsIn(reset, now: now.addingTimeInterval(3 * 3600)))
    check("past the reset → 곧 초기화", TimeText.resetsIn(reset, now: reset) == "곧 초기화")
    check("no reset time → empty, not 곧 초기화", TimeText.resetsIn(nil, now: now) == "",
          TimeText.resetsIn(nil, now: now))
    check("weekly phrase: no reset time → empty", TimeText.resetsAt(nil) == "")

    // The real shape with its session row renamed: the flat `five_hour`
    // (utilization 4) fills the window and the log says so.
    let renamedBody = String(decoding: response(), as: UTF8.self)
        .replacingOccurrences(of: #""kind":"session""#, with: #""kind":"session_v2""#)
    let renamed = try UsageAPIClient.parse(body(renamedBody))
    check("session row renamed, five_hour present → read flat and noted",
          renamed.fiveHourPercent == 4 && renamed.flatFallbacks == ["five_hour"],
          "\(String(describing: renamed.fiveHourPercent)) \(renamed.flatFallbacks)")
    let line = AuthDebugLog.usageUnknownLine(renamed) ?? ""
    check("flat fallback → a log line naming the window",
          line.contains("read flat five_hour"), line)
    check("flat fallback → a dedupe key, so the line is written once",
          AuthDebugLog.usageUnknownKey(renamed) != nil)

    let flatOnly = try UsageAPIClient.parse(body(#"{"five_hour": {"utilization": 41}, "seven_day": {"utilization": 9}}"#))
    check("no limits array → flat objects read, nothing noted",
          flatOnly.fiveHourPercent == 41 && flatOnly.weeklyAllPercent == 9 && flatOnly.flatFallbacks.isEmpty,
          "\(flatOnly.flatFallbacks)")
    check("real response shape → nothing noted", (try UsageAPIClient.parse(response())).flatFallbacks.isEmpty)
} catch {
    check("#133 responses parse", false, "\(error)")
}

// MARK: #135 — credits amounts read as JSON numbers, never bools

do {
    func credits(limit: String, used: String = "0", exponent: String = "2") -> String? {
        let spend = #""spend": {"enabled": true, "limit": {"amount_minor": \#(limit), "exponent": \#(exponent)}, "used": {"amount_minor": \#(used)}}"#
        let text = String(decoding: response(), as: UTF8.self).replacingOccurrences(of: #""spend": null"#, with: spend)
        return (try? UsageAPIClient.interpret(statusCode: 200, retryAfter: nil, data: body(text)))?.creditsText
    }
    check("credits: minor units over 10^exponent", credits(limit: "1050", used: "630") == "크레딧 $4.20 남음",
          "\(String(describing: credits(limit: "1050", used: "630")))")
    check("credits: exponent missing → 2", credits(limit: "500", exponent: "null") == "크레딧 $5.00 남음")
    check("credits: exponent true → default 2, not 1",
          credits(limit: "500", exponent: "true") == "크레딧 $5.00 남음",
          "\(String(describing: credits(limit: "500", exponent: "true")))")
    check("credits: exponent 0 kept", credits(limit: "5", exponent: "0") == "크레딧 $5.00 남음")
    check("credits: amount true → 0, not 1 cent",
          credits(limit: "true", exponent: "0") == "크레딧 $0.00 남음",
          "\(String(describing: credits(limit: "true", exponent: "0")))")
    check("credits: used true → 0", credits(limit: "100", used: "true", exponent: "0") == "크레딧 $100.00 남음")
    check("credits: fractional amount → 0 (integers only, as before)",
          credits(limit: "1.5", exponent: "0") == "크레딧 $0.00 남음")
    check("credits: negative used kept", credits(limit: "100", used: "-50", exponent: "0") == "크레딧 $150.00 남음")
    check("credits: exponent 6 (top of range) kept", credits(limit: "5000000", exponent: "6") == "크레딧 $5.00 남음")
    for bad in ["-1", "7", "-400", "400"] {
        let text = credits(limit: "500", exponent: bad)
        check("credits: exponent \(bad) out of range → no credits line, not $inf / $0.00",
              text == nil, "\(String(describing: text))")
    }
    // Int.max reads as 2^63 through Double, out of Int's range → nil → 0;
    // -(Int.max) rounds to -2^63 = Int.min, which Int holds. Subtracting must
    // not trap either way.
    let extreme = credits(limit: "9223372036854775807", used: "-9223372036854775807", exponent: "0")
    check("credits: extreme Ints don't trap — 0 - Int.min as a Double",
          extreme == "크레딧 $9223372036854775808.00 남음", "\(String(describing: extreme))")
    check("integer: exact within ±2^53",
          JSONNumber.integer(NSNumber(value: 1 << 53)) == 1 << 53
          && JSONNumber.integer(NSNumber(value: -(1 << 53))) == -(1 << 53))
    check("integer: past 2^53 → nearest Double, not the digits sent",
          JSONNumber.integer(NSNumber(value: (1 << 53) + 1)) == 1 << 53)
    check("integer: Int.max rounds to 2^63 → nil", JSONNumber.integer(NSNumber(value: Int.max)) == nil)
    check("integer: Int.min is -2^63 exactly → kept", JSONNumber.integer(NSNumber(value: Int.min)) == Int.min)
}

// MARK: #147 — a lapse the Keychain cannot confirm is still told

do {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let dead = OAuthToken(accessToken: "a1", refreshToken: "r1", expiresAt: nil)
    let holdsR1 = KeychainExpectation.holds(refreshToken: "r1")
    let snap = UsageSnapshot(fiveHourPercent: 10, fiveHourResetAt: nil,
                             weeklyAllPercent: 20, weeklyResetAt: nil, models: [], extraLimits: [],
                             unknownTopLevel: [], creditsText: nil, lastUpdated: now)
    func lapse(_ own: OwnTokenLookup) -> LapseStep {
        UsageRefreshPolicy.lapse(match: UsageRefreshPolicy.keychainMatch(own: own, expects: holdsR1))
    }

    check("lapse, Keychain holds the dead token → delete it and tell",
          lapse(.found(dead)) == .discard)
    // A remembered decline (#143) answers every read with this refusal — so
    // this is every invalid_grant while the decline stands.
    check("lapse, prompt declined → told, item kept (it may be another login)",
          lapse(UsageRefreshPolicy.rememberedRefusal) == .noticeOnly)
    check("lapse, Keychain locked or refused → told, item kept",
          lapse(.unavailable(errSecInteractionNotAllowed)) == .noticeOnly
          && lapse(.refused(errSecAuthFailed)) == .noticeOnly)
    check("lapse, Keychain moved on (another login, a sign-out) → nothing over it",
          lapse(.found(OAuthToken(accessToken: "b", refreshToken: "rb", expiresAt: nil))) == .leave
          && lapse(.missing) == .leave)

    // The kept item lapses again once it reads: one notification, not two.
    var s = UsageSession()
    s.loaded(snap, source: .oauthLogin)
    check("first lapse is news", s.lapseIsNews)
    s.expired(now: now)
    check("a second lapse under the notice is not news (no second notification)", !s.lapseIsNews)
    s.noToken(now: now)
    check("…nor after the polls that follow it", !s.lapseIsNews)
    var resolved = s
    resolved.loaded(snap, source: .claudeCodeCLI)
    check("a lapse after the notice was resolved by a fetch is news again", resolved.lapseIsNews)
    var signedIn = s
    signedIn.signedIn()
    check("a lapse after signing in again is news again", signedIn.lapseIsNews)
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
