import SwiftUI

struct PreferencesGeneralPage: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var mic: MicController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PreferencesChrome.sectionHeader("Status")
            PreferencesChrome.gridRow("Microphone", statusText)
            PreferencesChrome.gridRow("Device", mic.deviceName)
            if let error = mic.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider().padding(.vertical, 2)

            PreferencesChrome.sectionHeader("Options")
            Toggle("Show on-screen HUD when muting", isOn: $preferences.hudEnabled)
            Text("Brief indicator on mute/unmute, and while holding talk / mute / flip.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Keep HUD indicator floating", isOn: $preferences.hudFloating)
            Text("Always-on indicator · drag to move · click to toggle · right-click to hide per display.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Play sound when muting / unmuting", isOn: $preferences.soundEnabled)
            Toggle("Launch at login", isOn: $preferences.launchAtLogin)
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
