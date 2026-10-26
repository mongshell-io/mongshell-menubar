import SwiftUI

/// The instant hover summary shown when the cursor enters the menu-bar icon.
/// Two compact lines (5-hour / 7-day) mirroring the popover's numbers, display
/// mode, and reset wording so it reads consistently with the rest of the app.
/// Deliberately tiny — reset text only, no gauges — since it's a glance aid.
struct HoverSummaryView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var prefs: Preferences

    private var snap: UsageSnapshot { model.snapshot }
    private var modeLabel: String { prefs.showRemaining ? "남은 양" : "사용량" }

    var body: some View {
        // Grid so the three columns (label · percent · reset) line up across
        // both rows — label and percent widths differ per row, which left an
        // HStack ragged.
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 6, verticalSpacing: 5) {
            row(window: "5시간", used: snap.fiveHourPercent, reset: snap.fiveHourResetText)
            row(window: "7일", used: snap.weeklyAllPercent, reset: snap.weeklyResetText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .fixedSize()
    }

    /// One row: label · right-aligned percent · reset. Display number follows
    /// the consumed/remaining mode via `Meter`, the single source of truth
    /// shared with the gauges/popover; color-free text keeps this minimal.
    /// `used` nil = the response did not let us read it: a grey dash, not 0%.
    private func row(window: String, used: Int?, reset: String) -> some View {
        let display = used.map {
            Meter(usedPercent: $0, showRemaining: prefs.showRemaining,
                  colorCoding: prefs.colorCoding).displayPercent
        }
        return GridRow {
            Text("\(window) \(modeLabel)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(display.map { "\($0)%" } ?? "—")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(display == nil ? HierarchicalShapeStyle.tertiary : .primary)
                .gridColumnAlignment(.trailing)
            // Always emit the third cell (empty when no reset) so both rows
            // keep the same column count and stay aligned.
            Text(reset.isEmpty ? "" : "· \(reset)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .gridColumnAlignment(.leading)
        }
    }
}
