import AppKit

@MainActor
final class MeetingAlertWindowController {
    var onSnooze: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onToggleSound: (() -> Void)?

    private var panel: NSPanel?
    private var card: MeetingAlertCardView?
    private var scale: CGFloat
    private var appeared = false
    private var latest: MeetingAlertSnapshot?

    init() {
        scale = Self.loadScale()
    }

    var isVisible: Bool { panel?.isVisible == true }

    func show(_ snapshot: MeetingAlertSnapshot) {
        let size = NSSize(
            width: MeetingAlertLogic.cardWidth * scale,
            height: MeetingAlertLogic.cardHeight * scale
        )
        latest = snapshot
        if panel == nil {
            let card = MeetingAlertCardView(frame: NSRect(origin: .zero, size: size))
            card.onSnooze = { [weak self] in self?.onSnooze?() }
            card.onDismiss = { [weak self] in self?.onDismiss?() }
            card.onToggleSound = { [weak self] in self?.onToggleSound?() }
            card.onDragEnded = { [weak self] in self?.saveOrigin() }
            card.onScaleChanged = { [weak self] next in
                self?.applyScale(next)
            }
            self.card = card

            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.acceptsMouseMovedEvents = true
            panel.animationBehavior = .none
            panel.contentView = card
            self.panel = panel
            appeared = false
        }

        card?.apply(snapshot, scale: scale)
        guard let panel else { return }
        if panel.frame.size != size {
            var frame = panel.frame
            frame.size = size
            panel.setFrame(frame, display: true)
        }
        if !panel.isVisible {
            panel.setFrameOrigin(initialOrigin(for: size))
            appear(panel)
        }
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        card = nil
        latest = nil
        appeared = false
    }

    private func applyScale(_ next: CGFloat) {
        scale = next
        Self.saveScale(next)
        guard let panel, let card, let latest else { return }
        let old = panel.frame
        let size = NSSize(
            width: MeetingAlertLogic.cardWidth * scale,
            height: MeetingAlertLogic.cardHeight * scale
        )
        card.apply(latest, scale: scale)
        let origin = NSPoint(x: old.origin.x, y: old.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func appear(_ panel: NSPanel) {
        var frame = panel.frame
        let finalOrigin = frame.origin
        frame.origin.y += 14
        panel.setFrame(frame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = MeetingAlertLogic.appearDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(finalOrigin)
        }
        appeared = true
    }

    private func initialOrigin(for size: NSSize) -> NSPoint {
        if let saved = Self.loadOrigin() {
            return MeetingAlertCardView.clampedOrigin(saved, size: size)
        }
        let screen = NSScreen.main ?? NSScreen.screens.first
        let bounds = screen?.visibleFrame ?? NSRect(x: 80, y: 80, width: 800, height: 600)
        let origin = NSPoint(x: bounds.maxX - size.width - 24, y: bounds.maxY - size.height - 24)
        return MeetingAlertCardView.clampedOrigin(origin, size: size)
    }

    private func saveOrigin() {
        guard let origin = panel?.frame.origin else { return }
        UserDefaults.standard.set(origin.x, forKey: Self.originXKey)
        UserDefaults.standard.set(origin.y, forKey: Self.originYKey)
    }

    private static let originXKey = "meetingAlertOriginX"
    private static let originYKey = "meetingAlertOriginY"
    private static let scaleKey = "meetingAlertScale"

    private static func loadOrigin() -> NSPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: originXKey) != nil,
              defaults.object(forKey: originYKey) != nil
        else { return nil }
        return NSPoint(x: defaults.double(forKey: originXKey), y: defaults.double(forKey: originYKey))
    }

    private static func loadScale() -> CGFloat {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: scaleKey) != nil else { return 1 }
        let value = CGFloat(defaults.double(forKey: scaleKey))
        return min(MeetingAlertLogic.scaleMax, max(MeetingAlertLogic.scaleMin, value))
    }

    private static func saveScale(_ value: CGFloat) {
        UserDefaults.standard.set(Double(value), forKey: scaleKey)
    }
}
