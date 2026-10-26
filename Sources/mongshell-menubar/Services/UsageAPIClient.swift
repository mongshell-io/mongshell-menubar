import Foundation

enum APIError: Error, Equatable {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case badResponse
}

/// Calls the (unofficial) subscription usage endpoint and maps the response
/// into a `UsageSnapshot`. The shape `parse` reads is the one the endpoint
/// returned on 2026-10-21 (pinned as the fixture in `Tests/UsageTests`). The
/// schema is still undocumented and may change without notice, so decoding
/// stays deliberately tolerant: it probes several candidate key paths and
/// fills what it can.
///
/// The request carries the Bearer token, so it goes through `BoundedHTTP`:
/// no redirect is followed (a 3xx can't carry the token to another host),
/// nothing is cached, and the body is read only up to
/// `Config.usageMaxResponseBytes`.
struct UsageAPIClient {
    /// The endpoint answers in well under a second. Past this the poll gives
    /// up and the next one (at least `Config.minPollInterval` later) tries
    /// again, instead of a stalled request holding the loop.
    static let requestTimeout: TimeInterval = 30

    private static let session = BoundedHTTP.makeSession(timeout: requestTimeout)

    func fetch(token: OAuthToken) async throws -> UsageSnapshot {
        var req = URLRequest(url: Config.usageURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(Config.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(Config.anthropicBeta, forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await BoundedHTTP.download(
                req, session: Self.session, maxBytes: Config.usageMaxResponseBytes,
                readsBody: Self.readsBody(statusCode:))
        } catch is BoundedHTTP.ResponseTooLarge {
            throw APIError.badResponse
        } catch {
            // Transport failure, timeout or cancellation — the model shows
            // one error state for all of them, as before.
            throw APIError.badResponse
        }
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
        return try Self.interpret(statusCode: http.statusCode,
                                  retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                                  data: data)
    }

    /// Only a 200 carries a usage document. Every other code is judged on the
    /// code and the `Retry-After` header alone, so a large error page still
    /// surfaces as 401/429/… rather than tripping the size cap.
    static func readsBody(statusCode: Int) -> Bool {
        statusCode == 200
    }

    /// Status code → snapshot or error. Split from `fetch` so the mapping the
    /// model branches on (401/403 → re-auth, 429 → back off) is testable
    /// without a server.
    static func interpret(statusCode: Int, retryAfter: String?, data: Data) throws -> UsageSnapshot {
        switch statusCode {
        case 200:
            return try parse(data)
        case 401, 403:
            throw APIError.unauthorized
        case 429:
            throw APIError.rateLimited(retryAfter: retryAfter.flatMap(TimeInterval.init))
        default:
            throw APIError.http(statusCode)
        }
    }

    // MARK: - Tolerant decoding

    /// Real (undocumented) schema. The authoritative per-limit data is the
    /// `limits` array; each entry has an int `percent`, a `kind`, `resets_at`,
    /// and (for scoped rows) `scope.model.display_name`:
    /// ```
    /// "limits": [
    ///   { "kind":"session",       "percent":64, "resets_at":"…" },
    ///   { "kind":"weekly_all",     "percent":23, "resets_at":"…" },
    ///   { "kind":"weekly_scoped",  "percent":29, "resets_at":"…",
    ///     "scope":{ "model":{ "display_name":"Fable" } } } ]
    /// ```
    /// (`five_hour`/`seven_day` objects mirror session/weekly_all; the old
    /// `seven_day_<model>` keys are always null now.)
    ///
    /// Any other `kind` (a limit reset or bonus granted from the settings
    /// page would arrive as one) is kept as an `ExtraLimit` rather than
    /// dropped, and the code-named top-level objects (`iguana_necktie`…) are
    /// noted in `unknownTopLevel` so the debug log can say what came.
    static func parse(_ data: Data) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.badResponse
        }

        // nil until read: a limit the response no longer names stays unread
        // rather than showing as 0% (#130).
        var fivePct: Int?, weeklyPct: Int?
        var fiveReset: Date?, weeklyReset: Date?
        var models: [ModelUsage] = []
        var extraLimits: [ExtraLimit] = []
        var seenExtraKinds: [String: Int] = [:]

        let limits = root["limits"] as? [[String: Any]] ?? []
        for limit in limits {
            let pct = percentInt(limit["percent"])
            let reset = ResponseDate.parse(limit["resets_at"])
            // Pretty-printed in both rows below, so one model never shows
            // under two spellings ("Fable" / "Fable 5") in the same section.
            let scopeModel = scopeModelName(limit).map(prettyModelName)
            switch limit["kind"] as? String {
            // A row whose percent cannot be read leaves its reset unread too:
            // the window has no value, so no reset time or countdown is drawn
            // beside the empty ring (#130).
            case "session":
                fivePct = percentValue(limit["percent"])
                fiveReset = fivePct == nil ? nil : reset
            case "weekly_all":
                weeklyPct = percentValue(limit["percent"])
                weeklyReset = weeklyPct == nil ? nil : reset
            case "weekly_scoped":
                models.append(ModelUsage(name: scopeModel ?? "모델", percent: pct))
            case let rawKind?:
                let kind = displayText(rawKind)
                guard !kind.isEmpty, extraLimits.count < Config.usageExtraLimitsCap else { break }
                let seen = seenExtraKinds[kind, default: 0]
                seenExtraKinds[kind] = seen + 1
                extraLimits.append(ExtraLimit(
                    id: seen == 0 ? kind : "\(kind)-\(seen)",
                    kind: kind,
                    scopeModel: scopeModel,
                    percent: pct,
                    resetAt: reset,
                    isActive: limit["is_active"] as? Bool))
            case nil:
                break
            }
        }

        // The flat objects mirror session/weekly_all, so each is the
        // fallback for its own window when `limits` is absent or no longer
        // carries a readable row for it. A fallback taken while `limits` is
        // there is noted for the debug log: the row it replaced went away.
        var flatFallbacks: [String] = []
        if fivePct == nil, let five = root["five_hour"] as? [String: Any],
           let pct = percentValue(five["utilization"]) {
            fivePct = pct; fiveReset = ResponseDate.parse(five["resets_at"])
            if !limits.isEmpty { flatFallbacks.append("five_hour") }
        }
        if weeklyPct == nil, let weekly = root["seven_day"] as? [String: Any],
           let pct = percentValue(weekly["utilization"]) {
            weeklyPct = pct; weeklyReset = ResponseDate.parse(weekly["resets_at"])
            if !limits.isEmpty { flatFallbacks.append("seven_day") }
        }

        return UsageSnapshot(
            fiveHourPercent: fivePct,
            fiveHourResetAt: fiveReset,
            weeklyAllPercent: weeklyPct,
            weeklyResetAt: weeklyReset,
            models: models,
            extraLimits: extraLimits,
            unknownTopLevel: unknownTopLevel(in: root),
            flatFallbacks: flatFallbacks,
            creditsText: creditsText(from: root),
            lastUpdated: Date()
        )
    }

