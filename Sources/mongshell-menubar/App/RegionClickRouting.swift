import CoreGraphics

/// Which region of the status item a mouse click belongs to, kept out of
/// `AppDelegate` so the rule compiles into `scripts/test.sh` without AppKit.
///
/// The click is split by one boundary — the GitHub region's leading edge —
/// rather than by "is the cursor inside the GitHub region's rect" (#58). The
/// system hands the button clicks from outside that rect: the full menu-bar
/// height (30pt here, taller on notched Macs) against the 22pt button, and the
/// padding beside the item. With a containment test every such click fell
/// through to `.claude`, so the GitHub region's edges opened the Claude
/// popover. Hover still uses the rect (`AppDelegate.isCursorOver`).
enum RegionClickRouting {
    /// - Parameters:
    ///   - cursorX: the cursor's x on screen at the click.
    ///   - githubMinX: the GitHub region's leading edge on screen, or nil when
    ///     the region has no frame to measure.
    ///   - githubWidth: the GitHub region's width; zero while it is switched off.
    static func clickGoesToGitHub(cursorX: CGFloat, githubMinX: CGFloat?, githubWidth: CGFloat) -> Bool {
        guard let githubMinX, githubWidth > 0 else { return false }
        return cursorX >= githubMinX
    }
}
