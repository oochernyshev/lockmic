import AppKit

enum RecordingMonitorChrome {
    /// Solid enough to read on the HUD-glass window.
    static var blockFill: NSColor {
        NSColor.windowBackgroundColor.withAlphaComponent(0.88)
    }

    static var blockStroke: NSColor {
        NSColor.labelColor.withAlphaComponent(0.14)
    }
}

private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// Preferences-style inset card (fill + hairline + 10pt corner).
final class CardView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let header = NSStackView()
    private let rows = NSStackView()
    private let scroller = NSScrollView()
    private let bodyStack = NSStackView()
    private var scrollerHeight: NSLayoutConstraint?
    private var leadingAccessory: NSView?
    private var accessory: NSView?
    private var maxVisibleRows: Int?

    convenience init(maxVisibleRows: Int? = nil) {
        self.init(frame: .zero)
        self.maxVisibleRows = maxVisibleRows
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = PreferencesChrome.cardCornerRadius
        layer?.borderWidth = 1

        titleField.font = .systemFont(ofSize: 12, weight: .semibold)
        titleField.textColor = .secondaryLabelColor
        titleField.alignment = .left
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.addArrangedSubview(titleField)
        header.addArrangedSubview(spacer)

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false

        let clip = FlippedClipView()
        clip.drawsBackground = false
        scroller.contentView = clip
        scroller.drawsBackground = false
        scroller.backgroundColor = .clear
        scroller.borderType = .noBorder
        scroller.hasHorizontalScroller = false
        scroller.hasVerticalScroller = false
        scroller.autohidesScrollers = true
        scroller.scrollerStyle = .overlay
        scroller.automaticallyAdjustsContentInsets = false
        scroller.contentInsets = NSEdgeInsets()
        scroller.documentView = rows
        let verticalScroller = ThinTransparentScroller()
        verticalScroller.controlSize = .regular
        scroller.verticalScroller = verticalScroller
        let height = scroller.heightAnchor.constraint(equalToConstant: 0)
        height.priority = .required
        scrollerHeight = height

        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = PreferencesChrome.contentSpacing
        bodyStack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        bodyStack.addArrangedSubview(header)
        bodyStack.addArrangedSubview(scroller)
        addSubview(bodyStack)
        NSLayoutConstraint.activate([
            bodyStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            bodyStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            bodyStack.topAnchor.constraint(equalTo: topAnchor),
            bodyStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: bodyStack.widthAnchor, constant: -28),
            scroller.widthAnchor.constraint(equalTo: bodyStack.widthAnchor, constant: -28),
            height,
            rows.topAnchor.constraint(equalTo: clip.topAnchor),
            rows.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            rows.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = RecordingMonitorChrome.blockFill.cgColor
        layer?.borderColor = RecordingMonitorChrome.blockStroke.cgColor
    }

    func setTitle(_ title: String) {
        titleField.stringValue = title
    }

    func setHeaderHidden(_ hidden: Bool) {
        header.isHidden = hidden
        bodyStack.setCustomSpacing(hidden ? 0 : PreferencesChrome.contentSpacing, after: header)
    }

    func setBodyInsets(_ insets: NSEdgeInsets) {
        bodyStack.edgeInsets = insets
    }

    func setLeadingAccessory(_ view: NSView?) {
        if let leadingAccessory {
            header.removeArrangedSubview(leadingAccessory)
            leadingAccessory.removeFromSuperview()
        }
        leadingAccessory = view
        if let view {
            header.insertArrangedSubview(view, at: 0)
        }
    }

    func setAccessory(_ view: NSView?) {
        if let accessory {
            header.removeArrangedSubview(accessory)
            accessory.removeFromSuperview()
        }
        accessory = view
        if let view {
            header.addArrangedSubview(view)
        }
    }

    func removeRows() {
        rows.arrangedSubviews.forEach {
            rows.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        refreshScrolling()
    }

    func addRow(_ row: NSView) {
        if !rows.arrangedSubviews.isEmpty {
            let line = NSBox()
            line.boxType = .separator
            rows.addArrangedSubview(line)
        }
        rows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        refreshScrolling()
    }

    func refreshScrolling() {
        layoutSubtreeIfNeeded()
        let count = rows.arrangedSubviews.filter { !($0 is NSBox) }.count
        let shouldScroll = maxVisibleRows.map { count > $0 } ?? false
        scroller.hasVerticalScroller = shouldScroll
        scroller.verticalScrollElasticity = shouldScroll ? .automatic : .none
        let height: CGFloat
        if shouldScroll, let limit = maxVisibleRows {
            height = heightOfVisibleRows(limit)
        } else {
            height = max(rows.fittingSize.height, 0)
        }
        if let scrollerHeight, abs(scrollerHeight.constant - height) > 0.5 {
            scrollerHeight.constant = height
        }
    }

    private func heightOfVisibleRows(_ limit: Int) -> CGFloat {
        var height: CGFloat = 0
        var devices = 0
        for view in rows.arrangedSubviews {
            if view is NSBox {
                if devices > 0, devices < limit {
                    height += max(view.fittingSize.height, 1)
                }
                continue
            }
            devices += 1
            if devices <= limit {
                let rowHeight = view.fittingSize.height
                height += rowHeight > 1 ? rowHeight : view.intrinsicContentSize.height
            }
        }
        return height
    }

    func setDimmed(_ dimmed: Bool) {
        alphaValue = dimmed ? 0.42 : 1
    }
}
