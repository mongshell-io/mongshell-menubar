import Foundation

/// One rule for numbers read out of a JSONSerialization tree (the GitHub
/// response, the openclaw status document, the usage response, the OAuth
/// token response, Claude Code's credentials): a figure is a finite JSON number,
/// never a JSON `true` / `false`. JSONSerialization hands a bool back as an
/// NSNumber worth 1 or 0, so `as? Double` / `as? Int` would read `true` as 1 —
/// each caller once kept its own copy of this check, and the copies drifted.
enum JSONNumber {
    /// A finite JSON number; nil for a bool, a non-number, NaN or ±infinity.
    static func finite(_ any: Any?) -> Double? {
        guard let number = any as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    /// A non-negative count, fraction dropped. Bounded below `Int32.max` so
    /// `Int(_:)` can't trap and arithmetic on it downstream can't overflow.
    static func count(_ any: Any?) -> Int? {
        guard let value = finite(any), value >= 0, value < countCeiling else { return nil }
        return Int(value)
    }

    static let countCeiling = Double(Int32.max)

    /// An exact integer of either sign — what `as? Int` used to accept, minus
    /// the bools. nil for a fraction or a value `Int` can't hold.
    static func integer(_ any: Any?) -> Int? {
        finite(any).flatMap { Int(exactly: $0) }
    }
}
