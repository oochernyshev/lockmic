import SwiftUI

struct PreferencesGeneralPage: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var mic: MicController

    var body: some View {
        VStack(alignment: .leading, spacing: PreferencesChrome.pageSpacing) {
            PreferencesChrome.sectionCard {
                PreferencesChrome.sectionHeader(L10n.generalAnonymousHeader)
                Toggle(L10n.generalAnonymousToggle, isOn: $preferences.shareAnonymousUsage)
                PreferencesChrome.caption(L10n.generalAnonymousCaption)
                if !preferences.shareAnonymousUsage {
                    Text(L10n.generalAnonymousDisabled)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }

            PreferencesChrome.sectionCard {
                PreferencesChrome.sectionHeader(L10n.generalStatusHeader)
                PreferencesChrome.statusRow(
                    title: L10n.generalStatusMicrophone,
                    text: statusText,
                    color: statusColor
                )
                PreferencesChrome.gridRow(L10n.generalStatusDevice, mic.deviceName)
                if let error = mic.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            PreferencesChrome.sectionCard {
                PreferencesChrome.sectionHeader(L10n.generalOptionsHeader)
                Group {
                    Toggle(L10n.generalOptionsHUD, isOn: $preferences.hudEnabled)
                    PreferencesChrome.caption(L10n.generalOptionsHUDCaption)
                    Toggle(L10n.generalOptionsFloating, isOn: $preferences.hudFloating)
                    PreferencesChrome.caption(L10n.generalOptionsFloatingCaption)
                    Toggle(L10n.generalOptionsSound, isOn: $preferences.soundEnabled)
                    Toggle(L10n.generalOptionsLogin, isOn: $preferences.launchAtLogin)
                }
                .disabled(!preferences.featuresEnabled)
                .opacity(preferences.featuresEnabled ? 1 : 0.45)
            }
        }
    }

    private var statusText: String {
        if !preferences.featuresEnabled {
            return L10n.generalStatusDisabled
        }
        switch mic.state {
        case .muted: return L10n.generalStatusMuted
        case .unmuted: return L10n.generalStatusUnmuted
        case .unknown: return L10n.generalStatusUnknown
        case .unsupported: return L10n.generalStatusUnsupported
        }
    }

    private var statusColor: Color {
        if !preferences.featuresEnabled {
            return .orange
        }
        return PreferencesChrome.statusColor(for: mic.state)
    }
}
