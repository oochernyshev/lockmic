import AppKit

/// Large, semi-transparent mute indicator on every connected display.
/// Toast mode auto-hides; floating mode stays up, is draggable, click toggles mute,
/// and right-click can hide/restore the indicator per display.
@MainActor
final class HUDOverlay: NSObject {
    /// Called when the user clicks the floating HUD (not after a drag).
    var onToggle: (() -> Void)?

    private var panels: [ObjectIdentifier: (screen: NSScreen, panel: NSPanel)] = [:]
    private var hideWorkItem: DispatchWorkItem?
    private var isPersistent = false
    private var lastMuted = false
    private var lastHold: HUDHoldKind = .none
    private var lastInteractive = false
    private var screenObserver: NSObjectProtocol?

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
    }

    /// Show or update the HUD.
    /// - Parameters:
    ///   - persistent: when true, stays visible until `hide()` or a non-persistent `show`.
    ///   - interactive: drag / click / per-display hide (floating mode). Defaults to `persistent`.
    ///     Momentary holds use `persistent: true, interactive: false` so toast HUD stays up while held.
    ///   - hold: optional momentary label (Talking / Hold mute / Holding).
    func show(
        muted: Bool,
        deviceName: String,
        persistent: Bool = false,
        interactive: Bool? = nil,
        hold: HUDHoldKind = .none
    ) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        isPersistent = persistent
        lastMuted = muted
        lastHold = hold
        let isInteractive = interactive ?? persistent
        lastInteractive = isInteractive

        ensurePanels()
        for entry in panels.values {
            configureContent(
                entry.panel,
                muted: muted,
                interactive: isInteractive,
                hold: hold,
                screen: entry.screen
            )
            entry.panel.ignoresMouseEvents = !isInteractive

            // Per-display hide only applies to interactive floating HUD.
            if isInteractive, isDisplayHidden(displayID(for: entry.screen)) {
                entry.panel.orderOut(nil)
                entry.panel.alphaValue = 0
                continue
            }

            if isInteractive {
                applyRelativePosition(entry.panel, on: entry.screen)
            } else {
                positionAtBottom(entry.panel, on: entry.screen)
            }
            present(entry.panel, animated: entry.panel.alphaValue < 0.95 || !entry.panel.isVisible)
        }

        if persistent {
            if isInteractive {
                observeScreenChangesIfNeeded()
            }
        } else {
            stopObservingScreenChanges()
            let work = DispatchWorkItem { [weak self] in
                self?.hide()
            }
            hideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + toastDuration, execute: work)
        }
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        isPersistent = false
        stopObservingScreenChanges()

        for entry in panels.values {
            if let content = entry.panel.contentView as? HUDContentView {
                content.isInteractive = false
            }
            entry.panel.ignoresMouseEvents = true
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
        guard isPersistent else { return }
        show(
            muted: lastMuted,
            deviceName: "",
            persistent: true,
            interactive: lastInteractive,
            hold: lastHold
        )
    }

    // MARK: - Per-display visibility

    func screenVisibilities() -> [ScreenVisibility] {
        NSScreen.screens.map { screen in
            let id = displayID(for: screen)
            return ScreenVisibility(
                id: id,
                name: screen.localizedName,
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
        if isPersistent {
            show(
                muted: lastMuted,
                deviceName: "",
                persistent: true,
                interactive: lastInteractive,
                hold: lastHold
            )
        }
    }

    func setAllDisplaysHidden(_ hidden: Bool) {
        if hidden {
            saveHiddenDisplayIDs(Set(NSScreen.screens.map { displayID(for: $0) }))
        } else {
            saveHiddenDisplayIDs([])
        }
        if isPersistent {
            show(
                muted: lastMuted,
                deviceName: "",
                persistent: true,
                interactive: lastInteractive,
                hold: lastHold
            )
        }
    }

    func hasAnyHiddenDisplay() -> Bool {
        !loadHiddenDisplayIDs().isEmpty
    }

    // MARK: - Panels

    private func ensurePanels() {
        let screens = NSScreen.screens
        let screenSet = Set(screens.map { ObjectIdentifier($0) })
        for (id, entry) in panels {
            if !screenSet.contains(id) {
                entry.panel.orderOut(nil)
                panels.removeValue(forKey: id)
            } else {
                panels[id] = (screens.first(where: { ObjectIdentifier($0) == id }) ?? entry.screen, entry.panel)
            }
        }
        for screen in screens {
            _ = panel(for: screen)
        }
    }

    private func panel(for screen: NSScreen) -> NSPanel {
        let id = ObjectIdentifier(screen)
        if let existing = panels[id] {
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
        screen: NSScreen
    ) {
        guard let content = panel.contentView as? HUDContentView else { return }
        content.configureToast(muted: muted, hold: hold)
        content.isInteractive = interactive
        content.dragThreshold = dragThreshold
        content.assignedScreen = screen
        content.onToggle = { [weak self] in
            self?.onToggle?()
        }
        content.onDragEnded = { [weak self] window in
            self?.persistPosition(from: window)
        }
        content.onShowContextMenu = { [weak self] view, event in
            self?.showContextMenu(for: view, event: event)
        }
    }

    private func showContextMenu(for view: NSView, event: NSEvent) {
        guard isPersistent, let screen = (view as? HUDContentView)?.assignedScreen ?? screen(for: view.window) else {
            return
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let thisID = displayID(for: screen)
        let hideItem = NSMenuItem(
            title: "Hide on This Display",
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
                    title: "Show on \(screenInfo.name)",
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
                title: "Show on All Displays",
                action: #selector(contextShowAllDisplays(_:)),
                keyEquivalent: ""
            )
            showAll.target = self
            menu.addItem(showAll)
        }

        NSMenu.popUpContextMenu(menu, with: event, for: view)
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
        return screen.localizedName
    }

    private func screen(for window: NSWindow?) -> NSScreen? {
        guard let window else { return nil }
        return panels.first(where: { $0.value.panel === window })?.value.screen
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
