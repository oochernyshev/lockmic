import SwiftUI

enum PreferencesChrome {
    static func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
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

    static let windowMinSize = CGSize(width: 520, height: 380)
    static let windowIdealSize = CGSize(width: 560, height: 460)
}
