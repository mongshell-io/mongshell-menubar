import Foundation

// Regression tests for the API credit estimate (Decision #162).
//
// Pinned here: the cost report's amounts are summed as cents across every
// bucket and row, other currencies and unreadable rows are skipped, and a
// page whose rows are all unreadable is an error rather than $0 spent; the
// status code maps onto the error the model branches on (401/403 → the key,
// 429 → back off with Retry-After); the query range starts at the UTC day
// holding the cycle start and ends at the next UTC midnight; the billing
// cycle clamps a renewal day past the month's end and turns over at local
// midnight of the renewal day; what is left never goes below zero, a spend
// read for another cycle is not shown, and the dollar text rounds down; the
// 429 backoff grows, is capped and honors Retry-After.
//
// Run with `./scripts/test.sh`, which compiles this against the real sources
// (the @MainActor model is left out, as for the other bundles).

var failures: [String] = []

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "  ok  " : " FAIL ") \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    if !ok { failures.append(label) }
}

func body(_ s: String) -> Data { Data(s.utf8) }

func parse(_ s: String) -> Result<CostReportPage, CostReportError> {
    do { return .success(try CostReportClient.parse(body(s))) } catch { return .failure(error) }
}

func interpret(_ status: Int, retryAfter: String? = nil, _ s: String = "") -> CostReportError? {
    do { _ = try CostReportClient.interpret(statusCode: status, retryAfter: retryAfter, data: body(s)); return nil }
    catch { return error }
}

// MARK: parsing

do {
    let page = parse("""
    {"data": [
      {"starting_at": "2026-11-01T00:00:00Z", "ending_at": "2026-11-02T00:00:00Z",
       "results": [{"amount": "123.45", "currency": "USD", "model": null},
                   {"amount": "0.55", "currency": "USD", "cost_type": "tokens"}]},
      {"starting_at": "2026-11-02T00:00:00Z", "ending_at": "2026-11-03T00:00:00Z",
       "results": [{"amount": "1000", "currency": "USD"}]}
    ], "has_more": false, "next_page": null}
    """)
    check("cents summed across buckets and rows",
          (try? page.get())?.spentCents == Decimal(string: "1124"), "\(page)")
    check("no more pages", (try? page.get())?.hasMore == false)
}

