import Foundation

/// One rule for text that arrives from outside (the openclaw status document,
/// the usage response, the GitHub response) and ends up on screen or in the
/// debug log: control characters and line breaks become spaces, then it is
/// cut to a caller-chosen character limit and a fixed scalar limit. Shared by
/// `OpenClawStatusClient`, `UsageAPIClient` and `GitHubAPIClient`, which apply
/// it at their parsing boundary — views and the log receive bounded,
/// single-line strings.
enum DisplayText {
    /// Scalars kept per displayed text, on top of the character limit: one
    /// character can stack any number of combining marks ("Zalgo" text), so a
    /// character count alone doesn't bound what gets drawn.
    static let scalarLimit = 480

    /// Replaced by a space: control characters plus every line break —
    /// U+2028/U+2029 aren't control characters but still break the line.
    private static let lineBreaking = CharacterSet.controlCharacters.union(.newlines)

    /// A bounded single line of `raw`: control characters and line breaks
    /// become spaces, then it's cut to `limit` characters and at most
    /// `scalarLimit` scalars.
    static func flatten(_ raw: String, limit: Int) -> String {
        let flattened = String(String.UnicodeScalarView(raw.unicodeScalars.map {
            lineBreaking.contains($0) ? " " : $0
        }))
        var kept = ""
        var scalarCount = 0
        for character in flattened.trimmingCharacters(in: .whitespaces).prefix(limit) {
            scalarCount += character.unicodeScalars.count
            if scalarCount > scalarLimit { break }
            kept.append(character)
        }
        return kept
    }
}
