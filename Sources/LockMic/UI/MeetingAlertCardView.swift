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
    private var mouseDownScreenPoint: NSPoint?
    private var windowOriginAtDown: NSPoint?
    private var dragging = false
    private var resizing = false
    private var resizeStartScale: CGFloat = 1
    private var resizeStartSize = NSSize.zero
    private var resizeStartMouse = NSPoint.zero
    private let dragThreshold: CGFloat = 4

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Self.corner
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        appearance = NSAppearance(named: .darkAqua)

        glassHost.wantsLayer = true
        addSubview(glassHost)
        installGlass()

        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(srgbRed: 0.09, green: 0.13, blue: 0.21, alpha: 0.46).cgColor
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
        let phase = MeetingAlertLogic.phase(remaining: snapshot.remaining)
        let accent: NSColor = phase == .upcoming ? Self.yellow : Self.red
        let status: String
        switch phase {
        case .upcoming: status = L10n.meetingStatusUpcoming
        case .soon: status = L10n.meetingStatusSoon
        case .now: status = L10n.meetingStatusNow
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
        for sub in glassHost.subviews {
            sub.frame = glassHost.bounds
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
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if resizeMark.frame.contains(local) {
            resizing = true
            dragging = false
            resizeStartScale = scale
            resizeStartSize = window?.frame.size ?? bounds.size
            resizeStartMouse = NSEvent.mouseLocation
            return
        }
        if soundButton.frame.contains(local)
            || snoozeButton.frame.contains(local)
            || okButton.frame.contains(local)
        {
            super.mouseDown(with: event)
            return
        }
        resizing = false
        dragging = false
        mouseDownScreenPoint = NSEvent.mouseLocation
        windowOriginAtDown = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        if resizing {
            let mouse = NSEvent.mouseLocation
            let dw = mouse.x - resizeStartMouse.x
            let dh = -(mouse.y - resizeStartMouse.y)
            let next: CGFloat
            if abs(dw) >= abs(dh) {
                next = (resizeStartSize.width + dw) / MeetingAlertLogic.cardWidth
            } else {
                let height = max(1, resizeStartSize.height)
                next = resizeStartScale * (height + dh) / height
            }
            let clamped = min(MeetingAlertLogic.scaleMax, max(MeetingAlertLogic.scaleMin, next))
            if abs(clamped - scale) >= 0.005 {
                onScaleChanged?(clamped)
            }
            return
        }
        guard let mouseDownScreenPoint, let windowOriginAtDown, let window else { return }
        let now = NSEvent.mouseLocation
        let delta = NSPoint(
            x: now.x - mouseDownScreenPoint.x,
            y: now.y - mouseDownScreenPoint.y
        )
        if !dragging && hypot(delta.x, delta.y) < dragThreshold { return }
        dragging = true
        var origin = NSPoint(
            x: windowOriginAtDown.x + delta.x,
            y: windowOriginAtDown.y + delta.y
        )
        origin = Self.clampedOrigin(origin, size: window.frame.size)
        window.setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        if resizing {
            resizing = false
            onDragEnded?()
            return
        }
        let wasDragging = dragging
        dragging = false
        mouseDownScreenPoint = nil
        windowOriginAtDown = nil
        if wasDragging {
            onDragEnded?()
            return
        }
        super.mouseUp(with: event)
    }

    static func clampedOrigin(_ origin: NSPoint, size: NSSize) -> NSPoint {
        let probe = NSPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        let screen = NSScreen.screens.first { NSMouseInRect(probe, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let bounds = screen?.visibleFrame else { return origin }
        let margin: CGFloat = 48
        let x = min(max(origin.x, bounds.minX - size.width + margin), bounds.maxX - margin)
        let y = min(max(origin.y, bounds.minY), bounds.maxY - margin)
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

private final class MeetingCardButton: NSButton {
    var corner: CGFloat = 10 {
        didSet { layer?.cornerRadius = corner }
    }
    var fontSize: CGFloat = 20 {
        didSet { font = .systemFont(ofSize: fontSize, weight: .medium) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .regularSquare
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 10
        focusRingType = .none
        font = .systemFont(ofSize: 20, weight: .medium)
        setButtonType(.momentaryChange)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setTitle(_ title: String, color: NSColor, fill: NSColor) {
        image = nil
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: color,
        ])
        layer?.backgroundColor = fill.cgColor
        contentTintColor = color
    }

    func setSound(on: Bool, scale: CGFloat) {
        attributedTitle = NSAttributedString()
        let config = NSImage.SymbolConfiguration(pointSize: 18 * scale, weight: .medium)
        let name = on ? "speaker.wave.2.fill" : "speaker.slash.fill"
        image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        imagePosition = .imageOnly
        contentTintColor = on ? .white : NSColor.white.withAlphaComponent(0.55)
        layer?.backgroundColor = NSColor.white.withAlphaComponent(on ? 0.12 : 0.08).cgColor
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
        NSColor.white.withAlphaComponent(0.16).setStroke()
        track.stroke()

        let sweep = max(0, min(1, fraction)) * 359.99
        if sweep >= 1 {
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
