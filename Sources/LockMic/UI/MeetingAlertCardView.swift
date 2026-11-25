import AppKit

@MainActor
final class MeetingAlertCardView: NSView {
    var onSnooze: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onToggleSound: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onScaleChanged: ((CGFloat) -> Void)?

    private static let pad: CGFloat = 20
    private static let btnGap: CGFloat = 12
    private static let btnH: CGFloat = 46
    private static let ringR: CGFloat = 46
    private static let ringGap: CGFloat = 16
    private static let corner: CGFloat = 18
    private static let yellow = NSColor(srgbRed: 1, green: 0.76, blue: 0.20, alpha: 1)
    private static let red = NSColor(srgbRed: 1, green: 0.28, blue: 0.28, alpha: 1)
    private static let navy = NSColor(srgbRed: 0.09, green: 0.13, blue: 0.21, alpha: 1)

    private let glassHost = NSView()
    private let tint = NSView()
    private let headline = NSTextField(labelWithString: "")
    private let ring = CountdownRingView()
    private let soundButton = MeetingCardButton()
    private let snoozeButton = MeetingCardButton()
    private let okButton = MeetingCardButton()
    private let resizeMark = ResizeGripView()

    private var scale: CGFloat = 1
    private var snapshot: MeetingAlertSnapshot?
    private let dragThreshold: CGFloat = 4

    /// Latest pointer sample from the drag thread. The main thread only applies it.
    private let dragSample = DragSample()
    private var dragMoved = false

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Self.corner
        // Leave shadows of the buttons unclipped. Glass and tint round themselves.
        layer?.masksToBounds = false
        layer?.borderWidth = 1
        appearance = NSAppearance(named: .darkAqua)

        glassHost.wantsLayer = true
        addSubview(glassHost)
        installGlass()

        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(srgbRed: 0.09, green: 0.13, blue: 0.21, alpha: 0.18).cgColor
        addSubview(tint)

        headline.font = NSFont(name: "Helvetica Neue", size: 28) ?? .systemFont(ofSize: 28, weight: .regular)
        headline.textColor = .white
        headline.alignment = .left
        headline.lineBreakMode = .byWordWrapping
        headline.maximumNumberOfLines = 4
        headline.drawsBackground = false
        headline.isSelectable = false
        addSubview(headline)

        addSubview(ring)

        soundButton.target = self
        soundButton.action = #selector(tapSound)
        addSubview(soundButton)

        snoozeButton.target = self
        snoozeButton.action = #selector(tapSnooze)
        addSubview(snoozeButton)

        okButton.target = self
        okButton.action = #selector(tapOK)
        addSubview(okButton)

        addSubview(resizeMark)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        updateButtonHover(event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateButtonHover(event)
    }

    override func mouseExited(with event: NSEvent) {
        for button in [soundButton, snoozeButton, okButton] {
            button.setHovered(false)
        }
    }

    private func updateButtonHover(_ event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        soundButton.setHovered(soundButton.frame.contains(local))
        snoozeButton.setHovered(snoozeButton.frame.contains(local))
        okButton.setHovered(okButton.frame.contains(local))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        layer?.cornerRadius = Self.corner * scale
        layer?.borderWidth = max(1, scale)
    }

