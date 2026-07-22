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
    /// - Parameter persistent: when true, stays visible, accepts drag + click + right-click menu.
    func show(muted: Bool, deviceName: String, persistent: Bool = false) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        isPersistent = persistent
        lastMuted = muted

        ensurePanels()
        for entry in panels.values {
            configureContent(entry.panel, muted: muted, interactive: persistent, screen: entry.screen)
            entry.panel.ignoresMouseEvents = !persistent

            if persistent, isDisplayHidden(displayID(for: entry.screen)) {
                entry.panel.orderOut(nil)
                entry.panel.alphaValue = 0
                continue
            }

            if persistent {
                applyRelativePosition(entry.panel, on: entry.screen)
            } else {
                positionAtBottom(entry.panel, on: entry.screen)
            }
            present(entry.panel, animated: entry.panel.alphaValue < 0.95 || !entry.panel.isVisible)
        }

        if persistent {
            observeScreenChangesIfNeeded()
        } else {
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
        show(muted: lastMuted, deviceName: "", persistent: true)
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
            show(muted: lastMuted, deviceName: "", persistent: true)
        }
    }

    func setAllDisplaysHidden(_ hidden: Bool) {
        if hidden {
            saveHiddenDisplayIDs(Set(NSScreen.screens.map { displayID(for: $0) }))
        } else {
            saveHiddenDisplayIDs([])
        }
        if isPersistent {
            show(muted: lastMuted, deviceName: "", persistent: true)
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

    private func configureContent(_ panel: NSPanel, muted: Bool, interactive: Bool, screen: NSScreen) {
        guard let content = panel.contentView as? HUDContentView else { return }
        content.configureToast(muted: muted)
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

// MARK: - Content

private final class HUDContentView: NSView {
    var onToggle: (() -> Void)?
    var onDragEnded: ((NSWindow) -> Void)?
    var onShowContextMenu: ((NSView, NSEvent) -> Void)?
    var isInteractive = false
    var dragThreshold: CGFloat = 4
    /// Screen this HUD instance belongs to (drag stays within it).
    weak var assignedScreen: NSScreen?

    private let backdrop = NSView()
    private let iconView = NSImageView()
    private let captionLabel = NSTextField(labelWithString: "")

    private var mouseDownScreenPoint: NSPoint?
    private var windowOriginAtDown: NSPoint?
    private var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        backdrop.layer?.cornerRadius = 36
        backdrop.layer?.masksToBounds = true
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        let material = NSVisualEffectView()
        material.material = .hudWindow
        material.blendingMode = .withinWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 36
        material.layer?.masksToBounds = true
        material.alphaValue = 0.35
        material.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(material)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .white
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        captionLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        captionLabel.textColor = NSColor.white.withAlphaComponent(0.95)
        captionLabel.alignment = .center
        captionLabel.isSelectable = false
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(captionLabel)

        NSLayoutConstraint.activate([
            backdrop.centerXAnchor.constraint(equalTo: centerXAnchor),
            backdrop.centerYAnchor.constraint(equalTo: centerYAnchor),
            backdrop.widthAnchor.constraint(equalToConstant: 140),
            backdrop.heightAnchor.constraint(equalToConstant: 140),

            material.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            material.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            material.topAnchor.constraint(equalTo: backdrop.topAnchor),
            material.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),

            iconView.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor, constant: -10),
            iconView.widthAnchor.constraint(equalToConstant: 72),
            iconView.heightAnchor.constraint(equalToConstant: 72),

            captionLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 6),
            captionLabel.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            captionLabel.leadingAnchor.constraint(greaterThanOrEqualTo: backdrop.leadingAnchor, constant: 8),
            captionLabel.trailingAnchor.constraint(lessThanOrEqualTo: backdrop.trailingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configureToast(muted: Bool) {
        let name = muted ? "mic.slash.fill" : "mic.fill"
        let config = NSImage.SymbolConfiguration(pointSize: 58, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        iconView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        iconView.contentTintColor = .white
        captionLabel.stringValue = muted ? "Muted" : "Unmuted"
        backdrop.layer?.backgroundColor = muted
            ? NSColor.black.withAlphaComponent(0.62).cgColor
            : NSColor.black.withAlphaComponent(0.50).cgColor
        backdrop.layer?.borderWidth = 0
        toolTip = isInteractive ? "Click to toggle · drag to move · right-click to hide" : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        if isInteractive {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    /// Route all hits to this view so image/label subviews don't steal drag/click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInteractive else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard isInteractive, let window else {
            super.mouseDown(with: event)
            return
        }
        // Left button only — right-click is handled separately.
        guard event.type == .leftMouseDown else {
            super.mouseDown(with: event)
            return
        }
        mouseDownScreenPoint = NSEvent.mouseLocation
        windowOriginAtDown = window.frame.origin
        isDragging = false
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isInteractive,
              let window,
              let startScreen = mouseDownScreenPoint,
              let startOrigin = windowOriginAtDown
        else {
            super.mouseDragged(with: event)
            return
        }

        let now = NSEvent.mouseLocation
        let dx = now.x - startScreen.x
        let dy = now.y - startScreen.y
        if !isDragging, hypot(dx, dy) >= dragThreshold {
            isDragging = true
        }
        guard isDragging else { return }

        var origin = NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy)
        let boundsScreen = assignedScreen ?? window.screen
        if let boundsScreen {
            origin = clamp(origin, size: window.frame.size, to: boundsScreen.visibleFrame)
        }
        window.setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        if isInteractive, event.type == .leftMouseUp {
            NSCursor.pop()
            if isDragging, let window {
                onDragEnded?(window)
            } else if !isDragging {
                onToggle?()
            }
            mouseDownScreenPoint = nil
            windowOriginAtDown = nil
            isDragging = false
            window?.invalidateCursorRects(for: self)
        } else {
            super.mouseUp(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isInteractive else {
            super.rightMouseDown(with: event)
            return
        }
        onShowContextMenu?(self, event)
    }

    private func clamp(_ origin: NSPoint, size: NSSize, to visible: NSRect) -> NSPoint {
        let minX = visible.minX
        let maxX = visible.maxX - size.width
        let minY = visible.minY
        let maxY = visible.maxY - size.height
        return NSPoint(
            x: min(max(origin.x, minX), max(maxX, minX)),
            y: min(max(origin.y, minY), max(maxY, minY))
        )
    }
}

// MARK: - Helpers

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
