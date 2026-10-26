import SwiftUI

/// The status-bar content: Claude mark + two compact ring gauges (`◔15% ◕96%`)
/// for the 5-hour and 7-day windows. Hosted inside the NSStatusItem button via
/// NSHostingView.
/// Reset times live in the popover, not the bar, to keep it short.
struct MenuBarIconView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var prefs: Preferences
    @ObservedObject var openClaw: OpenClawModel

    private var fiveHourUsed: Int { model.snapshot.fiveHourPercent }
    private var weeklyUsed: Int { model.snapshot.weeklyAllPercent }

    private var dots: OpenClawDots { OpenClawDots(prefs: prefs, openClaw: openClaw) }

    var body: some View {
        MenuBarContent(fiveHourUsed: fiveHourUsed, weeklyUsed: weeklyUsed,
                       showRemaining: prefs.showRemaining,
                       colorCoding: prefs.colorCoding,
                       showPercent: prefs.showPercent,
                       fiveHourReset: TimeText.clockShort(model.snapshot.fiveHourResetAt),
                       openClawDotColor: dots.openClaw,
                       serverHostDotColor: dots.serverHost)
    }
}

/// The bar's visual content, parameterized so the live menu bar and the
/// offscreen snapshot renderer share one layout.
struct MenuBarContent: View {
    let fiveHourUsed: Int
    let weeklyUsed: Int
    let showRemaining: Bool
    let colorCoding: Bool
    let showPercent: Bool
    /// 5-hour reset clock (e.g. "19:00") shown next to the 5h gauge — the 5h
    /// window's reset is easy to lose track of, so it earns the extra text.
    /// nil hides it.
    var fiveHourReset: String? = nil
    /// Non-nil = append the unified openclaw indicator (paw + traffic-light dot)
    /// in this color. nil = hide it entirely.
    var openClawDotColor: Color? = nil
    /// Non-nil = stack the server host indicator (server glyph + dot) under
    /// the openclaw one, in this color. Both come from the same status
    /// document, so it's only drawn next to the openclaw indicator. Like that
    /// dot it ignores `colorCoding`: the color is the information.
    var serverHostDotColor: Color? = nil

    var body: some View {
        HStack(spacing: 6) {
            ClaudeMarkView()
                .frame(width: 16, height: 16)

            if showPercent {
                // Position conveys the window: left = 5h, right = 7d.
                // 5h shows its reset clock (easy to forget); 7d is gauge-only
                // (its weekly reset is easy to remember).
                fiveHourGauge
                ring(weeklyUsed)
            }

            if let openClawDotColor {
                if let serverHostDotColor {
                    stackedIndicators(openClaw: openClawDotColor, serverHost: serverHostDotColor,
                                      separated: showPercent)
                } else {
                    openClawIndicator(color: openClawDotColor, separated: showPercent)
                }
            }
        }
        .padding(.horizontal, 2)
        .fixedSize()
    }

    /// 5h: ring gauge + its reset clock.
    private var fiveHourGauge: some View {
        HStack(spacing: 4) {
            ring(fiveHourUsed)
            if let fiveHourReset {
                Text(fiveHourReset)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A tiny ring gauge for one window (no number). Fill follows the display
    /// mode (consumed vs remaining); color always tracks risk (consumed).
    private func ring(_ used: Int) -> some View {
        let display = Meter(usedPercent: used, showRemaining: showRemaining, colorCoding: colorCoding).displayPercent
        let color = colorCoding ? Palette.statusColor(for: used, colorCoding: true) : Color.primary
        return MenuRing(percent: display, color: color)
            .frame(width: 13, height: 13)
    }

    /// openclaw "아이콘 + 신호등": a paw glyph followed by the health-colored dot,
    /// sitting to the right of the usage gauges in the same status item.
    private func openClawIndicator(color: Color, separated: Bool) -> some View {
        HStack(spacing: 4) {
            if separated {
                Text("·")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "pawprint.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        }
    }

    /// openclaw over server host: one glyph + dot row each, in the place of
    /// the single openclaw indicator.
    private func stackedIndicators(openClaw: Color, serverHost: Color,
                                   separated: Bool) -> some View {
        HStack(spacing: 4) {
            if separated {
                Text("·")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: StackedIndicator.rowSpacing) {
                stackedRow(glyph: "pawprint.fill", color: openClaw)
                stackedRow(glyph: "server.rack", color: serverHost)
            }
        }
    }

    private func stackedRow(glyph: String, color: Color) -> some View {
        HStack(spacing: StackedIndicator.glyphDotSpacing) {
            Image(systemName: glyph)
                .font(.system(size: StackedIndicator.glyphSize, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: StackedIndicator.glyphColumnWidth)
            Circle()
                .fill(color)
                .frame(width: StackedIndicator.dotSize, height: StackedIndicator.dotSize)
        }
        .frame(height: StackedIndicator.rowHeight)
    }
}

/// Sizes of the two stacked indicators. Two rows and the gap between them
/// (9 + 1 + 9 = 19pt) have to fit the 22pt menu bar, and the stack must not be
/// wider than the single indicator it replaces (PHILOSOPHY § Admission
/// Criteria 4).
private enum StackedIndicator {
    static let rowSpacing: CGFloat = 1
    static let rowHeight: CGFloat = 9
    static let glyphSize: CGFloat = 8
    /// Fixed, so the two dots line up whatever the glyphs' own widths.
    static let glyphColumnWidth: CGFloat = 11
    static let glyphDotSpacing: CGFloat = 3
    static let dotSize: CGFloat = 6
}

/// A minimal ring gauge sized for the menu bar (top-start, clockwise fill).
private struct MenuRing: View {
    let percent: Int
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.30), lineWidth: 2.2)
            Circle()
                .trim(from: 0, to: max(0, min(1, CGFloat(percent) / 100)))
                .stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// The menu bar's openclaw and server dots — one rule for the bar and the
/// settings preview (#107). Each is nil when it shouldn't show: nothing at all
/// unless `Preferences.showsOpenClaw` (the app then looks exactly like the
/// plain build), and no server dot when the server sends no host signals.
@MainActor
struct OpenClawDots {
    let openClaw: Color?
    /// Stacked under the openclaw one.
    let serverHost: Color?

    init(prefs: Preferences, openClaw model: OpenClawModel) {
        openClaw = prefs.showsOpenClaw ? model.health.dotColor : nil
        serverHost = prefs.showsOpenClaw ? model.hostHealth.dotColor : nil
    }
}