    func apply(_ snapshot: MeetingAlertSnapshot, scale: CGFloat) {
        self.snapshot = snapshot
        self.scale = min(MeetingAlertLogic.scaleMax, max(MeetingAlertLogic.scaleMin, scale))
        let phase = MeetingAlertLogic.phase(remaining: snapshot.remaining, duration: snapshot.duration)
        let accent: NSColor = phase == .upcoming ? Self.yellow : Self.red
        let status: String
        switch phase {
        case .upcoming: status = L10n.meetingStatusUpcoming
        case .soon: status = L10n.meetingStatusSoon
        case .now: status = L10n.meetingStatusNow
        case .finished: status = L10n.meetingStatusFinished
        }

        let timeText = MeetingAlertLogic.meetingTimeText(start: snapshot.start)
        let line = MeetingAlertLogic.headline(timeText: timeText, title: snapshot.title)
        let headlineSize = 28 * self.scale
        let statusSize = 18 * self.scale
        let body = NSMutableAttributedString(
            string: line + "\n",
            attributes: [
                .font: NSFont(name: "Helvetica Neue", size: headlineSize)
                    ?? .systemFont(ofSize: headlineSize, weight: .regular),
                .foregroundColor: NSColor.white,
            ]
        )
        body.append(NSAttributedString(
            string: status,
            attributes: [
                .font: NSFont(name: "Helvetica Neue", size: statusSize)
                    ?? .systemFont(ofSize: statusSize, weight: .medium),
                .foregroundColor: accent,
            ]
        ))
        headline.attributedStringValue = body

        ring.accent = accent
        ring.started = snapshot.remaining <= 0
        ring.fraction = MeetingAlertLogic.ringFraction(
            remaining: snapshot.remaining,
            duration: snapshot.duration
        )
        ring.label = MeetingAlertLogic.countdownText(remaining: snapshot.remaining)
        ring.needsDisplay = true

        let snooze = MeetingAlertLogic.snoozeSeconds(remaining: snapshot.remaining)
        snoozeButton.setTitle(L10n.meetingSnooze(snooze), color: .white, fill: NSColor.white.withAlphaComponent(0.12))
        okButton.setTitle(L10n.meetingOK, color: Self.navy, fill: accent)
        soundButton.setSound(on: snapshot.soundEnabled, scale: self.scale)
        soundButton.toolTip = snapshot.soundEnabled ? L10n.meetingSoundOn : L10n.meetingSoundOff
        needsLayout = true
        needsDisplay = true
        updateLayer()
    }

    override func layout() {
        super.layout()
        let s = scale
        let pad = Self.pad * s
        let btnGap = Self.btnGap * s
        let btnH = Self.btnH * s
        let ringR = Self.ringR * s
        let ringGap = Self.ringGap * s
        let width = bounds.width
        let height = bounds.height
        glassHost.frame = bounds
        tint.frame = bounds
        tint.layer?.cornerRadius = Self.corner * s
        for sub in glassHost.subviews {
            sub.frame = glassHost.bounds
            if #available(macOS 26.0, *), let glass = sub as? NSGlassEffectView {
                glass.cornerRadius = Self.corner * s
            } else {
                sub.layer?.cornerRadius = Self.corner * s
            }
        }

        let ringCX = width - pad - ringR
        let ringCY = (16 * s) + ringR
        ring.frame = NSRect(
            x: ringCX - ringR,
            y: ringCY - ringR,
            width: ringR * 2,
            height: ringR * 2
        )

        let textW = ringCX - ringR - pad - ringGap
        let buttonsY = height - pad - btnH
        let headlineY = 16 * s
        headline.frame = NSRect(
            x: pad,
            y: headlineY,
            width: max(40, textW),
            height: max(40, buttonsY - (10 * s) - headlineY)
        )

        let soundBtn = btnH
        let btnW = (width - pad * 2 - btnGap * 2 - soundBtn) / 2
        soundButton.frame = NSRect(x: pad, y: buttonsY, width: soundBtn, height: btnH)
        let snoozeX = pad + soundBtn + btnGap
        snoozeButton.frame = NSRect(x: snoozeX, y: buttonsY, width: btnW, height: btnH)
        okButton.frame = NSRect(x: snoozeX + btnW + btnGap, y: buttonsY, width: btnW, height: btnH)
        soundButton.fontSize = 20 * s
        snoozeButton.fontSize = 20 * s
        okButton.fontSize = 20 * s
        soundButton.corner = 10 * s
        snoozeButton.corner = 10 * s
        okButton.corner = 10 * s

