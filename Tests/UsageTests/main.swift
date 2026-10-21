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
// otherwise; and its dedupe key ignores the moving numbers.
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
    // as the weekly_scoped row, and no reset time leaves the caption empty
    // rather than invented.
    let snap = try UsageAPIClient.parse(response(extraLimits: """
        ,{"kind":"bonus","percent":50,
          "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}
        """))
    let extra = snap.extraLimits.first
    check("scoped unknown kind → name matches the weekly_scoped spelling",
          extra?.name == snap.models.first?.name && extra?.name == "Fable 5", extra?.name ?? "nil")
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

// MARK: result

if failures.isEmpty {
    print("\nUsage tests: all passed")
    exit(0)
} else {
    print("\nUsage tests: \(failures.count) failed")
    failures.forEach { print("  - \($0)") }
    exit(1)
}
