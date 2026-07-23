import SwiftUI

struct PreferencesKeyboardPage: View {
    @ObservedObject var preferences: PreferencesStore

    var body: some View {
        VStack(alignment: .leading, spacing: PreferencesChrome.pageSpacing) {
            PreferencesChrome.sectionCard {
                PreferencesChrome.sectionHeader(L10n.keyboardShortcutsHeader)
                PreferencesChrome.caption(L10n.keyboardShortcutsCaption)

                if !preferences.shortcutConflictMessages.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(L10n.keyboardConflicts, systemImage: "exclamationmark.triangle.fill")
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
                    title: L10n.keyboardToggle,
                    enabled: $preferences.toggleShortcutEnabled,
                    chord: $preferences.toggleChord
                )
                PreferencesChrome.shortcutRow(
                    title: L10n.keyboardMute,
                    enabled: $preferences.muteShortcutEnabled,
                    chord: $preferences.muteChord
                )
                PreferencesChrome.shortcutRow(
                    title: L10n.keyboardUnmute,
                    enabled: $preferences.unmuteShortcutEnabled,
                    chord: $preferences.unmuteChord
                )

                Toggle(L10n.keyboardF5, isOn: $preferences.f5ToggleEnabled)
                    .focusable(false)
                    .focusEffectDisabled()
            }

            PreferencesChrome.sectionCard {
                PreferencesChrome.sectionHeader(L10n.keyboardMomentaryHeader)
                PreferencesChrome.caption(L10n.keyboardMomentaryCaption)

                PreferencesChrome.shortcutRow(
                    title: L10n.keyboardPushFlip,
                    enabled: $preferences.pushToToggleEnabled,
                    chord: $preferences.pushToToggleChord
                )
                PreferencesChrome.shortcutRow(
                    title: L10n.keyboardPushTalk,
                    enabled: $preferences.pushToTalkEnabled,
                    chord: $preferences.pushToTalkChord
                )
                PreferencesChrome.shortcutRow(
                    title: L10n.keyboardPushMute,
                    enabled: $preferences.pushToMuteEnabled,
                    chord: $preferences.pushToMuteChord
                )

                HStack {
                    Spacer(minLength: 0)
                    Button(L10n.keyboardReset) {
                        preferences.resetShortcutsToDefaults()
                    }
                    .focusable(false)
                    .focusEffectDisabled()
                }
                .padding(.top, 2)
            }
        }
    }
}
