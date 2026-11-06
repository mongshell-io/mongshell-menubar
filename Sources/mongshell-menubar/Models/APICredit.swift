import Foundation

/// The billing cycle of the monthly API credit (Decision #162). The API
/// doesn't say when a cycle starts, so the user gives a day of the month;
/// a month shorter than that day renews on its last day.
struct APICreditCycle: Equatable {
    /// Local midnight of the most recent renewal day at or before `now`.
    let start: Date
    /// Local midnight of the renewal after that.
    let nextRenewal: Date

    static let renewalDays = 1...31

    static func current(renewalDay: Int, now: Date, calendar: Calendar = .current) -> APICreditCycle {
        let day = min(max(renewalDay, renewalDays.lowerBound), renewalDays.upperBound)
        let thisMonth = calendar.dateComponents([.year, .month], from: now)
        let renewalThisMonth = renewal(day: day, year: thisMonth.year!, month: thisMonth.month!,
                                       calendar: calendar)
        if renewalThisMonth <= now {
            return APICreditCycle(start: renewalThisMonth,
                                  nextRenewal: renewal(day: day, monthsAfter: 1, from: now, calendar: calendar))
        }
        return APICreditCycle(start: renewal(day: day, monthsAfter: -1, from: now, calendar: calendar),
                              nextRenewal: renewalThisMonth)
    }

    private static func renewal(day: Int, monthsAfter offset: Int, from now: Date,
                                calendar: Calendar) -> Date {
        let firstOfThisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let shifted = calendar.date(byAdding: .month, value: offset, to: firstOfThisMonth)!
        let parts = calendar.dateComponents([.year, .month], from: shifted)
        return renewal(day: day, year: parts.year!, month: parts.month!, calendar: calendar)
    }

    /// `day` of the month, clamped to the month's last day, at local midnight.
    private static func renewal(day: Int, year: Int, month: Int, calendar: Calendar) -> Date {
        let first = calendar.date(from: DateComponents(year: year, month: month, day: 1))!
        let length = calendar.range(of: .day, in: .month, for: first)!.count
        return calendar.date(from: DateComponents(year: year, month: month, day: min(day, length)))!
    }
}

/// What the popover's API credit section shows: the credit left, estimated
/// as the monthly credit minus the cycle's spend. Granted credit is spent
/// before purchased credit, so the spend comes out of the grant first.
struct APICreditEstimate: Equatable {
    let monthlyCents: Decimal
    let spentCents: Decimal

    /// The estimate, or nil when the spend read belongs to another cycle —
    /// one that has rolled over, or a renewal day changed since — rather
    /// than showing last cycle's spend against this cycle's credit.
    static func make(monthlyUSD: Int, spentCents: Decimal?, spentCycleStart: Date?,
                     currentCycleStart: Date) -> APICreditEstimate? {
        guard let spentCents, spentCycleStart == currentCycleStart else { return nil }
        return APICreditEstimate(monthlyCents: Decimal(max(0, monthlyUSD) * centsPerDollar),
                                 spentCents: spentCents)
    }

    /// Never below zero: spend past the grant comes from purchased credit.
    var remainingCents: Decimal {
        max(0, monthlyCents - spentCents)
    }

    /// The bar's fill, 0…1.
    var remainingFraction: Double {
        guard monthlyCents > 0 else { return 0 }
        let fraction = NSDecimalNumber(decimal: remainingCents / monthlyCents).doubleValue
        return min(1, max(0, fraction))
    }

    /// Percent of the grant spent, 0…100 — the risk the three-step color
    /// reads, like a usage gauge's used percent.
    var spentPercent: Int {
        guard monthlyCents > 0 else { return 100 }
        let percent = NSDecimalNumber(decimal: spentCents * 100 / monthlyCents).doubleValue
        return Int(min(100, max(0, percent.rounded(.up))))
    }

    /// Percent of the grant left, 0…100 — the menu bar ring's fill (#165).
    /// Rounded down, like the dollars, so what is left is never overstated.
    var remainingPercent: Int {
        Int((remainingFraction * 100).rounded(.down))
    }

    /// "$123.45" — whole cents, rounded down so what is left is never
    /// overstated.
    static func dollarsText(cents: Decimal) -> String {
        var exact = cents
        var whole = Decimal()
        NSDecimalRound(&whole, &exact, 0, .down)
        let total = NSDecimalNumber(decimal: whole).intValue
        let dollars = total / centsPerDollar
        let rest = total % centsPerDollar
        return "$\(dollars).\(rest < 10 ? "0" : "")\(rest)"
    }

    /// "$200" — the monthly credit, a whole number of dollars.
    static func wholeDollarsText(_ usd: Int) -> String {
        "$\(usd)"
    }

    static let centsPerDollar = 100
}

/// The menu bar's credit ring (#165), or nil when it isn't drawn: only once
/// the user has turned it on and a key is stored. With no estimate to show —
/// before the first read, or a read for another cycle — it is the unknown ring.
enum APICreditRing: Equatable {
    case unknown
    /// Fill is what is left; the three-step color reads what is spent.
    case estimate(remainingPercent: Int, spentPercent: Int)

    static func make(enabled: Bool, keySaved: Bool, estimate: APICreditEstimate?) -> APICreditRing? {
        guard enabled, keySaved else { return nil }
        guard let estimate else { return .unknown }
        return .estimate(remainingPercent: estimate.remainingPercent,
                         spentPercent: estimate.spentPercent)
    }
}

/// Whether a typed-in Admin key can be saved (Decision #162).
enum AdminKeyInput {
    /// Why it would be refused, or nil when it can be saved. Empty input is
    /// refused with an empty reason — there is nothing to say yet.
    ///
    /// Token characters only: a key carrying a newline or other control
    /// character makes `URLRequest` drop the `x-api-key` header without a
    /// word, and the result would read as a rejected key.
    static func problem(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return "" }
        guard key.hasPrefix(Config.adminKeyPrefix) else {
            return "Admin 키(\(Config.adminKeyPrefix)…)만 사용할 수 있습니다"
        }
        guard key.wholeMatch(of: #/[A-Za-z0-9_\-]+/#) != nil else {
            return "키에 쓸 수 없는 문자가 들어 있습니다"
        }
        return nil
    }
}

/// How long the credit poll waits (Decision #162). A 429 backs off
/// exponentially from the base interval, capped, and never sooner than the
/// server's `Retry-After` (capped the same).
enum APICreditPollPolicy {
    static func wait(consecutiveRateLimits: Int, retryAfter: TimeInterval?) -> Int {
        let base = Config.apiCreditPollSeconds
        let cap = Config.apiCreditMaxBackoffSeconds
        guard consecutiveRateLimits > 0 else { return base }
        let doublings = min(consecutiveRateLimits, maxDoublings)
        let backoff = min(cap, base << doublings)
        let asked = retryAfter.map { min(Double(cap), max(0, $0)).rounded(.up) }.map(Int.init) ?? 0
        return max(backoff, asked)
    }

    /// Enough to pass any cap a minute or more; keeps the shift small.
    private static let maxDoublings = 16
}