        let grip = 28 * s
        resizeMark.lineWidth = max(1.5, 2 * s)
        resizeMark.frame = NSRect(x: width - grip, y: height - grip, width: grip, height: grip)
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(resizeMark.frame, cursor: Self.resizeCursor)
    }

    /// Bottom-right corner of this flipped card. macOS 14 has no public diagonal resize cursor.
    private static let resizeCursor: NSCursor = {
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(position: .bottomRight, directions: [.inward, .outward])
        }
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let path = NSBezierPath()
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: NSPoint(x: 3.5, y: 3.5))
            path.line(to: NSPoint(x: 14.5, y: 14.5))
            path.move(to: NSPoint(x: 9, y: 14.5))
            path.line(to: NSPoint(x: 14.5, y: 14.5))
            path.line(to: NSPoint(x: 14.5, y: 9))
            path.move(to: NSPoint(x: 3.5, y: 9))
            path.line(to: NSPoint(x: 3.5, y: 3.5))
            path.line(to: NSPoint(x: 9, y: 3.5))
            NSColor.black.setStroke()
            path.lineWidth = 3.2
            path.stroke()
            NSColor.white.setStroke()
            path.lineWidth = 1.6
            path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 9, y: 9))
    }()

    /// Title, ring, and glass sit above this view. Own those hits so a drag
    /// starts there. `point` is in the superview's coordinates, not this view's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        for button in [soundButton, snoozeButton, okButton] where button.frame.contains(local) {
            return button.hitTest(convert(local, to: button.superview)) ?? button
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if let button = [soundButton, snoozeButton, okButton].first(where: { $0.frame.contains(local) }) {
            button.mouseDown(with: event)
            return
        }
        guard let window else { return }
        let resize = resizeMark.frame.contains(local)
        let startMouse = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        let startScale = scale
        let startSize = window.frame.size
        // Follow the pointer off the main thread. Beeps and card redraw keep the
        // main run loop, so a Glass tick does not freeze the drag.
        dragMoved = false
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            while (NSEvent.pressedMouseButtons & 1) != 0 {
                let now = NSEvent.mouseLocation
                guard let self, self.dragSample.send(now) else {
                    Thread.sleep(forTimeInterval: 1.0 / 120.0)
                    continue
                }
                DispatchQueue.main.async { [weak self] in
                    self?.applyDragSample(
                        resize: resize,
                        startMouse: startMouse,
                        startOrigin: startOrigin,
                        startScale: startScale,
                        startSize: startSize
                    )
                }
                Thread.sleep(forTimeInterval: 1.0 / 120.0)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.dragMoved { self.onDragEnded?() }
                self.dragMoved = false
            }
        }
    }

    /// Applies the newest pointer sample. Returns whether the card moved.
    private func applyDragSample(
        resize: Bool,
        startMouse: NSPoint,
        startOrigin: NSPoint,
        startScale: CGFloat,
        startSize: NSSize
    ) -> Bool {
        guard let window, let now = dragSample.take() else { return false }
        if resize {
            let dw = now.x - startMouse.x
            let dh = -(now.y - startMouse.y)
            let nextScale: CGFloat
            if abs(dw) >= abs(dh) {
                nextScale = (startSize.width + dw) / MeetingAlertLogic.cardWidth
            } else {
                let height = max(1, startSize.height)
                nextScale = startScale * (height + dh) / height
            }
            let clamped = min(MeetingAlertLogic.scaleMax, max(MeetingAlertLogic.scaleMin, nextScale))
            if abs(clamped - scale) < 0.005 { return false }
            dragMoved = true
            onScaleChanged?(clamped)
            return true
        }
        let delta = NSPoint(x: now.x - startMouse.x, y: now.y - startMouse.y)
        if hypot(delta.x, delta.y) < dragThreshold { return false }
        let origin = Self.clampedOrigin(
            NSPoint(x: startOrigin.x + delta.x, y: startOrigin.y + delta.y),
            size: window.frame.size
        )
        window.setFrameOrigin(origin)
        dragMoved = true
        return true
    }

    static func clampedOrigin(_ origin: NSPoint, size: NSSize) -> NSPoint {
        let probe = NSPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        let screen = NSScreen.screens.first { NSMouseInRect(probe, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        // Full display frame, not visibleFrame: visibleFrame stops at the Dock.
        guard let bounds = screen?.frame else { return origin }
        let margin: CGFloat = 48
        let x = min(max(origin.x, bounds.minX - size.width + margin), bounds.maxX - margin)
        let y = min(max(origin.y, bounds.minY - size.height + margin), bounds.maxY - margin)
        return NSPoint(x: x, y: y)
    }

    @objc private func tapSound() { onToggleSound?() }
    @objc private func tapSnooze() { onSnooze?() }
    @objc private func tapOK() { onDismiss?() }

    private func installGlass() {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.corner
            glass.style = .regular
            glass.frame = glassHost.bounds
            glass.autoresizingMask = [.width, .height]
            glassHost.addSubview(glass)
        } else {
            let material = NSVisualEffectView()
            material.material = .hudWindow
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = Self.corner
            material.layer?.masksToBounds = true
            material.frame = glassHost.bounds
            material.autoresizingMask = [.width, .height]
            glassHost.addSubview(material)
        }
    }

}

