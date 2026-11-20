import AppKit
import SwiftUI

/// Non-interactive rendering of the real meeting alert card, so Preferences shows
/// exactly what will appear on screen. Uses sample data only.
struct MeetingAlertPreview: View {
    let soundEnabled: Bool

    private static let inset: CGFloat = 16

    var body: some View {
        let fullWidth = MeetingAlertLogic.cardWidth + Self.inset * 2
        let fullHeight = MeetingAlertLogic.cardHeight + Self.inset * 2
        // Shrink the card to whatever width the settings page gives it.
        GeometryReader { proxy in
            let scale = min(1, proxy.size.width / fullWidth)
            CardRepresentable(soundEnabled: soundEnabled)
                .frame(width: MeetingAlertLogic.cardWidth, height: MeetingAlertLogic.cardHeight)
                .scaleEffect(scale)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(fullWidth / fullHeight, contentMode: .fit)
        .frame(maxWidth: fullWidth)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct CardRepresentable: NSViewRepresentable {
        let soundEnabled: Bool

        func makeNSView(context: Context) -> MeetingAlertCardView {
            let card = MeetingAlertCardView(frame: NSRect(
                x: 0, y: 0,
                width: MeetingAlertLogic.cardWidth,
                height: MeetingAlertLogic.cardHeight
            ))
            card.apply(snapshot, scale: 1)
            return card
        }

        func updateNSView(_ card: MeetingAlertCardView, context: Context) {
            card.apply(snapshot, scale: 1)
        }

        private var snapshot: MeetingAlertSnapshot {
            MeetingAlertSnapshot(
                title: "",
                start: Date().timeIntervalSince1970 + 120,
                remaining: 120,
                duration: 120,
                soundEnabled: soundEnabled
            )
        }
    }
}
