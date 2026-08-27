import AppKit

/// Large, semi-transparent mute indicator on every connected display.
/// Toast mode auto-hides; floating mode stays up, is draggable, click toggles mute,
/// and right-click can hide/restore the indicator per display.
@MainActor
final class HUDOverlay: NSObject {
    /// Called when the user clicks the floating HUD (not after a drag).
    var onToggle: (() -> Void)?
    /// Called from the HUD context menu while a session is recording.
    var onStopRecording: (() -> Void)?

    /// Keyed by `displayID(for:)` — `ObjectIdentifier(NSScreen)` is not stable across
    /// reconfiguration, and identical monitors share `localizedName`.
    private var panels: [String: (screen: NSScreen, panel: NSPanel)] = [:]
    private var hideWorkItem: DispatchWorkItem?
    private enum Presentation {
        case toast(persistent: Bool)
        case floating
    }
    private var presentation: Presentation?
    private var lastMuted = false
    private var lastHold: HUDHoldKind = .none
    private var lastRecording = false
    private var screenObserver: NSObjectProtocol?
    /// Mouse-move monitors: toggle `ignoresMouseEvents` so only the rounded pill is interactive.
    /// Event-driven (not a timer) — runs only when the cursor actually moves.
    private var clickThroughLocalMonitor: Any?
    private var clickThroughGlobalMonitor: Any?

    private let panelSize = NSSize(width: 160, height: 160)
    private let bottomMargin: CGFloat = 48
    private let toastDuration: TimeInterval = 1.4
    private let dragThreshold: CGFloat = 4

    /// Per-display relative positions: `[displayID: ["x": relX, "y": relY]]`.
    private static let positionsKey = "hudFloatingPositionsByDisplay"
    /// Display IDs where the floating HUD is hidden by the user.
    private static let hiddenKey = "hudFloatingHiddenDisplays"

    /// Snapshot for menu bar / UI.
    struct ScreenVisibility: Identifiable {
        let id: String
        let name: String
        let isVisible: Bool
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let clickThroughLocalMonitor {
            NSEvent.removeMonitor(clickThroughLocalMonitor)
        }
        if let clickThroughGlobalMonitor {
            NSEvent.removeMonitor(clickThroughGlobalMonitor)
        }
    }

    /// Bottom-center toast. Auto-hides unless `persistent` (hold / recording).
    func showToast(
        muted: Bool,
        hold: HUDHoldKind = .none,
        recording: Bool = false,
        persistent: Bool = false
    ) {
        apply(.toast(persistent: persistent || hold != .none || recording), muted: muted, hold: hold, recording: recording)
    }

    /// Always-on draggable pill, one per display.
    func showFloating(
        muted: Bool,
        hold: HUDHoldKind = .none,
        recording: Bool = false
    ) {
        apply(.floating, muted: muted, hold: hold, recording: recording)
    }

    private var isFloating: Bool {
        if case .floating = presentation { return true }
        return false
    }

    private var isPersistent: Bool {
        switch presentation {
        case .floating, .toast(persistent: true): return true
        default: return false
        }
    }

    private func apply(
        _ presentation: Presentation,
        muted: Bool,
        hold: HUDHoldKind,
        recording: Bool
    ) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        self.presentation = presentation
        lastMuted = muted
        lastHold = hold
        lastRecording = recording
        let floating = isFloating

        ensurePanels()
        for entry in panels.values {
            configureContent(
                entry.panel,
                muted: muted,
                interactive: floating,
                hold: hold,
                recording: recording,
                screen: entry.screen
            )
            entry.panel.ignoresMouseEvents = true
            entry.panel.acceptsMouseMovedEvents = floating || recording

            if floating, isDisplayHidden(displayID(for: entry.screen)) {
                entry.panel.orderOut(nil)
                entry.panel.alphaValue = 0
                continue
            }

            if floating {
                applyRelativePosition(entry.panel, on: entry.screen)
            } else {
                positionAtBottom(entry.panel, on: entry.screen)
            }
            present(entry.panel, animated: entry.panel.alphaValue < 0.95 || !entry.panel.isVisible)
        }

        if floating || recording {
            startClickThroughTrackingIfNeeded()
            updateClickThroughState()
        } else {
            stopClickThroughTracking()
        }

