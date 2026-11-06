import Foundation

/// Why the cost report couldn't be read. `detail` is the short grey line the
/// popover's API credit section shows; it never carries the key.
enum CostReportError: Error, Equatable, Sendable {
    /// 401/403 — the key is wrong, revoked, or not an Admin key.
    case unauthorized
    /// 429. `retryAfter` from the header when it gave one.
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case timedOut
    case offline
    /// Any other transport failure (DNS, TLS, refused, a refused redirect…).
    case network
    /// Not a report this client can vouch for: not JSON, too large, no rows
    /// it could read, or more pages than it follows.
    case badResponse
    /// Cancelled on our side (the loop was replaced). Not news about the API.
    case cancelled

    var detail: String {
        switch self {
        case .unauthorized: return "Admin 키를 확인하세요"
        case .rateLimited:  return "요청이 제한되었습니다 — 잠시 후 다시 시도합니다"
        case .offline:      return "네트워크 연결 없음"
        default:            return "불러오지 못했습니다"
        }
    }

    static func transport(_ code: URLError.Code) -> CostReportError {
        switch code {
        case .cancelled: return .cancelled
        case .timedOut:  return .timedOut
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return .offline
        default:         return .network
        }
    }
}

/// One page of the cost report, summed: USD spend in cents across every
/// bucket and row, and where the next page is.
struct CostReportPage: Equatable, Sendable {
    let spentCents: Decimal
    let hasMore: Bool
    let nextPage: String?
}

/// Reads the Admin API cost report (Decision #162) and sums the spend in a
/// time range. Pure fetch + parse, no state. The Admin key goes only to
/// `Config.costReportURL`'s host, through `BoundedHTTP` — no redirect is
/// followed, so a 3xx can't carry the key elsewhere.
struct CostReportClient: Sendable {
    /// The report answers in about a second; past this the next poll tries.
    static let requestTimeout: TimeInterval = 30

    private static let session = BoundedHTTP.makeSession(timeout: requestTimeout)

    /// USD spent in `range`, in cents, following `next_page` up to
    /// `Config.costReportMaxPages`.
    func fetchSpentCents(adminKey: String, range: DateInterval) async throws(CostReportError) -> Decimal {
        try await Self.sumPages(maxPages: Config.costReportMaxPages) { page throws(CostReportError) in
            try await fetchPage(adminKey: adminKey, range: range, page: page)
        }
    }

    /// Sums the pages `fetch` hands back, following `next_page` from the
    /// first (nil cursor) for at most `maxPages`. Split from the transport so
    /// the paging rules are testable. Every way of stopping short is an
    /// error, never the partial total: a total that misses pages undercounts
    /// the spend and overstates what is left.
    static func sumPages(maxPages: Int,
                         fetch: (String?) async throws(CostReportError) -> CostReportPage)
        async throws(CostReportError) -> Decimal {
        var total = Decimal(0)
        var page: String?
        for _ in 0..<maxPages {
            let result = try await fetch(page)
            total += result.spentCents
            guard result.hasMore else { return total }
            // `has_more` with no cursor can't be followed.
            guard let next = result.nextPage else { throw .badResponse }
            page = next
        }
        throw .badResponse
    }

