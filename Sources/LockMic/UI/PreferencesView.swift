import SwiftUI

struct PreferencesView: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var mic: MicController

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Microphone") {
                    Text(statusText)
                }
                LabeledContent("Device") {
                    Text(mic.deviceName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let error = mic.lastError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            Section("General") {
                Toggle("Show on-screen HUD when muting", isOn: $preferences.hudEnabled)
                Toggle("Launch at login", isOn: $preferences.launchAtLogin)
            }

            Section("Devices") {
                Toggle("Mute all input devices", isOn: $preferences.muteAllInputs)
                    .onChange(of: preferences.muteAllInputs) { _, _ in
                        mic.preferenceMuteScopeChanged()
                    }
                Text(
                    preferences.muteAllInputs
                        ? "Mutes every microphone Core Audio can see (recommended). Safer when Zoom/Teams picks a non-default mic."
                        : "Only mutes the system default input (System Settings → Sound → Input)."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Keyboard") {
                LabeledContent("Toggle mute") {
                    Text(preferences.hotkeyDisplayString)
                        .font(.body.monospaced())
                }
                Text("Defaults: ⌘⇧M and ⌘F5. Note: macOS may also use ⌘F5 for VoiceOver — disable that in Keyboard shortcuts if they conflict.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                }
                Text("LockMic mutes your input at the system level so it works in every app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 440)
        .padding()
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
