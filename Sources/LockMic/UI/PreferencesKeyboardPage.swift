import SwiftUI

struct PreferencesKeyboardPage: View {
    @ObservedObject var preferences: PreferencesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PreferencesChrome.sectionHeader("Shortcuts")
            Text("Click a field, then press keys · Esc cancels · Delete clears")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !preferences.shortcutConflictMessages.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Shortcut conflicts", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                    ForEach(preferences.shortcutConflictMessages, id: \.self) { message in
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.orange.opacity(0.12))
                )
            }

            PreferencesChrome.shortcutRow(
                title: "Toggle mute",
                enabled: $preferences.toggleShortcutEnabled,
                chord: $preferences.toggleChord
            )
            PreferencesChrome.shortcutRow(
                title: "Mute",
                enabled: $preferences.muteShortcutEnabled,
                chord: $preferences.muteChord
            )
            PreferencesChrome.shortcutRow(
                title: "Unmute",
                enabled: $preferences.unmuteShortcutEnabled,
                chord: $preferences.unmuteChord
            )

            Toggle("Also toggle with ⌘F5", isOn: $preferences.f5ToggleEnabled)
                .focusable(false)
                .focusEffectDisabled()

            Divider().padding(.vertical, 2)

            PreferencesChrome.sectionHeader("Momentary")
            Text("Hold to change mute · release restores previous state")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            PreferencesChrome.shortcutRow(
                title: "Push to flip",
                enabled: $preferences.pushToToggleEnabled,
                chord: $preferences.pushToToggleChord
            )
            PreferencesChrome.shortcutRow(
                title: "Push to talk",
                enabled: $preferences.pushToTalkEnabled,
                chord: $preferences.pushToTalkChord
            )
            PreferencesChrome.shortcutRow(
                title: "Push to mute",
                enabled: $preferences.pushToMuteEnabled,
                chord: $preferences.pushToMuteChord
            )

            HStack {
                Spacer(minLength: 0)
                Button("Reset to Defaults") {
                    preferences.resetShortcutsToDefaults()
                }
                .focusable(false)
                .focusEffectDisabled()
            }
            .padding(.top, 2)
        }
    }
}
