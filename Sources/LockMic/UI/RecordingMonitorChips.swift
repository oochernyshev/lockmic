import AppKit
import QuartzCore

private enum MonitorChipMetrics {
    static let fontSize = NSFont.preferredFont(forTextStyle: .caption1).pointSize
    static let semiboldFont = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
    static let monospacedFont = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
    static let height = max(22, ceil(semiboldFont.ascender - semiboldFont.descender + semiboldFont.leading) + 8)
    static let cornerRadius = height / 2

    static func applyAppearance(to layer: CALayer?) {
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 2
        layer?.shadowOffset = CGSize(width: 0, height: -1)
    }

    static func updateSeparation(of layer: CALayer?, darkMode: Bool) {
        layer?.shadowOpacity = darkMode ? 0.4 : 0.16
        layer?.borderWidth = darkMode ? 0.5 : 0
        layer?.borderColor = darkMode
            ? NSColor.white.withAlphaComponent(0.16).cgColor
            : nil
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

/// Compact pill overlaid on the waveform (status / size / elapsed).
final class MonitorChip: NSView {
    let dotView = NSView()
    let label = NSTextField(labelWithString: "")
    private let showsDot: Bool

    init(title: String, showsDot: Bool, monospaced: Bool = false) {
        self.showsDot = showsDot
        super.init(frame: .zero)
        wantsLayer = true
        MonitorChipMetrics.applyAppearance(to: layer)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: MonitorChipMetrics.height).isActive = true

        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 3.5
        dotView.isHidden = !showsDot
        dotView.translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = title
        label.font = monospaced
            ? MonitorChipMetrics.monospacedFont
            : MonitorChipMetrics.semiboldFont
        label.textColor = .labelColor
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(dotView)
        addSubview(label)
        if showsDot {
            NSLayoutConstraint.activate([
                dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
                dotView.widthAnchor.constraint(equalToConstant: 7),
                dotView.heightAnchor.constraint(equalToConstant: 7),
                label.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 5),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            ])
        } else {
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.82).cgColor
        MonitorChipMetrics.updateSeparation(
            of: layer,
            darkMode: MonitorChipMetrics.isDark(effectiveAppearance)
        )
        if showsDot, dotView.layer?.backgroundColor == nil {
            dotView.layer?.backgroundColor = NSColor.systemRed.cgColor
        }
    }
}

/// Silence mode control: left side toggles, right side cycles the timeout.
final class SilenceModeChip: NSView {
    var onAdvance: (() -> Void)?

    private let dot = NSView()
    private let toggleButton = NSButton(title: L10n.recordingSilenceHeader, target: nil, action: nil)
    private let durationButton = NSButton(title: L10n.recordingSilence30s, target: nil, action: nil)
    private let clickButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        MonitorChipMetrics.applyAppearance(to: layer)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: MonitorChipMetrics.height).isActive = true

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        for button in [toggleButton, durationButton] {
            button.isBordered = false
            button.font = MonitorChipMetrics.semiboldFont
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
        }
        addSubview(dot, positioned: .below, relativeTo: toggleButton)

        clickButton.isBordered = false
        clickButton.title = ""
        clickButton.target = self
        clickButton.action = #selector(advanceClicked)
        clickButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clickButton)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            toggleButton.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 3),
            toggleButton.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            toggleButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            durationButton.leadingAnchor.constraint(equalTo: toggleButton.trailingAnchor, constant: 1),
            durationButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            durationButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clickButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            clickButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            clickButton.topAnchor.constraint(equalTo: topAnchor),
            clickButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        apply(enabled: false, duration: L10n.recordingSilence30s)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(enabled: Bool, duration: String) {
        toggleButton.title = L10n.recordingSilenceHeader
        durationButton.image = nil
        durationButton.title = duration
        dot.layer?.backgroundColor = (enabled ? NSColor.systemGreen : NSColor.secondaryLabelColor).cgColor
        toggleButton.contentTintColor = enabled ? .labelColor : .secondaryLabelColor
        durationButton.contentTintColor = enabled ? .labelColor : .secondaryLabelColor
        toolTip = nil
    }

    func applyCountdown(_ title: String) {
        toggleButton.title = title
        durationButton.title = ""
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        durationButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: L10n.recordingSilenceCancelTooltip
        )?.withSymbolConfiguration(config)
        dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        toggleButton.contentTintColor = .labelColor
        durationButton.contentTintColor = .labelColor
        toolTip = L10n.recordingSilenceCancelTooltip
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.82).cgColor
        MonitorChipMetrics.updateSeparation(
            of: layer,
            darkMode: MonitorChipMetrics.isDark(effectiveAppearance)
        )
    }

    @objc private func advanceClicked() { onAdvance?() }
}
