import AppKit
import ApplicationServices
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var mic: MicController
    let testMute: () -> Void
    @ObservedObject var meetings: MeetingAlertCoordinator
    let finish: () -> Void

    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                ForEach(0..<6, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.22))
                        .frame(width: index == page ? 28 : 8, height: 8)
                        .animation(.easeInOut(duration: 0.2), value: page)
                }
            }
            .padding(.top, 22)

            Group {
                switch page {
                case 0: welcomePage
                case 1: analyticsPage
                case 2: hudPage
                case 3: syncPage
                case 4: alertsPage
                default: readyPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                if page > 0 {
                    Button("Back") { page -= 1 }
                }
                Spacer()
                if page == 0 {
                    Button("Continue") { page = 1 }
                        .keyboardShortcut(.defaultAction)
                } else if page == 1 {
                    Button("Agree & Continue") {
                        preferences.shareAnonymousUsage = true
                        page = 2
                    }
                        .keyboardShortcut(.defaultAction)
                } else if page >= 2 && page <= 4 {
                    Button("Continue") { page += 1 }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Start Using LockMic") {
                        preferences.hasCompletedOnboarding = true
                        finish()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .frame(width: 620, height: 660)
        .background(.ultraThinMaterial)
        .onChange(of: page) { old, new in
            // Leaving the Sync page with any sync switched on: ask for Accessibility now.
            let syncPage = 3
            if old == syncPage, new != syncPage,
               preferences.syncWebEnabled || preferences.syncTeamsAppEnabled || preferences.syncZoomAppEnabled {
                AccessibilityPrompt.requestNow()
            }
            // Leaving the Alerts page with the countdown on: ask for Calendar access now.
            let alertsPage = 4
            if old == alertsPage, new != alertsPage,
               preferences.meetingAlertsEnabled, meetings.access == .notDetermined {
                meetings.requestAccessAndEnable()
            }
        }
    }

    private var welcomePage: some View {
        VStack(spacing: 20) {
            PreferencesAppIcon(size: 92, muted: true)
            VStack(spacing: 8) {
                Text("Welcome to LockMic")
                    .font(.system(size: 28, weight: .bold))
                Text("One mute control for your whole Mac")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                onboardingFeature("mic.slash.fill", "Mute every controllable microphone at once")
                onboardingFeature("arrow.left.arrow.right", "Stay in sync with Meet, Teams and Zoom, both ways")
                onboardingFeature("keyboard", "Use global shortcuts from any app")
                onboardingFeature("waveform", "Record microphone and system audio when you need it")
            }
            .frame(maxWidth: 410, alignment: .leading)
        }
        .padding(36)
    }

    private var analyticsPage: some View {
        VStack(spacing: 14) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(.tint)
            Text("Free, supported by anonymous analytics")
                .font(.system(size: 25, weight: .bold))
            Text("LockMic is free because anonymous usage data helps us understand which features matter and where the app needs improvement. Sharing it is required to use LockMic.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 470)

            VStack(alignment: .leading, spacing: 10) {
                Label("Shared: a random anonymous install ID, app and macOS versions, language, HUD mode, and actions such as mute or recording start and stop", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.primary)
                Label("Never shared: microphone audio, recordings, filenames, device names, or personal information", systemImage: "lock.shield.fill")
                    .foregroundStyle(.primary)
            }
            .font(.callout)
            .frame(maxWidth: 470, alignment: .leading)
            .padding(16)
            .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))

            Link("Read the Privacy Policy", destination: URL(string: "https://lockmic.com/privacy.html")!)
                .font(.callout)

        }
        .padding(26)
    }

    private var readyPage: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 42))
                .foregroundStyle(.green)
            VStack(spacing: 4) {
                Text("You’re ready")
                    .font(.system(size: 24, weight: .bold))
                Text("LockMic lives in your menu bar. Start with these controls:")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                controlRow(icon: "mic.slash.fill", title: "Toggle mute", detail: "Click the menu-bar microphone or press", shortcut: "⇧⌘M")
                controlRow(icon: "hand.tap.fill", title: "Momentary control", detail: "Hold to invert mute, then release", shortcut: "⌥Space")
                controlRow(icon: "record.circle", title: "Start recording", detail: "Record from anywhere with", shortcut: "⇧⌘R")
            }
            .frame(maxWidth: 470)

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Show LockMic in the Dock", isOn: $preferences.showInDock)
                    .toggleStyle(.checkbox)
                    .fontWeight(.medium)
                Text("LockMic normally lives in the menu bar. You can change this later in Preferences → General.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 446, alignment: .leading)
            .padding(10)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))

            Text("Right-click the menu-bar icon for recording and Preferences. You can reopen this guide from Preferences → General.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var hudPage: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text("Meet the HUD")
                    .font(.system(size: 24, weight: .bold))
                Text("A Heads-Up Display keeps your microphone status visible on screen.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.88, green: 0.94, blue: 0.96),
                             Color(red: 0.63, green: 0.76, blue: 0.79)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                OnboardingHUDPreview(muted: mic.effectiveMuted)
                    .frame(width: 156, height: 156)
                Button(action: testMute) {
                    Color.clear
                        .frame(width: 140, height: 140)
                        .contentShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(mic.effectiveMuted ? "Click to test unmute" : "Click to test mute")
                .accessibilityLabel(mic.effectiveMuted ? "Test unmute" : "Test mute")
            }
            .frame(width: 310, height: 176)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.18))
            }
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)

            Label("Try it now—click the HUD to mute or unmute", systemImage: "hand.tap.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Show on-screen HUD when muting", isOn: $preferences.hudEnabled)
                    .toggleStyle(.checkbox)
                Toggle("Keep HUD indicator floating", isOn: $preferences.hudFloating)
                    .toggleStyle(.checkbox)

                Text("You can change these options anytime in Preferences → General.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "display.2")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Place it anywhere")
                            .font(.callout.weight(.semibold))
                        Text("Drag the floating HUD to move it. Right-click to hide it on that monitor, or manage each display from the menu-bar icon → Floating HUD.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: 520)
            .padding(12)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(14)
    }

    private var alertsPage: some View {
        VStack(spacing: 12) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.tint)
            VStack(spacing: 4) {
                Text("Never walk into a meeting live")
                    .font(.system(size: 24, weight: .bold))
                Text("Two minutes before a calendar event, a floating countdown card reminds you to check your microphone.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 470)
            }

            MeetingAlertPreview(soundEnabled: preferences.meetingAlertSoundEnabled)
                .frame(maxWidth: 360)

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Show meeting countdown", isOn: $preferences.meetingAlertsEnabled)
                .toggleStyle(.checkbox)
                .fontWeight(.medium)
                Toggle("Play an alert sound near the start", isOn: $preferences.meetingAlertSoundEnabled)
                    .toggleStyle(.checkbox)
                    .disabled(!preferences.meetingAlertsEnabled)
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(12)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 6) {
                Label("LockMic reads event titles and start times on this Mac and uploads nothing.", systemImage: "lock.shield.fill")
                Label("You can change this anytime in Preferences → Alerts.", systemImage: "gearshape.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 520, alignment: .leading)

            CalendarAccessRow(meetings: meetings)
                .frame(maxWidth: 520)
        }
        .padding(14)
    }

    private var syncPage: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.left.arrow.right.circle.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.tint)
            VStack(spacing: 4) {
                Text("Keep your calls in sync")
                    .font(.system(size: 24, weight: .bold))
                Text("Mute in LockMic and the call mutes. Mute in the call and LockMic follows, both ways, within a second.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 470)
            }

            VStack(alignment: .leading, spacing: 10) {
                syncOption(
                    "Web calls",
                    detail: "Google Meet, Microsoft Teams and Zoom in your browser. Safari: calls in every tab. Chrome and other Chromium browsers: the tab that is open and visible in its window.",
                    isOn: $preferences.syncWebEnabled
                )
                Divider()
                syncOption(
                    "Microsoft Teams app",
                    detail: "Follows mute in the Teams desktop app.",
                    isOn: $preferences.syncTeamsAppEnabled
                )
                Divider()
                syncOption(
                    "Zoom app",
                    detail: "Follows mute in the Zoom desktop app.",
                    isOn: $preferences.syncZoomAppEnabled
                )
            }
            .frame(maxWidth: 520)
            .padding(12)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 6) {
                Label("LockMic only reads each call's mute button and the page address needed to find it, never audio or what is on the page.", systemImage: "lock.shield.fill")
                Label("You can change these anytime in Preferences → Sync.", systemImage: "gearshape.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 520, alignment: .leading)

            AccessibilityAccessRow()
                .frame(maxWidth: 520)
        }
        .padding(14)
    }

    private func syncOption(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.checkbox)
                .fontWeight(.medium)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
        }
    }

    private func onboardingFeature(_ icon: String, _ title: String) -> some View {
        Label {
            Text(title).font(.body.weight(.medium))
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 24)
        }
    }

    private func controlRow(icon: String, title: String, detail: String, shortcut: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(shortcut)
                .font(.system(.body, design: .rounded, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        }
        .padding(9)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

}

/// Uses the production HUD view so onboarding always matches what appears on screen.
private struct OnboardingHUDPreview: NSViewRepresentable {
    let muted: Bool

    func makeNSView(context: Context) -> HUDContentView {
        let view = HUDContentView(frame: NSRect(x: 0, y: 0, width: 156, height: 156))
        view.configureToast(muted: muted)
        return view
    }

    func updateNSView(_ view: HUDContentView, context: Context) {
        view.configureToast(muted: muted)
    }
}