    private func fetchPage(adminKey: String, range: DateInterval,
                           page: String?) async throws(CostReportError) -> CostReportPage {
        let req = Self.request(adminKey: adminKey, range: range, page: page)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await BoundedHTTP.download(
                req, session: Self.session, maxBytes: Config.costReportMaxResponseBytes,
                readsBody: Self.readsBody(statusCode:))
        } catch is BoundedHTTP.ResponseTooLarge {
            throw .badResponse
        } catch let error as URLError {
            throw .transport(error.code)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .network
        }
        guard let http = response as? HTTPURLResponse else { throw .badResponse }
        return try Self.interpret(statusCode: http.statusCode,
                                  retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                                  data: data)
    }

    // MARK: Request

    static func request(adminKey: String, range: DateInterval, page: String?) -> URLRequest {
        var components = URLComponents(url: Config.costReportURL, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "starting_at", value: rfc3339(range.start)),
            URLQueryItem(name: "ending_at", value: rfc3339(range.end)),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: String(Config.costReportBucketLimit)),
        ]
        if let page { items.append(URLQueryItem(name: "page", value: page)) }
        // Encoded by hand: `queryItems` leaves `+` as is, which the server
        // reads as a space — an opaque page cursor holding one would break.
        components.percentEncodedQueryItems = items.map {
            URLQueryItem(name: $0.name,
                         value: $0.value?.addingPercentEncoding(withAllowedCharacters: queryValueAllowed))
        }
        var req = URLRequest(url: components.url!)
        req.httpMethod = "GET"
        req.setValue(adminKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Config.anthropicAPIVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue(Config.costReportUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    /// The range asked for a cycle that began at `cycleStart`, as of `now`.
    ///
    /// Buckets snap to UTC day starts, so the start is floored to the UTC day
    /// holding `cycleStart`: the part of that day before the local cycle
    /// start is counted as spent, which can only understate what is left —
    /// the other way (the next UTC midnight) would drop the cycle's first
    /// hours. `starting_at` is inclusive and a bucket is returned when it
    /// ends by `ending_at`, so the end is the next UTC midnight after `now`:
    /// today's bucket ends there and so is included, partial as it is.
    static func queryRange(cycleStart: Date, now: Date) -> DateInterval {
        let start = utcCalendar.startOfDay(for: cycleStart)
        let today = utcCalendar.startOfDay(for: now)
        let end = utcCalendar.date(byAdding: .day, value: 1, to: today)!
        return DateInterval(start: start, end: max(start, end))
    }

    /// What may stand bare in a query value: `urlQueryAllowed` less the
    /// characters that delimit or mean something inside a query.
    private static let queryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=;")
        return allowed
    }()

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func rfc3339(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: date)
    }

    // MARK: Response

    /// Only a 200 carries a report; every other code is judged on the code
    /// (and `Retry-After`) alone.
    static func readsBody(statusCode: Int) -> Bool {
        statusCode == okStatusCode
    }

    private static let okStatusCode = 200

    static func interpret(statusCode: Int, retryAfter: String?, data: Data) throws(CostReportError) -> CostReportPage {
        switch statusCode {
        case okStatusCode: return try parse(data)
        case 401, 403:     throw .unauthorized
        case 429:          throw .rateLimited(retryAfter: retryAfter.flatMap(TimeInterval.init))
        default:           throw .http(statusCode)
        }
    }

    /// One page:
    /// ```
    /// { "data": [ { "starting_at", "ending_at",
    ///               "results": [ { "amount": "123.78912", "currency": "USD", … } ] } ],
    ///   "has_more": false, "next_page": null }
    /// ```
    /// `amount` is a decimal string in cents. Tolerant: a row whose amount or
    /// currency can't be read is skipped, and a row in another currency is
    /// read but not added. But if the page had buckets and not one carried a
    /// `results` array, or had rows and not one could be read, the shape has
    /// changed under us — that is an error, not $0 spent, which would show
    /// the whole credit as left. A negative amount (a refund or adjustment)
    /// is read as 0: subtracting it would overstate what is left.
    static func parse(_ data: Data) throws(CostReportError) -> CostReportPage {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let buckets = root["data"] as? [Any]
        else { throw .badResponse }

        var total = Decimal(0)
        var readBuckets = 0
        var rows = 0
        var readRows = 0
        for case let bucket as [String: Any] in buckets {
            guard let results = bucket["results"] as? [Any] else { continue }
            readBuckets += 1
            for result in results {
                rows += 1
                guard let row = result as? [String: Any],
                      let currency = row["currency"] as? String,
                      let amount = cents(row["amount"])
                else { continue }
                readRows += 1
                if currency.uppercased() == "USD" { total += max(0, amount) }
            }
        }
        if !buckets.isEmpty && readBuckets == 0 { throw .badResponse }
        if rows > 0 && readRows == 0 { throw .badResponse }

        // A JSON bool only — JSONSerialization hands `1` back as an NSNumber too.
        let hasMore = (root["has_more"] as? NSNumber)
            .map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
        let nextPage = (root["next_page"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return CostReportPage(spentCents: total, hasMore: hasMore, nextPage: nextPage)
    }

    /// The amount as a decimal string (documented) or, leniently, a JSON
    /// number. A bool is not an amount.
    private static func cents(_ value: Any?) -> Decimal? {
        if let string = value as? String {
            // `Decimal(string:)` reads a leading number and ignores the rest
            // ("12abc" → 12), so the whole string must look like one.
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            guard trimmed.wholeMatch(of: #/-?[0-9]+(\.[0-9]+)?/#) != nil else { return nil }
            return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
        }
        if let number = JSONNumber.finite(value) {
            return Decimal(number)
        }
        return nil
    }
}