check("fractional cents kept",
      (try? parse(#"{"data":[{"results":[{"amount":"123.78912","currency":"USD"}]}],"has_more":false}"#).get())?
        .spentCents == Decimal(string: "123.78912"))

check("another currency is not added",
      (try? parse(#"{"data":[{"results":[{"amount":"500","currency":"USD"},{"amount":"900","currency":"EUR"}]}],"has_more":false}"#).get())?
        .spentCents == 500)

check("unreadable rows are skipped, readable ones kept",
      (try? parse(#"{"data":[{"results":[{"amount":"200","currency":"USD"},{"amount":"12abc","currency":"USD"},{"amount":true,"currency":"USD"},{"currency":"USD"},"x"]}],"has_more":false}"#).get())?
        .spentCents == 200)

check("rows that are all unreadable are an error, not $0",
      parse(#"{"data":[{"results":[{"amount":"n/a","currency":"USD"},{"amount":null}]}],"has_more":false}"#)
        == .failure(.badResponse))

check("no rows at all is $0 spent",
      (try? parse(#"{"data":[{"results":[]}],"has_more":false}"#).get())?.spentCents == 0)
check("an empty data array is $0 spent",
      (try? parse(#"{"data":[],"has_more":false,"next_page":null}"#).get())?.spentCents == 0)

check("buckets without a results array are an error, not $0",
      parse(#"{"data":[{"starting_at":"2026-11-01T00:00:00Z","rows":[{"amount":"500","currency":"USD"}]}],"has_more":false}"#)
        == .failure(.badResponse))
check("a bucket without results beside a readable one is skipped",
      (try? parse(#"{"data":[{"rows":[]},{"results":[{"amount":"7","currency":"USD"}]}],"has_more":false}"#).get())?
        .spentCents == 7)
check("a negative row (refund) adds nothing, never lowers the spend",
      (try? parse(#"{"data":[{"results":[{"amount":"300","currency":"USD"},{"amount":"-200.5","currency":"USD"}]}],"has_more":false}"#).get())?
        .spentCents == 300)
check("not JSON is an error", parse("<html>") == .failure(.badResponse))
check("no data array is an error", parse(#"{"error":{"type":"x"}}"#) == .failure(.badResponse))

do {
    let more = try? parse(#"{"data":[],"has_more":true,"next_page":"page_2"}"#).get()
    check("has_more and next_page are read", more?.hasMore == true && more?.nextPage == "page_2")
    let numeric = try? parse(#"{"data":[],"has_more":1,"next_page":"page_2"}"#).get()
    check("a number is not has_more", numeric?.hasMore == false)
}

// MARK: status codes

check("401 → check the key", interpret(401) == .unauthorized)
check("403 → check the key", interpret(403) == .unauthorized)
check("429 → back off with Retry-After", interpret(429, retryAfter: "120") == .rateLimited(retryAfter: 120))
check("500 → HTTP error", interpret(500) == .http(500))
check("a refused redirect → HTTP error", interpret(302) == .http(302))
check("only a 200 body is read",
      CostReportClient.readsBody(statusCode: 200) && !CostReportClient.readsBody(statusCode: 401))

// MARK: request

do {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let seoul = TimeZone(identifier: "Asia/Seoul")!
    var local = Calendar(identifier: .gregorian)
    local.timeZone = seoul
    // Local midnight Nov 15 in Seoul is Nov 14 15:00 UTC.
    let cycleStart = local.date(from: DateComponents(year: 2026, month: 11, day: 15))!
    let now = utc.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 7))!
    let range = CostReportClient.queryRange(cycleStart: cycleStart, now: now)
    check("range starts at the UTC day holding the cycle start",
          range.start == utc.date(from: DateComponents(year: 2026, month: 11, day: 14)), "\(range.start)")
    check("range ends at the next UTC midnight, so today's bucket is in",
          range.end == utc.date(from: DateComponents(year: 2026, month: 11, day: 21)), "\(range.end)")

    let req = CostReportClient.request(adminKey: "sk-ant-admin01-test", range: range, page: "p2")
    check("the key goes only to api.anthropic.com", req.url?.host == "api.anthropic.com")
    check("the key rides in x-api-key", req.value(forHTTPHeaderField: "x-api-key") == "sk-ant-admin01-test")
    check("anthropic-version is set", req.value(forHTTPHeaderField: "anthropic-version") == Config.anthropicAPIVersion)
    let query = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let items = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
    check("query carries the range, daily buckets and the page",
          items["starting_at"] == "2026-11-14T00:00:00Z" && items["ending_at"] == "2026-11-21T00:00:00Z"
          && items["bucket_width"] == "1d" && items["page"] == "p2", "\(items)")
}

// MARK: paging

func page(_ cents: Decimal, more: Bool = false, next: String? = nil) -> CostReportPage {
    CostReportPage(spentCents: cents, hasMore: more, nextPage: next)
}

func sum(maxPages: Int = 5, _ pages: [String?: CostReportPage]) async -> (Result<Decimal, CostReportError>, [String?]) {
    var asked: [String?] = []
    do {
        let total = try await CostReportClient.sumPages(maxPages: maxPages) { cursor throws(CostReportError) in
            asked.append(cursor)
            guard let found = pages[cursor] else { throw .badResponse }
            return found
        }
        return (.success(total), asked)
    } catch {
        return (.failure(error), asked)
    }
}

do {
    let (total, asked) = await sum([nil: page(100, more: true, next: "p2"), "p2": page(50)])
    check("pages are added up, following next_page", total == .success(150) && asked == [nil, "p2"], "\(total) \(asked)")
    let (noCursor, _) = await sum([nil: page(100, more: true, next: nil)])
    check("has_more without a cursor is an error, not the partial total", noCursor == .failure(.badResponse))
    let (capped, cappedAsked) = await sum(maxPages: 2, [nil: page(1, more: true, next: "a"),
                                                       "a": page(1, more: true, next: "b"),
                                                       "b": page(1)])
    check("past the page cap is an error, not the partial total",
          capped == .failure(.badResponse) && cappedAsked.count == 2, "\(capped)")
}

do {
    let range = DateInterval(start: Date(timeIntervalSince1970: 0), duration: 86_400)
    let req = CostReportClient.request(adminKey: "k", range: range, page: "a+b/c=d&e")
    let query = req.url?.query ?? ""
    check("a page cursor's + & = are percent-encoded", query.contains("page=a%2Bb/c%3Dd%26e"), query)
    let items = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    check("the cursor reads back as sent", items.first { $0.name == "page" }?.value == "a+b/c=d&e")
}

// MARK: key input

check("an Admin key is accepted", AdminKeyInput.problem("  sk-ant-admin01-AbC_d-9\n") == nil)
check("a regular API key is refused", AdminKeyInput.problem("sk-ant-api03-abc").map { !$0.isEmpty } == true)
check("a key with an inner newline is refused",
      AdminKeyInput.problem("sk-ant-admin01-ab\ncd").map { !$0.isEmpty } == true)
check("a key with a space is refused", AdminKeyInput.problem("sk-ant-admin01-ab cd").map { !$0.isEmpty } == true)
check("empty input has nothing to say yet", AdminKeyInput.problem("  ") == "")

// MARK: billing cycle

do {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Seoul")!
    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    func cycle(_ day: Int, _ now: Date) -> APICreditCycle {
        APICreditCycle.current(renewalDay: day, now: now, calendar: cal)
    }

    let mid = cycle(15, date(2026, 11, 20, 12))
    check("after the renewal day: this month's to next month's",
          mid.start == date(2026, 11, 15) && mid.nextRenewal == date(2026, 12, 15))
    let before = cycle(15, date(2026, 11, 14, 23, 59))
    check("before the renewal day: last month's to this month's",
          before.start == date(2026, 10, 15) && before.nextRenewal == date(2026, 11, 15))
    let onDay = cycle(15, date(2026, 11, 15))
    check("on the renewal day at midnight: a new cycle",
          onDay.start == date(2026, 11, 15) && onDay.nextRenewal == date(2026, 12, 15))

    let feb = cycle(31, date(2027, 2, 28, 9))
    check("day 31 in February renews on the 28th",
          feb.start == date(2027, 2, 28) && feb.nextRenewal == date(2027, 3, 31), "\(feb)")
    let febBefore = cycle(31, date(2027, 2, 27, 9))
    check("day 31 before February's last day: from January 31st",
          febBefore.start == date(2027, 1, 31) && febBefore.nextRenewal == date(2027, 2, 28))
    let april = cycle(31, date(2026, 4, 30, 9))
    check("day 31 in April renews on the 30th, then May 31st",
          april.start == date(2026, 4, 30) && april.nextRenewal == date(2026, 5, 31))
    let leap = cycle(30, date(2028, 3, 1))
    check("day 30 in a leap February: the 29th",
          leap.start == date(2028, 2, 29) && leap.nextRenewal == date(2028, 3, 30))
    let january = cycle(5, date(2027, 1, 3))
    check("across the year: December's to January's",
          january.start == date(2026, 12, 5) && january.nextRenewal == date(2027, 1, 5))
    check("a day out of range is clamped",
          cycle(0, date(2026, 11, 20)).start == date(2026, 11, 1)
          && cycle(45, date(2026, 11, 20)).start == date(2026, 10, 31))
}

// MARK: estimate

do {
    let cycleStart = Date(timeIntervalSince1970: 1_000_000)
    let estimate = APICreditEstimate.make(monthlyUSD: 200, spentCents: Decimal(string: "7655.12345"),
                                          spentCycleStart: cycleStart, currentCycleStart: cycleStart)
    check("remaining = credit − spend", estimate?.remainingCents == Decimal(string: "12344.87655"))
    check("dollar text rounds down", estimate.map { APICreditEstimate.dollarsText(cents: $0.remainingCents) } == "$123.44")
    check("bar fill is what is left", abs((estimate?.remainingFraction ?? 0) - 0.6172438275) < 0.000001)
    check("risk color reads the spend", estimate?.spentPercent == 39)

    let over = APICreditEstimate.make(monthlyUSD: 200, spentCents: 25_000,
                                      spentCycleStart: cycleStart, currentCycleStart: cycleStart)
    check("remaining never below zero", over?.remainingCents == 0 && over?.remainingFraction == 0)
    check("spent past the grant is full risk", over?.spentPercent == 100)

    check("a spend from another cycle is not shown",
          APICreditEstimate.make(monthlyUSD: 200, spentCents: 100, spentCycleStart: cycleStart,
                                 currentCycleStart: cycleStart.addingTimeInterval(86_400)) == nil)
    check("no spend read yet is no estimate",
          APICreditEstimate.make(monthlyUSD: 200, spentCents: nil, spentCycleStart: nil,
                                 currentCycleStart: cycleStart) == nil)
    check("small amounts keep two digits", APICreditEstimate.dollarsText(cents: 5) == "$0.05")
}

// MARK: backoff

do {
    let base = Config.apiCreditPollSeconds
    check("no 429: the base interval", APICreditPollPolicy.wait(consecutiveRateLimits: 0, retryAfter: nil) == base)
    let first = APICreditPollPolicy.wait(consecutiveRateLimits: 1, retryAfter: nil)
    let second = APICreditPollPolicy.wait(consecutiveRateLimits: 2, retryAfter: nil)
    check("a 429 backs off past the base, and grows", first > base && second > first, "\(first) \(second)")
    check("a shorter Retry-After does not cut the backoff",
          APICreditPollPolicy.wait(consecutiveRateLimits: 1, retryAfter: 60) == first && first == base * 2,
          "\(first)")
    check("the backoff is capped",
          APICreditPollPolicy.wait(consecutiveRateLimits: 40, retryAfter: nil) == Config.apiCreditMaxBackoffSeconds)
    check("a longer Retry-After wins, capped",
          APICreditPollPolicy.wait(consecutiveRateLimits: 1, retryAfter: 3000) == 3000
          && APICreditPollPolicy.wait(consecutiveRateLimits: 1, retryAfter: 1e9) == Config.apiCreditMaxBackoffSeconds)
}

// MARK: result

if failures.isEmpty {
    print("\nAPI credit tests: all passed")
    exit(0)
} else {
    print("\nAPI credit tests: \(failures.count) failed")
    failures.forEach { print("  - \($0)") }
    exit(1)
}
