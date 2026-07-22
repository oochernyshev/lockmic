import SwiftUI

private enum PreferencesTab: String, CaseIterable, Identifiable, Hashable {
    case general
    case devices
    case keyboard
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .devices: return "Devices"
        case .keyboard: return "Keyboard"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .devices: return "mic.fill"
        case .keyboard: return "keyboard"
        case .about: return "info.circle"
        }
    }
}

/// System Settings–style preferences: sidebar + detail, resizable frosted window.
struct PreferencesView: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var mic: MicController
    @State private var selection: PreferencesTab = .general

    private let sidebarWidth: CGFloat = 168

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: sidebarWidth)
                .frame(maxHeight: .infinity, alignment: .top)

            Divider()

            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 380, idealHeight: 460)
        .background(.regularMaterial)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(PreferencesTab.allCases) { tab in
                sidebarRow(tab)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(.thinMaterial)
    }

    private func sidebarRow(_ tab: PreferencesTab) -> some View {
        let selected = selection == tab
        return Button {
            selection = tab
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.systemImage)
                    .font(.body.weight(.medium))
                    .frame(width: 20, alignment: .center)
                    .symbolRenderingMode(.hierarchical)
                Text(tab.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusEffectDisabled()
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.85))
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        // Scroll only when content exceeds the window (indicators appear as needed).
        ScrollView(.vertical, showsIndicators: true) {
            Group {
                switch selection {
                case .general:
                    generalPage
                case .devices:
                    devicesPage
                case .keyboard:
                    keyboardPage
                case .about:
                    aboutPage
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Pages

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Status")
            gridRow("Microphone", statusText)
            gridRow("Device", mic.deviceName)
            if let error = mic.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider().padding(.vertical, 2)

            sectionHeader("Options")
            Toggle("Show on-screen HUD when muting", isOn: $preferences.hudEnabled)
                .disabled(preferences.hudFloating)
            Toggle("Keep HUD indicator floating", isOn: $preferences.hudFloating)
            if preferences.hudFloating {
                Text("Drag to move · click to toggle · right-click to hide/show per display.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Play sound when muting / unmuting", isOn: $preferences.soundEnabled)
            Toggle("Launch at login", isOn: $preferences.launchAtLogin)
        }
    }

    private var devicesPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Mute scope")
            Toggle("Mute all input devices", isOn: $preferences.muteAllInputs)
                .onChange(of: preferences.muteAllInputs) { _, _ in
                    mic.preferenceMuteScopeChanged()
                }
            Text(
                preferences.muteAllInputs
                    ? "Mutes every controllable input (recommended for Zoom/Meet)."
                    : "Only mutes the system default input."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 2)

            HStack {
                sectionHeader("Detected inputs")
                Spacer()
                Button {
                    mic.refreshDeviceList()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh device list")
                .focusable(false)
                .focusEffectDisabled()
            }

            if mic.inputDevices.isEmpty {
                Text("No input devices found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(mic.inputDevices) { device in
                        deviceRow(device)
                    }
                }
            }
        }
        .onAppear {
            mic.refreshDeviceList()
        }
    }

    private func deviceRow(_ device: InputDeviceRow) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: deviceIcon(device))
                .font(.body)
                .foregroundStyle(device.supportsMute ? Color.accentColor : Color.secondary)
                .frame(width: 18, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if device.isDefault {
                        Text("Default")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    if device.isVirtual {
                        Text("Virtual")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(deviceSubtitle(device))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Text(deviceStatusLabel(device))
                .font(.caption.weight(.medium))
                .foregroundStyle(deviceStatusColor(device))
        }
        .padding(.vertical, 2)
    }

    private func deviceIcon(_ device: InputDeviceRow) -> String {
        if device.isVirtual { return "waveform" }
        if device.supportsMute { return "mic.fill" }
        return "mic.slash"
    }

    private func deviceSubtitle(_ device: InputDeviceRow) -> String {
        switch device.controlStatus {
        case .virtualIgnored:
            return "Virtual loopback — not a physical mic; LockMic ignores it"
        case .notControllable:
            return "Driver does not support system mute"
        case .outsideScope:
            return "Outside current mute scope (default only)"
        case .muted, .on:
            return "Controlled by LockMic"
        case .unknown:
            return "Mute state unknown"
        }
    }

    private func deviceStatusLabel(_ device: InputDeviceRow) -> String {
        switch device.controlStatus {
        case .muted: return "Muted"
        case .on: return "On"
        case .virtualIgnored: return "Ignored"
        case .notControllable: return "—"
        case .outsideScope: return "On"
        case .unknown: return "?"
        }
    }

    private func deviceStatusColor(_ device: InputDeviceRow) -> Color {
        switch device.controlStatus {
        case .muted: return .orange
        case .on: return .green
        case .virtualIgnored, .notControllable, .outsideScope, .unknown: return .secondary
        }
    }

    private var keyboardPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Shortcuts")
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

            shortcutRow(
                title: "Toggle mute",
                enabled: $preferences.toggleShortcutEnabled,
                chord: $preferences.toggleChord
            )
            shortcutRow(
                title: "Mute",
                enabled: $preferences.muteShortcutEnabled,
                chord: $preferences.muteChord
            )
            shortcutRow(
                title: "Unmute",
                enabled: $preferences.unmuteShortcutEnabled,
                chord: $preferences.unmuteChord
            )

            Toggle("Also toggle with ⌘F5", isOn: $preferences.f5ToggleEnabled)
                .focusable(false)
                .focusEffectDisabled()

            Divider().padding(.vertical, 2)

            sectionHeader("Momentary")
            Text("Hold to change mute · release restores previous state")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            shortcutRow(
                title: "Push to talk",
                enabled: $preferences.pushToTalkEnabled,
                chord: $preferences.pushToTalkChord
            )
            shortcutRow(
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

    private func shortcutRow(
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

    private var aboutPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image("AppLogo")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 112, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text("LockMic")
                        .font(.title2.weight(.semibold))
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("by WIXEE.AI")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Text("LockMic mutes your input at the system level so it works in every app.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 8) {
                aboutMetaRow(label: "Website") {
                    Link("wixee.ai", destination: URL(string: "https://wixee.ai")!)
                        .font(.body)
                        .focusable(false)
                        .focusEffectDisabled()
                }
                aboutMetaRow(label: "Owner") {
                    Text("WIXEE.AI")
                }
                aboutMetaRow(label: "License") {
                    Text("MIT License")
                }
                Text("Copyright © 2026 WIXEE.AI")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
    }

    private func aboutMetaRow<Content: View>(label: String, @ViewBuilder value: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            value()
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
    }

    private func gridRow(_ title: String, _ value: String) -> some View {
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

    private var statusText: String {
        switch mic.state {
        case .muted: return "Muted"
        case .unmuted: return "Unmuted"
        case .unknown: return "Unknown"
        case .unsupported: return "Unsupported device"
        }
    }
}
