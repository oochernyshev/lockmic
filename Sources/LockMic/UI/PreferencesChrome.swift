import SwiftUI

enum PreferencesChrome {
    /// Vertical gap between section cards on a preferences page.
    static let pageSpacing: CGFloat = 12
    /// Internal spacing inside a section card.
    static let contentSpacing: CGFloat = 10
    /// Corner radius for section cards and inset lists.
    static let cardCornerRadius: CGFloat = 10

    static let windowMinSize = CGSize(width: 520, height: 380)
    static let windowIdealSize = CGSize(width: 560, height: 460)

    static func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
    }

    /// System Settings–style inset card.
    static func sectionCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: contentSpacing) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    /// Soft caption under a control.
    static func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func gridRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    /// Status value with a colored live indicator.
    static func statusRow(title: String, text: String, color: Color) -> some View {
        HStack(alignment: .center) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            statusBadge(text: text, color: color)
        }
    }

    static func statusBadge(text: String, color: Color, compact: Bool = false) -> some View {
        HStack(spacing: compact ? 5 : 6) {
            Circle()
                .fill(color)
                .frame(width: compact ? 6 : 7, height: compact ? 6 : 7)
            // Primary label (not pure green/orange) stays readable on dark wallpapers.
            Text(text)
                .font(compact ? .caption.weight(.semibold) : .body.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, compact ? 7 : 9)
        .padding(.vertical, compact ? 3 : 4)
        .background(color.opacity(compact ? 0.18 : 0.14))
        .clipShape(Capsule())
    }

    static func statusColor(for state: MicState) -> Color {
        switch state {
        case .muted: return .orange
        case .unmuted: return .green
        case .unknown: return .secondary
        case .unsupported: return .red
        }
    }

    static func shortcutRow(
        title: String,
        enabled: Binding<Bool>,
        chord: Binding<HotkeyChord>
    ) -> some View {
        HStack(spacing: 10) {
            Toggle(title, isOn: enabled)
                .toggleStyle(.checkbox)
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusable(false)
                .focusEffectDisabled()

            HotkeyRecorderButton(chord: chord, isEnabled: enabled.wrappedValue)
        }
    }
}


