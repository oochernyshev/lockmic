import SwiftUI

struct PreferencesGeneralPage: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var mic: MicController

    var body: some View {
        VStack(alignment: .leading, spacing: PreferencesChrome.pageSpacing) {
            PreferencesChrome.sectionCard {
                PreferencesChrome.sectionHeader("Anonymous usage")
                Toggle("I agree to share anonymous usage statistics", isOn: $preferences.shareAnonymousUsage)
                PreferencesChrome.caption(
                    "Required to use LockMic. Sends app version and each anonymous action as it happens (toggle, mute/unmute, hold shortcuts). No mic audio or personal data."
                )
                if !preferences.shareAnonymousUsage {
                    Text("Microphone control is disabled until you agree.")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }

            PreferencesChrome.sectionCard {
                PreferencesChrome.sectionHeader("Status")
                PreferencesChrome.statusRow(
                    title: "Microphone",
                    text: statusText,
                    color: statusColor
                )
                PreferencesChrome.gridRow("Device", mic.deviceName)
                if let error = mic.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            PreferencesChrome.sectionCard {
                PreferencesChrome.sectionHeader("Options")
                Group {
                    Toggle("Show on-screen HUD when muting", isOn: $preferences.hudEnabled)
                    PreferencesChrome.caption(
                        "Brief indicator on mute/unmute, and while holding talk / mute / flip."
                    )
                    Toggle("Keep HUD indicator floating", isOn: $preferences.hudFloating)
                    PreferencesChrome.caption(
                        "Always-on indicator · drag to move · click to toggle · right-click to hide per display."
                    )
                    Toggle("Play sound when muting / unmuting", isOn: $preferences.soundEnabled)
                    Toggle("Launch at login", isOn: $preferences.launchAtLogin)
                }
                .disabled(!preferences.featuresEnabled)
                .opacity(preferences.featuresEnabled ? 1 : 0.45)
            }
        }
    }

    private var statusText: String {
        if !preferences.featuresEnabled {
            return "Disabled — agreement required"
        }
        switch mic.state {
        case .muted: return "Muted"
        case .unmuted: return "Unmuted"
        case .unknown: return "Unknown"
        case .unsupported: return "Unsupported device"
        }
    }

    private var statusColor: Color {
        if !preferences.featuresEnabled {
            return .orange
        }
        return PreferencesChrome.statusColor(for: mic.state)
    }
}
