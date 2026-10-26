import Foundation

/// ISO 8601 timestamps as the three response parsers meet them — with or
/// without fractional seconds. One copy for `UsageAPIClient`,
/// `OpenClawStatusClient` and `GitHubAPIClient` (#107).
enum ResponseDate {
    /// nil for anything that is not such a string. Formatters are built per
    /// call: parsing runs once per field per poll, and a shared instance is
    /// not `Sendable` under Swift 6.
    static func parse(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFrac.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
