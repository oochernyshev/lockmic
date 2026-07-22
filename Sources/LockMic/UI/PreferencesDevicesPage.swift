import SwiftUI

struct PreferencesDevicesPage: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var mic: MicController

    var body: some View {
        VStack(alignment: .leading, spacing: PreferencesChrome.pageSpacing) {
            PreferencesChrome.sectionCard {
                PreferencesChrome.sectionHeader("Mute scope")
                Toggle("Mute all input devices", isOn: $preferences.muteAllInputs)
                    .onChange(of: preferences.muteAllInputs) { _, _ in
                        mic.preferenceMuteScopeChanged()
                    }
                PreferencesChrome.caption(
                    preferences.muteAllInputs
                        ? "Mutes every controllable input (recommended for Zoom/Meet)."
                        : "Only mutes the system default input."
                )
            }

            PreferencesChrome.sectionCard {
                HStack {
                    PreferencesChrome.sectionHeader("Detected inputs")
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
                    PreferencesChrome.caption("No input devices found.")
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(mic.inputDevices.enumerated()), id: \.element.id) { index, device in
                            deviceRow(device)
                            if index < mic.inputDevices.count - 1 {
                                Divider()
                                    .padding(.leading, 26)
                                    .opacity(0.55)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.035))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                    )
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
        .padding(.vertical, 8)
    }

    private func deviceIcon(_ device: InputDeviceRow) -> String {
        if device.isVirtual { return "waveform" }
        if device.supportsMute { return "mic.fill" }
        return "mic.slash"
    }

    private func deviceSubtitle(_ device: InputDeviceRow) -> String {
        switch device.controlStatus {
        case .virtualIgnored:
            return "Virtual transport (Core Audio) — ignored for mute control"
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
}
