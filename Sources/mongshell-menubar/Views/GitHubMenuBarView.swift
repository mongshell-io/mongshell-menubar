import SwiftUI

/// The opt-in second region of the status item (Decision #45): a vertical
/// hairline, the pull-request glyph (the green merge arrow while one of my
/// PRs can be merged, Decision #52), the traffic-light dot and — when there
/// is something to act on — the count. Hosted in its own
/// `PassthroughHostingView` to the right of `MenuBarIconView`; the hairline
/// is part of this content, so switching the region off removes it too.
struct GitHubMenuBarView: View {
    @ObservedObject var model: GitHubModel
    @ObservedObject var prefs: Preferences

    var body: some View {
        if prefs.showsGitHub {
            GitHubMenuBarContent(count: model.glance.count, dot: model.glance.dot.color,
                                 mergeReady: model.glance.hasMergeable)
        } else {
            // Explicit zero frame: a bare EmptyView makes the hosting view
            // report SwiftUI's 10×10 default size, which would widen the
            // status item (and give the region a hover rect) while off.
            EmptyView().frame(width: 0, height: 0)
        }
    }
}

/// The region's visual content, parameterized so the live menu bar and the
/// offscreen snapshot renderer share one layout (mockup § A).
struct GitHubMenuBarContent: View {
    let count: Int
    /// The glance dot's color. Like the openclaw dot it ignores
    /// `colorCoding`: the color is the information.
    let dot: Color
    /// One of my PRs can be merged from the popover now (Decision #52).
    /// Like the dot it ignores `colorCoding`.
    let mergeReady: Bool

    var body: some View {
        HStack(spacing: 0) {
            // The boundary between the two regions. `.secondary` so it follows
            // the status bar's light/dark appearance like the glyph does.
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 1, height: 12)
                .padding(.horizontal, 6)
            HStack(spacing: 4) {
                glyph
                Circle()
                    .fill(dot)
                    .frame(width: 7, height: 7)
                // No "0": nothing to do is said by the green dot alone.
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 2)
        }
        .fixedSize()
    }

    /// The pull glyph's own width at 10pt medium — the region as shipped
    /// in #45. The merge glyph is about two thirds of a point wider and
    /// overhangs this slot into the spacing around it rather than widening
    /// the status item, so a merge becoming possible moves nothing.
    private static let glyphSlotWidth: CGFloat = 8

    /// A yes/no in the glyph rather than a second number: the region holds
    /// one glyph, one dot and one number (Decision #52).
    private var glyph: some View {
        Image(systemName: mergeReady ? "arrow.triangle.merge" : "arrow.triangle.pull")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(mergeReady ? AnyShapeStyle(Palette.green) : AnyShapeStyle(.secondary))
            .frame(width: Self.glyphSlotWidth)
            .accessibilityLabel(mergeReady ? "머지 가능한 PR 있음" : "머지 가능한 PR 없음")
    }
}