    /// Top-level keys that are not "unknown": the ones the app reads, plus
    /// ones it does not read but whose shape it knows (`seven_day_breakdown`
    /// is an object of per-model rows, `weekly_scoped_shares` an array,
    /// `member_dashboard_available` a bool) — those must not log a line on
    /// every launch. Everything else is a code-named candidate.
    private static let knownTopLevelKeys: Set<String> = [
        "limits", "five_hour", "seven_day", "spend", "extra_usage",
        "seven_day_breakdown", "weekly_scoped_shares", "member_dashboard_available",
    ]

    /// The code-named top-level objects, sorted by key so the summary line is
    /// stable across polls. Null-valued keys (most of them) are skipped, as is
    /// a key that flattens to nothing, and past the cap the rest are dropped.
    private static func unknownTopLevel(in root: [String: Any]) -> [UnknownBucket] {
        let buckets: [UnknownBucket] = root.keys.sorted().compactMap { key in
            guard !knownTopLevelKeys.contains(key),
                  let object = root[key] as? [String: Any] else { return nil }
            let name = displayText(key)
            guard !name.isEmpty else { return nil }
            return UnknownBucket(key: name,
                                 utilization: percentValue(object["utilization"]),
                                 resetAt: ResponseDate.parse(object["resets_at"]))
        }
        return Array(buckets.prefix(Config.usageUnknownTopLevelCap))
    }

    /// Cents: the exponent is the currency's minor-unit count (ISO 4217),
    /// 2 for USD, which is what an absent one has always meant here.
    private static let defaultCreditsExponent = 2
    /// ISO 4217 minor units run 0 (JPY) to 4 (CLF); a little headroom past
    /// that, nothing negative.
    private static let creditsExponentRange = 0...6

    /// Usage-credits balance — shown ONLY when the user has the pay-as-you-go
    /// credits feature enabled (amounts are minor units, e.g. cents). We
    /// deliberately don't surface the "disabled/out_of_credits" state, since
    /// for users who never opted in it reads as misleading.
    private static func creditsText(from root: [String: Any]) -> String? {
        guard let spend = root["spend"] as? [String: Any],
              (spend["enabled"] as? Bool) == true,
              let limit = spend["limit"] as? [String: Any],
              let used = spend["used"] as? [String: Any] else { return nil }
        let exp = JSONNumber.integer(limit["exponent"]) ?? defaultCreditsExponent
        // A wrong figure is worse than none: an exponent past any currency's
        // minor-unit count misreads the amount, and at the extremes 10^exp
        // becomes 0 or inf and the line reads "$inf", "$nan" or a false "$0.00".
        guard creditsExponentRange.contains(exp) else { return nil }
        let divisor = pow(10.0, Double(exp))
        // Subtracted as Doubles: two extreme Ints would trap on overflow.
        let remaining = (Double(JSONNumber.integer(limit["amount_minor"]) ?? 0)
                         - Double(JSONNumber.integer(used["amount_minor"]) ?? 0)) / divisor
        return String(format: "크레딧 $%.2f 남음", max(0, remaining))
    }

    // MARK: helpers

    private static func scopeModelName(_ limit: [String: Any]) -> String? {
        let name = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
        return name.map(displayText)
    }

    /// Every response string that reaches a label or the log goes through
    /// here: one line, at most `Config.usageDisplayTextLimit` characters.
    private static func displayText(_ raw: String) -> String {
        DisplayText.flatten(raw, limit: Config.usageDisplayTextLimit)
    }

    /// `utilization` is a 0…100 percentage already — round + clamp, no scaling.
    private static func percentInt(_ any: Any?) -> Int {
        percentValue(any) ?? 0
    }

    /// nil when the field is absent, not a number (a JSON `true` included —
    /// it is not 1%), or not finite. Clamped while still a Double: `Int(_:)`
    /// traps on a value outside Int's range, and a hostile `1e300` must fold
    /// to 100, not crash the poll.
    private static func percentValue(_ any: Any?) -> Int? {
        guard let v = JSONNumber.finite(any) else { return nil }
        return Int(max(0, min(100, v.rounded())))
    }

    private static func prettyModelName(_ raw: String) -> String {
        let r = raw.lowercased()
        if r.contains("opus") { return "Opus" }
        if r.contains("fable") { return "Fable 5" }
        if r.contains("sonnet") { return "Sonnet" }
        if r.contains("haiku") { return "Haiku" }
        return raw.capitalized
    }
}
