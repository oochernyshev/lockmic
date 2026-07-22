import SwiftUI

struct PreferencesGeneralPage: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var mic: MicController

    var body: some View {
        VStack(alignment: .leading, spacing: PreferencesChrome.pageSpacing) {
            PreferencesChrome.sectionCard {
                PreferencesChrome.sectionHeader("Status")
                PreferencesChrome.statusRow(
                    title: "Microphone",
                    text: statusText,
                    color: PreferencesChrome.statusColor(for: mic.state)
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
        }
    }

    private var statusText: String {
        switch mic.state {
        case .muted: return "Muted"
        case .unmuted: return "Unmuted"
        case .unknown: return "Unknown"
        case .unsupported: return "Unsupported device"
        }
    }
}
