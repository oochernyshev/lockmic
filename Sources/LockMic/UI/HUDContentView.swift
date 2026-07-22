import AppKit

/// Visual content + drag/click handling for one HUD panel.
final class HUDContentView: NSView {
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

    func configureToast(muted: Bool, hold: HUDHoldKind = .none) {
        let name = muted ? "mic.slash.fill" : "mic.fill"
        let config = NSImage.SymbolConfiguration(pointSize: 58, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        iconView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        iconView.contentTintColor = .white

        if let holdCaption = hold.caption {
            captionLabel.stringValue = holdCaption
        } else {
            captionLabel.stringValue = muted ? "Muted" : "Unmuted"
        }

        let holding = hold != .none
        backdrop.layer?.backgroundColor = muted
            ? NSColor.black.withAlphaComponent(holding ? 0.72 : 0.62).cgColor
            : NSColor.black.withAlphaComponent(holding ? 0.60 : 0.50).cgColor
        if holding {
            backdrop.layer?.borderWidth = 2
            backdrop.layer?.borderColor = NSColor.white.withAlphaComponent(0.45).cgColor
        } else {
            backdrop.layer?.borderWidth = 0
            backdrop.layer?.borderColor = nil
        }

        if isInteractive {
            toolTip = "Click to toggle · drag to move · right-click to hide"
        } else if holding {
            toolTip = "Key held — release to restore"
        } else {
            toolTip = nil
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        if isInteractive {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

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
