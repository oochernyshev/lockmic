import AppKit

/// Brief non-activating floating HUD for mute state changes.
@MainActor
final class HUDOverlay {
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    func show(muted: Bool, deviceName: String) {
        hideWorkItem?.cancel()

        let panel = ensurePanel()
        if let hosting = panel.contentView as? HUDContentView {
            hosting.configure(muted: muted, deviceName: deviceName)
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25, execute: work)
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let size = NSSize(width: 220, height: 96)
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentView = HUDContentView(frame: NSRect(origin: .zero, size: size))

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2 + 40
            )
            panel.setFrameOrigin(origin)
        }

        self.panel = panel
        return panel
    }
}

private final class HUDContentView: NSView {
    private let iconLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let blur = NSVisualEffectView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true

        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.frame = bounds
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)

        iconLabel.font = .systemFont(ofSize: 28)
        iconLabel.alignment = .center
        iconLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconLabel)
        addSubview(titleLabel)
        addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            iconLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            iconLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: iconLabel.bottomAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(muted: Bool, deviceName: String) {
        iconLabel.stringValue = muted ? "🔇" : "🎤"
        titleLabel.stringValue = muted ? "Microphone Muted" : "Microphone On"
        subtitleLabel.stringValue = deviceName
    }
}
