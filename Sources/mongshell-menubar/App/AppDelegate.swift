import SwiftUI
import AppKit
import Combine

/// An NSHostingView that lets mouse events fall through to the status-item
/// button underneath (so the button's click action still fires while the
/// SwiftUI icon is drawn over it), while tracking cursor
/// enter/exit over the icon to drive the instant hover summary.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    /// Called after the SwiftUI content's size may have changed — at most
    /// once per run-loop turn, however many invalidations it coalesces.
    var onIntrinsicSizeChange: (() -> Void)?
    private var hoverTracking: NSTrackingArea?
    private var sizeChangePending = false
    /// The width last reported through `onIntrinsicSizeChange`.
    private var reportedWidth: CGFloat?

    /// NSHostingView invalidates its intrinsic size whenever what SwiftUI
    /// draws changes size, whichever model or preference caused it — so the
    /// status item follows the content without a list of inputs (#116). An
    /// invalidation does not mean the size changed — an animation, for one,
    /// invalidates on every frame (#120 measured it) — so only an actual
    /// width change is reported.
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        guard !sizeChangePending else { return }
        sizeChangePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            sizeChangePending = false
            let width = fittingSize.width
            guard width != reportedWidth else { return }
            reportedWidth = width
            onIntrinsicSizeChange?()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        // .inVisibleRect keeps the area glued to the (dynamically resized) icon
        // bounds with no manual recompute. hitTest returning nil above doesn't
        // affect tracking-area enter/exit delivery to this owner.
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { onMouseEntered?() }
    override func mouseExited(with event: NSEvent) { onMouseExited?() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The one status item (Decision #5) is split into side-by-side regions,
    /// laid out left to right in this order. Each region has its own host
    /// view in the button and, when registered, its own hover summary and
    /// click popover, so hover and click are judged per region. `.github` is
    /// the opt-in second region (Decision #45) and has zero width while off.
    enum Region: CaseIterable {
        case claude
        case github
    }

    private var statusItem: NSStatusItem!
    /// The host views are `PassthroughHostingView` of differing root views,
    /// so they are kept as plain `NSView`.
    private var hosts: [Region: NSView] = [:]
    private var clickPopovers: [Region: NSPopover] = [:]
    private var hoverPopovers: [Region: NSPopover] = [:]
    /// Invisible, click-through window laid exactly over the hovered region
    /// while its summary is up; the summary is anchored to it rather than to
    /// the button. With the summary anchored to the button, the item's
    /// background changed on hover as if it were selected — the anchoring is
    /// the suspected cause (the system draws that highlight, so no API shows
    /// it). The click popovers stay anchored to the button. One window serves
    /// every region: at most one summary is up at a time.
    private var hoverAnchor: NSWindow?
    /// The region whose summary currently owns `hoverAnchor` and
    /// `hoverWatchdog`; nil while no summary is up.
    private var hoverRegion: Region?
    /// Closes the hover summary if the cursor is no longer over its region —
    /// see `showHoverSummary`. Set while a summary is shown; if something
    /// other than `hideHoverSummary` closes the summary, it clears itself on
    /// its next tick.
    private var hoverWatchdog: Timer?
    /// How often the watchdog looks. A missed mouseExited is rare, so this only
    /// bounds how long a stray summary can stay up.
    private static let hoverWatchdogInterval: TimeInterval = 0.5
    private static let minimumStatusItemWidth: CGFloat = 24
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    private let model = UsageModel.shared
    private let prefs = Preferences.shared
    private let openClaw = OpenClawModel.shared
    private let claude = ClaudeSettingsModel.shared
    // Not a singleton: only the settings window observes it (Models/CLAUDE.md —
    // 그 이유가 없는 상태는 소유자에게 주입).
    private let loginItem = LoginItemModel()
    // Not a singleton either: every view that observes it is made here and
    // handed this instance (Decision #45).
    private let github = GitHubModel(prefs: Preferences.shared)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // QA hook: render reference PNGs offscreen, then exit.
        if SnapshotRenderer.runIfRequested() {
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }

        NSApp.setActivationPolicy(.accessory) // menu-bar only, no Dock icon

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = MenuBarIconView(model: model, prefs: prefs, openClaw: openClaw)
        install(PassthroughHostingView(rootView: icon), as: .claude)
        install(PassthroughHostingView(rootView: GitHubMenuBarView(model: github, prefs: prefs)),
                as: .github)

        if let button = statusItem.button {
            // Regions sit side by side from the button's leading edge; the
            // item's length is kept equal to their total width by
            // `resizeStatusItem`.
            var leading = button.leadingAnchor
            for region in Region.allCases {
                guard let host = hosts[region] else { continue }
                button.addSubview(host)
                NSLayoutConstraint.activate([
                    host.leadingAnchor.constraint(equalTo: leading),
                    host.centerYAnchor.constraint(equalTo: button.centerYAnchor)
                ])
                leading = host.trailingAnchor
            }
            button.target = self
            button.action = #selector(statusItemClicked)
        }

        let popover = NSPopover()
        popover.behavior = .transient
        let content = PopoverView(
            model: model, prefs: prefs, openClaw: openClaw,
            onOpenSettings: { [weak self] in self?.openSettings() },
            onQuit: { NSApp.terminate(nil) }
        )
        let hc = NSHostingController(rootView: content)
        hc.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hc
        clickPopovers[.claude] = popover

        // Instant hover summary: a lightweight popover shown the moment the
        // cursor enters a region and closed when it leaves — no native-tooltip
        // delay. The tracking-area callbacks wired in `install` drive the
        // normal show/close.
        //
        // Not .transient: AppKit dismisses a transient popover on a click
        // outside it and swallows that click, so the first click on the icon
        // only closed the summary and the button action never ran — the full
        // popover took a second click. With .applicationDefined the click
        // reaches the button, and we close the summary ourselves.
        //
        // What changes: the summary now stays for as long as the cursor is over
        // the region, app switches included (.transient closed it on those).
        // The watchdog in `showHoverSummary` only cleans up the case where the
        // cursor has left but mouseExited never arrived.
        let hoverPopover = NSPopover()
        hoverPopover.behavior = .applicationDefined
        hoverPopover.animates = false
        let hoverHC = NSHostingController(rootView: HoverSummaryView(model: model, prefs: prefs))
        hoverHC.sizingOptions = [.preferredContentSize]
        hoverPopover.contentViewController = hoverHC
        hoverPopovers[.claude] = hoverPopover

        let githubPopover = NSPopover()
        githubPopover.behavior = .transient
        let githubHC = NSHostingController(rootView: GitHubPopoverView(
            model: github, prefs: prefs,
            onOpenSettings: { [weak self] in self?.openSettings() },
            onQuit: { NSApp.terminate(nil) }))
        githubHC.sizingOptions = [.preferredContentSize]
        githubPopover.contentViewController = githubHC
        clickPopovers[.github] = githubPopover
        // The model hears the popover: open = refresh at once; closed = only
        // recorded, so the next open refreshes again. AppKit closes a .transient popover
        // itself, so the close is learned from its notification rather than
        // from `togglePopover`.
        NotificationCenter.default.publisher(for: NSPopover.didCloseNotification, object: githubPopover)
            .sink { [weak self] _ in self?.github.setPopoverOpen(false) }
            .store(in: &cancellables)
        // A click popover opens with the app active (`togglePopover`), so the
        // app going inactive means the user went elsewhere. AppKit holds back
        // a .transient popover's close while one of its menus is tracking and
        // doesn't look again once the menu is gone: a click outside that only
        // dismissed the ⋯ menu left the popover up (#70).
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                for popover in self.clickPopovers.values where popover.isShown {
                    popover.performClose(nil)
                }
            }
            .store(in: &cancellables)

        let githubHover = NSPopover()
        githubHover.behavior = .applicationDefined
        githubHover.animates = false
        let githubHoverHC = NSHostingController(rootView: GitHubHoverSummaryView(model: github))
        githubHoverHC.sizingOptions = [.preferredContentSize]
        githubHover.contentViewController = githubHoverHC
        hoverPopovers[.github] = githubHover

        // Later width changes arrive through each host's
        // `onIntrinsicSizeChange` (see `install`).
        resizeStatusItem()
        model.start()

        // Parks in .notConfigured (no polling) when no status URL is set.
        openClaw.start()

        // Loads ~/.claude/settings.json and watches it, so the settings window
        // is already truthful when opened and tracks CLI-side edits live.
        // No-op if Claude Code isn't installed.
        claude.start()

        // Parks in .off (no polling, no Keychain read) until switched on in
        // settings.
        github.start()
    }

    /// Registers a region's host view. The hover callbacks capture the region
    /// here, so each host reports enter/exit for its own region only.
    private func install(_ host: PassthroughHostingView<some View>, as region: Region) {
        host.translatesAutoresizingMaskIntoConstraints = false
        host.onMouseEntered = { [weak self] in self?.showHoverSummary(region) }
        host.onMouseExited = { [weak self] in self?.hideHoverSummary(region) }
        host.onIntrinsicSizeChange = { [weak self] in self?.resizeStatusItem() }
        hosts[region] = host
    }

    /// Keeps the item's length equal to the regions' total width. Setting the
    /// length doesn't invalidate the hosts again — their size depends on their
    /// content only — and a length that is already right isn't written.
    private func resizeStatusItem() {
        guard let statusItem else { return }
        let width = Region.allCases.reduce(CGFloat(0)) { sum, region in
            guard let host = hosts[region] else { return sum }
            host.layoutSubtreeIfNeeded()
            return sum + host.fittingSize.width
        }
        let length = max(Self.minimumStatusItemWidth, width)
        if statusItem.length != length { statusItem.length = length }
    }

    /// Show a region's instant hover summary below it. Suppressed while a
    /// click popover is open so the two never stack.
    private func showHoverSummary(_ region: Region) {
        guard let summary = hoverPopovers[region] else { return }
        // When the cursor crosses from one region into the next, the previous
        // region's mouseExited and this region's mouseEntered arrive in no
        // guaranteed order — so the other summary is closed here rather than
        // left to its own exit.
        if let hoverRegion, hoverRegion != region { hideHoverSummary(hoverRegion) }
        guard !clickPopovers.values.contains(where: \.isShown), !summary.isShown,
              let frame = regionFrameOnScreen(region) else { return }
        let anchor = hoverAnchor ?? Self.makeHoverAnchor()
        hoverAnchor = anchor
        guard let anchorView = anchor.contentView else { return }
        anchor.setFrame(frame, display: false)
        anchor.orderFrontRegardless()
        hoverRegion = region
        summary.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
        // mouseExited normally closes the summary. If that event is ever
        // missed, nothing else would close an .applicationDefined popover, so
        // check the cursor position while the summary is up.
        hoverWatchdog?.invalidate()
        let watchdog = Timer(timeInterval: Self.hoverWatchdogInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !summary.isShown || !self.isCursorOver(region) {
                    self.hideHoverSummary(region)
                } else if let frame = self.regionFrameOnScreen(region) {
                    // The region can change width while the summary is up (a
                    // usage refresh); keep the anchor on it.
                    self.hoverAnchor?.setFrame(frame, display: false)
                }
            }
        }
        // .common: keep checking while the run loop is in an event-tracking
        // mode (a drag in the settings window), not only in .default.
        RunLoop.main.add(watchdog, forMode: .common)
        hoverWatchdog = watchdog
    }

    /// Closes that region's summary only. A late mouseExited from a region the
    /// cursor already left (see `showHoverSummary`) must not take down the
    /// summary that replaced it.
    private func hideHoverSummary(_ region: Region) {
        guard hoverRegion == region, let summary = hoverPopovers[region] else { return }
        hoverWatchdog?.invalidate()
        hoverWatchdog = nil
        summary.performClose(nil)
        hoverAnchor?.orderOut(nil)
        hoverRegion = nil
    }

    /// Borderless and fully transparent, and it ignores mouse events, so the
    /// icon beneath still gets the hover tracking and the click.
    private static func makeHoverAnchor() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        // .fullScreenAuxiliary: the menu bar can be revealed over another
        // app's full-screen space, and the summary has to show there too.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.isExcludedFromWindowsMenu = true
        return window
    }

    /// The column of the button a region occupies, in the button's coordinate
    /// system: the host's horizontal span over the button's full height. The
    /// hosts are shorter than the button (content height, vertically
    /// centered), and popovers are placed against this rect's bottom edge, so
    /// it takes the button's height rather than the host's.
    private func regionRect(_ region: Region) -> NSRect? {
        guard let button = statusItem.button, let host = hosts[region] else { return nil }
        return NSRect(x: host.frame.minX, y: button.bounds.minY,
                      width: host.frame.width, height: button.bounds.height)
    }

    private func regionFrameOnScreen(_ region: Region) -> NSRect? {
        guard let button = statusItem.button, let window = button.window,
              let rect = regionRect(region) else { return nil }
        return window.convertToScreen(button.convert(rect, to: nil))
    }

    private func isCursorOver(_ region: Region) -> Bool {
        regionFrameOnScreen(region)?.contains(NSEvent.mouseLocation) ?? false
    }

    /// Routes the button's click to the region under the cursor by the
    /// cursor's screen x against the GitHub region's leading edge on screen
    /// (`RegionClickRouting`, #58). Routing by the click event's location in
    /// the button sent clicks on the GitHub region to the Claude popover on a
    /// real menu bar (Decision #45), and so did a containment test against the
    /// region's rect, for clicks above, below or beside it. The cursor is only
    /// read for a mouse click: keyboard or accessibility activation opens
    /// `.claude` wherever the cursor happens to rest. A GitHub region with no
    /// width opens `.claude` too.
    @objc private func statusItemClicked() {
        let isMouseClick = NSApp.currentEvent.map { Self.mouseClickTypes.contains($0.type) } ?? false
        let github = regionFrameOnScreen(.github)
        let toGitHub = isMouseClick && RegionClickRouting.clickGoesToGitHub(
            cursorX: NSEvent.mouseLocation.x, githubMinX: github?.minX, githubWidth: github?.width ?? 0)
        togglePopover(toGitHub ? .github : .claude)
    }

    private static let mouseClickTypes: Set<NSEvent.EventType> = [
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
    ]

    private func togglePopover(_ region: Region) {
        guard let button = statusItem.button, let rect = regionRect(region),
              let popover = clickPopovers[region] else { return }
        if let open = clickPopovers.values.first(where: \.isShown) {
            open.performClose(nil)
            if open === popover { return }
        }
        if let hoverRegion { hideHoverSummary(hoverRegion) } // don't stack a hover summary under the full popover
        // Freshen openclaw before showing its section in the unified popover.
        if region == .claude, prefs.showsOpenClaw {
            openClaw.refreshNow()
        }
        // GitHub refreshes once on open — skipped while backing off or
        // stopped for the user (`GitHubPollPolicy.refreshesOnOpen`).
        if region == .github {
            github.setPopoverOpen(true)
        }
        // Anchored to the button, not to the region's host: that is the
        // condition under which AppKit opens a .transient popover on the first
        // click and closes it on a click outside (Decision #8, #36/#39). Only
        // the positioning rect narrows to the region.
        //
        // Activate first. The status-item click leaves the app inactive, so
        // the first click inside the popover activated it — and that late
        // activation ended the ⋯ menu the same click had just opened (#70).
        // `NSApp.activate()` is only a request and wasn't granted here; the
        // `ignoringOtherApps` form activated at once (macOS 27).
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: rect, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Also the target of the app's ⌘, command (`MongshellMenubarApp`).
    func openSettings() {
        for popover in clickPopovers.values { popover.performClose(nil) }
        // Re-read the login-item state on every open. The window (and its view
        // hierarchy) is retained across closes, so `.onAppear` would fire only
        // once — this is the reliable point to catch a change made directly in
        // System Settings.
        loginItem.refresh()
        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView(model: model, prefs: prefs, openClaw: openClaw,
                                claude: claude, loginItem: loginItem, github: github)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 700),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        win.title = "mongshell-menubar 설정"
        win.contentViewController = NSHostingController(rootView: view)
        win.center()
        win.isReleasedWhenClosed = false
        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
