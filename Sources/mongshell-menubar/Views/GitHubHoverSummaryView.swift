import SwiftUI

/// The instant hover summary of the GitHub region (mockup § B2): rows in the
/// same three-column grid, type sizes and padding as `HoverSummaryView`,
/// so crossing from one region to the other reads as one app. Reads the
/// glance the model already computed — hover never triggers a refresh.
struct GitHubHoverSummaryView: View {
    @ObservedObject var model: GitHubModel

    var body: some View {
        Group {
            if let lines = model.glance.lines {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 6, verticalSpacing: 5) {
                    // Mine: red only when one of them is blocked.
                    row(label: "내 PR", number: lines.mine,
                        numberColor: lines.blocked > 0 ? Palette.red : nil,
                        rest: lines.mineRest)
                }
            } else {
                // No snapshot speaks for the region (no token, refused, first
                // load…): the state in one line, never an empty pair of rows.
                Text(model.glance.stateLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .fixedSize()
    }

    /// One row: label · right-aligned count · the rest. The count is the
    /// only colored cell; nil keeps it in the label color.
    private func row(label: String, number: Int, numberColor: Color?, rest: String) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text("\(number)")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(numberColor ?? Color.primary)
                .gridColumnAlignment(.trailing)
            // Always emit the third cell so every row keeps the same column
            // count and stays aligned.
            Text(rest.isEmpty ? "" : "· \(rest)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .gridColumnAlignment(.leading)
        }
    }
}
