import AppKit
import SwiftUI

/// Non-interactive rendering of the real meeting alert card, so Preferences shows
/// exactly what will appear on screen. Uses sample data only.
struct MeetingAlertPreview: View {
    let soundEnabled: Bool

    private static let scale: CGFloat = 0.8

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.22, blue: 0.38), Color(red: 0.30, green: 0.20, blue: 0.38)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            CardRepresentable(soundEnabled: soundEnabled)
                .frame(width: MeetingAlertLogic.cardWidth, height: MeetingAlertLogic.cardHeight)
                .scaleEffect(Self.scale)
                .frame(
                    width: MeetingAlertLogic.cardWidth * Self.scale,
                    height: MeetingAlertLogic.cardHeight * Self.scale
                )
        }
        .frame(maxWidth: .infinity)
        .frame(height: MeetingAlertLogic.cardHeight * Self.scale + 32)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.35), lineWidth: 0.5))
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
