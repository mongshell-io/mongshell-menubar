import SwiftUI

/// The instant hover summary of the GitHub region (layout only: mockup
/// § B2 — the rows' content is architecture.md § 4): two rows in
/// the same three-column grid, type sizes and padding as `HoverSummaryView`,
/// so crossing from one region to the other reads as one app. Reads the
/// glance the model already computed — hover never triggers a refresh. The
/// one moving part is the CI row's elapsed time, which `TimelineView`
/// advances once a second as the popover's running chip does;
/// `GitHubModel.frozenNow` pins it for the snapshot renderer.
struct GitHubHoverSummaryView: View {
    @ObservedObject var model: GitHubModel

    var body: some View {
        Group {
            if let lines = model.glance.lines {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 6, verticalSpacing: 5) {
                    // My PRs' checks: amber while they run, red once failed.
                    GridRow {
                        labelCell("CI")
                        numberCell(lines.ci.number, color: lines.ci.tone?.color)
                        ciRest(lines.ci)
                    }
                    // Mine: red only when one of them is blocked.
                    GridRow {
                        labelCell("내 PR")
                        numberCell(lines.mine, color: lines.blocked > 0 ? Palette.red : nil)
                        restCell(lines.mineRest, separated: true)
                    }
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

    /// 59m 59s — with monospaced digits, the widest the elapsed time reads
    /// under an hour; "1h 00m"–"9h 59m" are narrower. From "10h 00m" the
    /// text is as many characters again and may run under a point wider.
    private static let widestElapsed: TimeInterval = 59 * 60 + 59

    /// Only a running check with a start time pays for the timeline. The
    /// snapshot clock, when set, wins over the timeline's so reference
    /// images don't tick. A hidden copy at the widest elapsed time holds the
    /// cell's width, so the hover doesn't jump when "59s" becomes "1m 00s".
    @ViewBuilder private func ciRest(_ ci: GitHubCILine) -> some View {
        if let since = ci.runningSince {
            ZStack(alignment: .leading) {
                restCell(ci.rest(now: since.addingTimeInterval(Self.widestElapsed)),
                         separated: ci.number != nil)
                    .hidden()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    restCell(ci.rest(now: model.frozenNow ?? context.date), separated: ci.number != nil)
                }
            }
            .gridColumnAlignment(.leading)
        } else {
            restCell(ci.rest(now: model.frozenNow ?? Date()), separated: ci.number != nil)
        }
    }

    private func labelCell(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.leading)
    }

    /// The right-aligned count, the only colored cell; nil color keeps it in
    /// the label color. Without a count the cell stays, empty, so the rows
    /// keep the same column count and stay aligned.
    private func numberCell(_ number: Int?, color: Color?) -> some View {
        Text(number.map { "\($0)" } ?? "")
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(color ?? Color.primary)
            .gridColumnAlignment(.trailing)
    }

    /// The rest, greyed. "· " ties it to a count; a row that says it in
    /// words ("모두 통과") has no count to tie to.
    private func restCell(_ rest: String, separated: Bool) -> some View {
        Text(rest.isEmpty ? "" : (separated ? "· \(rest)" : rest))
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .gridColumnAlignment(.leading)
    }
}
