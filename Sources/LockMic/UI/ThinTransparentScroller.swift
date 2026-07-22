import AppKit
import SwiftUI

/// Narrow, semi-transparent overlay scroller used in preferences.
///
/// AppKit often lays out overlay scrollers at ~1–3pt; we force a usable width
/// and draw a fixed-width rounded knob so it never collapses to a hairline.
final class ThinTransparentScroller: NSScroller {
    /// Hit/layout width of the scroller track area.
    static let trackWidth: CGFloat = 10
    /// Visible pill width (centered in the track).
    static let knobWidth: CGFloat = 5

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(
        for controlSize: NSControl.ControlSize,
        scrollerStyle: NSScroller.Style
    ) -> CGFloat {
        trackWidth
    }

    /// Grow the frame when AppKit assigns a too-narrow strip (common with overlay style).
    override var frame: NSRect {
        get { super.frame }
        set {
            var f = newValue
            // Prefer orientation from the incoming frame; fall back to current bounds.
            let vertical = f.height >= f.width || (f.width == 0 && bounds.height >= bounds.width)
            if vertical {
                if f.width < Self.trackWidth {
                    let delta = Self.trackWidth - f.width
                    // Vertical scroller sits on the trailing edge — expand leftward.
                    f.origin.x -= delta
                    f.size.width = Self.trackWidth
                }
            } else if f.height < Self.trackWidth {
                let delta = Self.trackWidth - f.height
                f.origin.y -= delta
                f.size.height = Self.trackWidth
            }
            super.frame = f
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        if size.height >= size.width {
            size.width = max(size.width, Self.trackWidth)
        } else {
            size.height = max(size.height, Self.trackWidth)
        }
        super.setFrameSize(size)
    }

    private var isVertical: Bool {
        bounds.height >= bounds.width
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // No track fill — transparent gutter.
    }

    override func draw(_ dirtyRect: NSRect) {
        // Skip system chrome; draw only our knob.
        drawKnob()
    }

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard knob.height > 0 || knob.width > 0 else { return }

        let opacity: CGFloat = isHighlighted ? 0.58 : 0.38
        let color = NSColor.labelColor.withAlphaComponent(opacity)

        let drawRect: NSRect
        if isVertical {
            let width = Self.knobWidth
            let height = max(knob.height - 4, 18)
            let x = bounds.midX - width / 2
            let y = knob.midY - height / 2
            drawRect = NSRect(x: x, y: y, width: width, height: height)
        } else {
            let height = Self.knobWidth
            let width = max(knob.width - 4, 18)
            let y = bounds.midY - height / 2
            let x = knob.midX - width / 2
            drawRect = NSRect(x: x, y: y, width: width, height: height)
        }

        let radius = min(drawRect.width, drawRect.height) / 2
        let path = NSBezierPath(roundedRect: drawRect, xRadius: radius, yRadius: radius)
        color.setFill()
        path.fill()
    }
}

/// Installs thin overlay scrollers on the nearest enclosing `NSScrollView`.
struct ThinScrollIndicatorsInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        InstallerView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? InstallerView)?.installIfNeeded()
    }

    private final class InstallerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Defer so SwiftUI finishes wiring the NSScrollView hierarchy.
            DispatchQueue.main.async { [weak self] in
                self?.installIfNeeded()
            }
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            DispatchQueue.main.async { [weak self] in
                self?.installIfNeeded()
            }
        }

        override func layout() {
            super.layout()
            installIfNeeded()
        }

        func installIfNeeded() {
            guard let scrollView = findScrollView() else { return }
            applyThinScrollers(to: scrollView)
        }

        private func applyThinScrollers(to scrollView: NSScrollView) {
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
            scrollView.scrollerKnobStyle = .default

            if !(scrollView.verticalScroller is ThinTransparentScroller) {
                let scroller = ThinTransparentScroller()
                scroller.controlSize = .regular
                scrollView.verticalScroller = scroller
            }
            if !(scrollView.horizontalScroller is ThinTransparentScroller) {
                let scroller = ThinTransparentScroller()
                scroller.controlSize = .regular
                scrollView.horizontalScroller = scroller
            }

            scrollView.verticalScroller?.scrollerStyle = .overlay
            scrollView.horizontalScroller?.scrollerStyle = .overlay
        }

        private func findScrollView() -> NSScrollView? {
            if let enclosing = enclosingScrollView {
                return enclosing
            }
            var ancestor: NSView? = superview
            while let view = ancestor {
                if let scroll = view as? NSScrollView {
                    return scroll
                }
                if let scroll = view.subviews.compactMap({ $0 as? NSScrollView }).first {
                    return scroll
                }
                if let scroll = findScrollView(in: view) {
                    return scroll
                }
                ancestor = view.superview
            }
            if let content = window?.contentView {
                return findScrollView(in: content)
            }
            return nil
        }

        private func findScrollView(in root: NSView) -> NSScrollView? {
            if let scroll = root as? NSScrollView { return scroll }
            for child in root.subviews {
                if let found = findScrollView(in: child) { return found }
            }
            return nil
        }
    }
}

extension View {
    /// Applies a narrow, semi-transparent overlay scrollbar to the enclosing SwiftUI `ScrollView`.
    func thinScrollIndicators() -> some View {
        background(ThinScrollIndicatorsInstaller())
    }
}