struct MeetingAlertSnapshot: Equatable {
    var title: String
    var start: TimeInterval
    var remaining: TimeInterval
    var duration: TimeInterval?
    var soundEnabled: Bool
}

/// Pointer samples taken off the main thread while a drag is active.
private final class DragSample: @unchecked Sendable {
    private let lock = NSLock()
    private var point: NSPoint?
    private var scheduled = false

    /// Stores `point`. Returns true when the caller should schedule one main-thread apply.
    func send(_ point: NSPoint) -> Bool {
        lock.lock()
        self.point = point
        let shouldSchedule = !scheduled
        scheduled = true
        lock.unlock()
        return shouldSchedule
    }

    func take() -> NSPoint? {
        lock.lock()
        let point = self.point
        self.point = nil
        scheduled = false
        lock.unlock()
        return point
    }
}

private final class MeetingCardButton: NSButton {
    var corner: CGFloat = 10 {
        didSet { layer?.cornerRadius = corner }
    }
    var fontSize: CGFloat = 20 {
        didSet { font = .systemFont(ofSize: fontSize, weight: .medium) }
    }

    private var baseFill: NSColor = .clear
    private var hovered = false
    /// Shadow lives outside the fill, so a translucent button matches an opaque one.
    private let shadowHost = CALayer()
    private let shadowCast = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .regularSquare
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        focusRingType = .none
        font = .systemFont(ofSize: 20, weight: .medium)
        setButtonType(.momentaryChange)
        shadowCast.backgroundColor = NSColor.white.cgColor
        shadowCast.shadowColor = NSColor.white.cgColor
        shadowCast.shadowOpacity = 0
        shadowCast.shadowOffset = CGSize(width: 0, height: -2)
        shadowHost.addSublayer(shadowCast)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0, let host = superview?.layer else { return }
        if shadowHost.superlayer !== host {
            host.insertSublayer(shadowHost, below: layer)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The host is larger than the button so the shadow has pixels to land in.
        // The mask removes the button shape, which is what showed through Snooze.
        let pad: CGFloat = 32
        shadowHost.frame = frame.insetBy(dx: -pad, dy: -pad)
        let cast = CGRect(x: pad, y: pad, width: bounds.width, height: bounds.height)
        shadowCast.frame = cast
        shadowCast.cornerRadius = corner
        shadowCast.shadowPath = CGPath(
            roundedRect: shadowCast.bounds,
            cornerWidth: corner,
            cornerHeight: corner,
            transform: nil
        )
        let mask = CAShapeLayer()
        let cutout = CGMutablePath()
        cutout.addRect(CGRect(origin: .zero, size: shadowHost.bounds.size))
        cutout.addRoundedRect(in: cast, cornerWidth: corner, cornerHeight: corner)
        mask.frame = shadowHost.bounds
        mask.fillRule = .evenOdd
        mask.path = cutout
        shadowHost.mask = mask
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { shadowHost.removeFromSuperlayer() }
    }