        if floating {
            observeScreenChangesIfNeeded()
        } else {
            stopObservingScreenChanges()
            if !isPersistent {
                let work = DispatchWorkItem { [weak self] in
                    self?.hide()
                }
                hideWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + toastDuration, execute: work)
            }
        }
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        presentation = nil
        stopObservingScreenChanges()
        stopClickThroughTracking()

        for entry in panels.values {
            if let content = entry.panel.contentView as? HUDContentView {
                content.isInteractive = false
            }
            entry.panel.ignoresMouseEvents = true
            entry.panel.acceptsMouseMovedEvents = false
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                entry.panel.animator().alphaValue = 0
            }, completionHandler: {
                entry.panel.orderOut(nil)
            })
        }
    }

    /// Re-layout floating panels when displays change (resolution / add / remove).
    func relayoutIfPersistent() {
        guard isFloating else { return }
        showFloating(muted: lastMuted, hold: lastHold, recording: lastRecording)
    }

    // MARK: - Per-display visibility

    func screenVisibilities() -> [ScreenVisibility] {
        let screens = Self.screensSortedSpatially(NSScreen.screens)
        let names = Self.disambiguatedNames(for: screens)
        return zip(screens, names).map { screen, name in
            let id = displayID(for: screen)
            return ScreenVisibility(
                id: id,
                name: name,
                isVisible: !isDisplayHidden(id)
            )
        }
    }

    func setDisplayHidden(_ displayID: String, hidden: Bool) {
        var hiddenIDs = loadHiddenDisplayIDs()
        if hidden {
            hiddenIDs.insert(displayID)
        } else {
            hiddenIDs.remove(displayID)
        }
        saveHiddenDisplayIDs(hiddenIDs)
        if isFloating {
            showFloating(muted: lastMuted, hold: lastHold, recording: lastRecording)
        }
    }

    /// Flip from stored visibility, not `NSMenuItem.state` — macOS 14+ may rewrite
    /// item state for a same-target/action selection group before the action runs.
    func toggleDisplayHidden(_ displayID: String) {
        setDisplayHidden(displayID, hidden: !isDisplayHidden(displayID))
    }

    func setAllDisplaysHidden(_ hidden: Bool) {
        if hidden {
            saveHiddenDisplayIDs(Set(NSScreen.screens.map { displayID(for: $0) }))
        } else {
            saveHiddenDisplayIDs([])
        }
        if isFloating {
            showFloating(muted: lastMuted, hold: lastHold, recording: lastRecording)
        }
    }

    func hasAnyHiddenDisplay() -> Bool {
        screenVisibilities().contains { !$0.isVisible }
    }

    func hasAnyVisibleDisplay() -> Bool {
        screenVisibilities().contains { $0.isVisible }
    }

    // MARK: - Panels

    private func ensurePanels() {
        let screens = NSScreen.screens
        let ids = Set(screens.map { displayID(for: $0) })
        for (id, entry) in panels {
            if !ids.contains(id) {
                entry.panel.orderOut(nil)
                panels.removeValue(forKey: id)
            }
        }
        for screen in screens {
            _ = panel(for: screen)
        }
    }

    private func panel(for screen: NSScreen) -> NSPanel {
        let id = displayID(for: screen)
        if var existing = panels[id] {
            existing.screen = screen
            panels[id] = existing
            return existing.panel
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = HUDContentView(frame: NSRect(origin: .zero, size: panelSize))

        panels[id] = (screen, panel)
        return panel
    }

    private func configureContent(
        _ panel: NSPanel,
        muted: Bool,
        interactive: Bool,
        hold: HUDHoldKind,
        recording: Bool,
        screen: NSScreen
    ) {
        guard let content = panel.contentView as? HUDContentView else { return }
        content.isInteractive = interactive
        content.dragThreshold = dragThreshold
        content.assignedScreen = screen
        content.configureToast(
            muted: muted,
            hold: hold,
            updateAvailable: UpdateChecker.shared.availableUpdate != nil,
            recording: recording
        )
        content.onToggle = { [weak self] in
            self?.onToggle?()
            self?.updateClickThroughState()
        }
        content.onDragEnded = { [weak self] window in
            self?.persistPosition(from: window)
            self?.updateClickThroughState()
        }
        content.onShowContextMenu = { [weak self] view, event in
            self?.showContextMenu(for: view, event: event)
        }
    }

    /// Refresh the red update badge on visible HUD panels.
    func refreshUpdateBadge() {
        let available = UpdateChecker.shared.availableUpdate != nil
        for entry in panels.values {
            (entry.panel.contentView as? HUDContentView)?.setUpdateAvailable(available)
        }
    }

    // MARK: - Click-through (rounded pill only)

    private func startClickThroughTrackingIfNeeded() {
        guard clickThroughLocalMonitor == nil else { return }
        // hitTest:nil cannot pass clicks through an NSWindow — flip ignoresMouseEvents instead.
        let mask: NSEvent.EventTypeMask = .mouseMoved
        clickThroughLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.updateClickThroughState()
            return event
        }
        clickThroughGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            Task { @MainActor in
                self?.updateClickThroughState()
            }
        }
    }

    private func stopClickThroughTracking() {
        if let clickThroughLocalMonitor {
            NSEvent.removeMonitor(clickThroughLocalMonitor)
            self.clickThroughLocalMonitor = nil
        }
        if let clickThroughGlobalMonitor {
            NSEvent.removeMonitor(clickThroughGlobalMonitor)
            self.clickThroughGlobalMonitor = nil
        }
    }

    /// Mouse only over the visible pill (or mid-drag).
    private func updateClickThroughState() {
        guard isFloating || lastRecording else { return }
        let mouse = NSEvent.mouseLocation
        for entry in panels.values {
            guard let content = entry.panel.contentView as? HUDContentView else { continue }
            let overPill = entry.panel.isVisible
                && entry.panel.alphaValue >= 0.05
                && (content.isHandlingMouseSession || content.containsInteractiveScreenPoint(mouse))
            let ignore = !overPill
            if entry.panel.ignoresMouseEvents != ignore {
                entry.panel.ignoresMouseEvents = ignore
            }
        }
    }

    private func showContextMenu(for view: NSView, event: NSEvent) {
        let screen = (view as? HUDContentView)?.assignedScreen ?? screen(for: view.window)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.selectionMode = .selectAny

        if lastRecording {
            let stop = NSMenuItem(
                title: L10n.menuStopRecording,
                action: #selector(contextStopRecording),
                keyEquivalent: ""
            )
            stop.target = self
            stop.image = NSImage.menuItemSymbol("stop.circle")
            menu.addItem(stop)
        }

        if isFloating, let screen {
            if lastRecording {
                menu.addItem(.separator())
            }
            let thisID = displayID(for: screen)
            let hideItem = NSMenuItem(
                title: L10n.menuHideThisDisplay,
                action: #selector(contextHideThisDisplay(_:)),
                keyEquivalent: ""
            )
            hideItem.target = self
            hideItem.representedObject = thisID
            menu.addItem(hideItem)

            let hiddenOthers = screenVisibilities().filter { !$0.isVisible && $0.id != thisID }
            if !hiddenOthers.isEmpty {
                menu.addItem(.separator())
                for screenInfo in hiddenOthers {
                    let item = NSMenuItem(
                        title: L10n.menuShowOnDisplay(screenInfo.name),
                        action: #selector(contextShowDisplay(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = screenInfo.id
                    menu.addItem(item)
                }
            }

            if hasAnyHiddenDisplay() {
                menu.addItem(.separator())
                let showAll = NSMenuItem(
                    title: L10n.menuShowAllDisplays,
                    action: #selector(contextShowAllDisplays(_:)),
                    keyEquivalent: ""
                )
                showAll.target = self
                menu.addItem(showAll)
            }
        }

        guard !menu.items.isEmpty else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func contextStopRecording() {
        onStopRecording?()
    }

    @objc private func contextHideThisDisplay(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        setDisplayHidden(id, hidden: true)
    }

    @objc private func contextShowDisplay(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        setDisplayHidden(id, hidden: false)
    }

    @objc private func contextShowAllDisplays(_ sender: NSMenuItem) {
        setAllDisplaysHidden(false)
    }

    private func positionAtBottom(_ panel: NSPanel, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - panelSize.width / 2,
            y: visible.minY + bottomMargin
        )
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
    }

    private func applyRelativePosition(_ panel: NSPanel, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let origin: NSPoint
        if let saved = savedPosition(for: screen) {
            let maxX = max(visible.width - panelSize.width, 0)
            let maxY = max(visible.height - panelSize.height, 0)
            origin = NSPoint(
                x: visible.minX + saved.x.clamped(to: 0...1) * maxX,
                y: visible.minY + saved.y.clamped(to: 0...1) * maxY
            )
        } else {
            origin = NSPoint(
                x: visible.midX - panelSize.width / 2,
                y: visible.minY + bottomMargin
            )
        }
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
    }

    private func persistPosition(from window: NSWindow) {
        guard let screen = screen(for: window) else { return }

        let visible = screen.visibleFrame
        let origin = window.frame.origin
        let maxX = max(visible.width - panelSize.width, 1)
        let maxY = max(visible.height - panelSize.height, 1)
        let relX = ((origin.x - visible.minX) / maxX).clamped(to: 0...1)
        let relY = ((origin.y - visible.minY) / maxY).clamped(to: 0...1)

        var all = loadAllPositions()
        all[displayID(for: screen)] = ["x": Double(relX), "y": Double(relY)]
        UserDefaults.standard.set(all, forKey: Self.positionsKey)
    }

    private func savedPosition(for screen: NSScreen) -> (x: CGFloat, y: CGFloat)? {
        let id = displayID(for: screen)
        guard let dict = loadAllPositions()[id],
              let x = dict["x"], let y = dict["y"]
        else { return nil }
        return (CGFloat(x), CGFloat(y))
    }

    private func loadAllPositions() -> [String: [String: Double]] {
        UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: [String: Double]] ?? [:]
    }

    private func loadHiddenDisplayIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? [])
    }

    private func saveHiddenDisplayIDs(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids).sorted(), forKey: Self.hiddenKey)
    }

    private func isDisplayHidden(_ id: String) -> Bool {
        loadHiddenDisplayIDs().contains(id)
    }

    func displayID(for screen: NSScreen) -> String {
        if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return String(num.uint32Value)
        }
        // Never fall back to `localizedName` alone — identical monitors share it.
        let origin = screen.frame.origin
        return "\(screen.localizedName)@\(Int(origin.x.rounded())),\(Int(origin.y.rounded()))"
    }

    private func screen(for window: NSWindow?) -> NSScreen? {
        guard let window else { return nil }
        return panels.first(where: { $0.value.panel === window })?.value.screen
    }

    /// Left-to-right, then top-to-bottom. `NSScreen.screens` is main-first, which
    /// makes identical-named displays look randomly ordered in the menu.
    private static func screensSortedSpatially(_ screens: [NSScreen]) -> [NSScreen] {
        screens.sorted { a, b in
            let rowThreshold = max(a.frame.height, b.frame.height) * 0.25
            if abs(a.frame.midY - b.frame.midY) > rowThreshold {
                return a.frame.midY > b.frame.midY
            }
            return a.frame.minX < b.frame.minX
        }
    }

    private static func disambiguatedNames(for screens: [NSScreen]) -> [String] {
        var counts: [String: Int] = [:]
        for screen in screens {
            counts[screen.localizedName, default: 0] += 1
        }
        return screens.map { screen in
            let base = screen.localizedName
            guard counts[base, default: 0] > 1 else { return base }
            let peers = screens.filter { $0.localizedName == base }
            return L10n.menuDisplayNamed(base, role: spatialRole(of: screen, among: peers))
        }
    }

    private static func spatialRole(of screen: NSScreen, among peers: [NSScreen]) -> L10n.DisplaySpatialRole {
        guard peers.count > 1 else { return .center }
        let xSpan = (peers.map(\.frame.midX).max() ?? 0) - (peers.map(\.frame.midX).min() ?? 0)
        let ySpan = (peers.map(\.frame.midY).max() ?? 0) - (peers.map(\.frame.midY).min() ?? 0)
        if xSpan >= ySpan {
            let sorted = peers.sorted { $0.frame.midX < $1.frame.midX }
            guard let idx = sorted.firstIndex(where: { $0.frame == screen.frame }) else { return .center }
            if sorted.count == 2 { return idx == 0 ? .left : .right }
            if idx == 0 { return .left }
            if idx == sorted.count - 1 { return .right }
            if sorted.count == 3 { return .center }
            return .index(idx + 1)
        }
        let sorted = peers.sorted { $0.frame.midY > $1.frame.midY }
        guard let idx = sorted.firstIndex(where: { $0.frame == screen.frame }) else { return .center }
        if sorted.count == 2 { return idx == 0 ? .above : .below }
        if idx == 0 { return .above }
        if idx == sorted.count - 1 { return .below }
        if sorted.count == 3 { return .center }
        return .index(idx + 1)
    }

    private func present(_ panel: NSPanel, animated: Bool) {
        if animated {
            animateIn(panel)
        } else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    private func animateIn(_ panel: NSPanel) {
        panel.alphaValue = 0
        if let layer = panel.contentView?.layer {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            let frame = panel.contentView?.frame ?? .zero
            layer.position = CGPoint(x: frame.midX, y: frame.midY)
            layer.setAffineTransform(CGAffineTransform(scaleX: 0.88, y: 0.88))
        }

        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        if let layer = panel.contentView?.layer {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.18)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            layer.setAffineTransform(.identity)
            CATransaction.commit()
        }
    }

    private func observeScreenChangesIfNeeded() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.relayoutIfPersistent()
            }
        }
    }

    private func stopObservingScreenChanges() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
    }
}