    func setHovered(_ on: Bool) {
        guard hovered != on else { return }
        hovered = on
        applyHover(animated: true)
    }

    func setTitle(_ title: String, color: NSColor, fill: NSColor) {
        image = nil
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: color,
        ])
        contentTintColor = color
        baseFill = fill
        applyHover(animated: false)
    }

    func setSound(on: Bool, scale: CGFloat) {
        attributedTitle = NSAttributedString()
        let config = NSImage.SymbolConfiguration(pointSize: 18 * scale, weight: .medium)
        let name = on ? "speaker.wave.2.fill" : "speaker.slash.fill"
        image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        imagePosition = .imageOnly
        contentTintColor = on ? .white : NSColor.white.withAlphaComponent(0.55)
        baseFill = NSColor.white.withAlphaComponent(on ? 0.12 : 0.08)
        applyHover(animated: false)
    }

    /// Drop shadow from the button outline, not its fill. The card refresh must
    /// not restart a hover that is already showing.
    private func applyHover(animated: Bool) {
        guard let layer else { return }
        self.shadow = nil
        layer.shadowOpacity = 0
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.16)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        layer.backgroundColor = baseFill.cgColor
        layer.cornerRadius = corner
        layer.masksToBounds = true
        shadowCast.shadowOpacity = hovered ? 1 : 0
        shadowCast.shadowRadius = hovered ? 14 : 0
        shadowCast.shadowOffset = CGSize(width: 0, height: hovered ? -3 : 0)
        CATransaction.commit()
    }
}

private final class CountdownRingView: NSView {
    var fraction: CGFloat = 1
    var started = false
    var accent = NSColor.systemYellow
    var label = "02:00"

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let stroke = max(4, min(bounds.width, bounds.height) * (9 / 92))
        let inset = stroke / 2 + 1
        let radius = min(bounds.width, bounds.height) / 2 - inset
        let center = NSPoint(x: bounds.midX, y: bounds.midY)

        let fill = NSBezierPath(ovalIn: NSRect(
            x: center.x - radius - inset,
            y: center.y - radius - inset,
            width: (radius + inset) * 2,
            height: (radius + inset) * 2
        ))
        NSColor(srgbRed: 0.09, green: 0.13, blue: 0.21, alpha: 0.78).setFill()
        fill.fill()

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = stroke
        NSColor.white.withAlphaComponent(0.4).setStroke()
        track.stroke()

        let sweep = max(0, min(1, fraction)) * 359.99
        if sweep > 0 {
            let arc = NSBezierPath()
            arc.lineWidth = stroke
            arc.lineCapStyle = .round
            if started {
                arc.appendArc(
                    withCenter: center,
                    radius: radius,
                    startAngle: 90,
                    endAngle: 90 - sweep,
                    clockwise: true
                )
            } else {
                arc.appendArc(
                    withCenter: center,
                    radius: radius,
                    startAngle: 90 + sweep,
                    endAngle: 90,
                    clockwise: true
                )
            }
            accent.setStroke()
            arc.stroke()
        }

        let fontSize = max(11, min(bounds.width, bounds.height) * (20 / 92))
        let font = NSFont(name: "Avenir Next Demi Bold", size: fontSize)
            ?? .systemFont(ofSize: fontSize, weight: .semibold)
        let text = NSAttributedString(string: label, attributes: [
            .font: font,
            .foregroundColor: accent,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }
}

private final class ResizeGripView: NSView {
    var lineWidth: CGFloat = 2 {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let inset = max(6, bounds.width * 0.28)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.minX + 6, y: bounds.maxY - inset))
        path.line(to: NSPoint(x: bounds.maxX - inset, y: bounds.maxY - inset))
        path.line(to: NSPoint(x: bounds.maxX - inset, y: bounds.minY + 6))
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.white.withAlphaComponent(0.45).setStroke()
        path.stroke()
    }
}
