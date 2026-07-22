import CoreAudio
import Foundation
import os.log

private let log = Logger(subsystem: "com.lockmic.app", category: "MicController")

enum MicState: Equatable, Sendable {
    case muted
    case unmuted
    case unknown
    case unsupported(deviceName: String)
}

@MainActor
final class MicController: ObservableObject {
    @Published private(set) var state: MicState = .unknown
    @Published private(set) var deviceName: String = "—"
    @Published private(set) var lastError: String?

    /// User-intended mute preference; re-applied when devices change.
    private(set) var desiredMuted: Bool = false

    private let audio: AudioDeviceService
    private let preferences: PreferencesStore
    private var devicesToken: UUID?

    init(audio: AudioDeviceService = AudioDeviceService(), preferences: PreferencesStore) {
        self.audio = audio
        self.preferences = preferences
        devicesToken = audio.onDevicesChanged { [weak self] in
            Task { @MainActor in
                self?.handleDevicesChanged()
            }
        }
        refreshFromHardware(applyDesired: false)
    }

    deinit {
        if let devicesToken {
            audio.removeDevicesChangedHandler(devicesToken)
        }
    }

    var isMuted: Bool {
        if case .muted = state { return true }
        return false
    }

    var muteAllInputs: Bool {
        preferences.muteAllInputs
    }

    func toggle() {
        switch state {
        case .muted:
            setMuted(false)
        case .unmuted, .unknown:
            setMuted(true)
        case .unsupported:
            setMuted(!desiredMuted)
        }
    }

    func setMuted(_ muted: Bool) {
        desiredMuted = muted
        applyMute(muted, syncDesiredFromHardware: false)
    }

    /// Call when the user changes the "mute all inputs" preference while muted.
    func preferenceMuteScopeChanged() {
        guard desiredMuted || isMuted else {
            refreshFromHardware(applyDesired: false)
            return
        }
        applyMute(desiredMuted, syncDesiredFromHardware: false)
    }

    func refreshFromHardware(applyDesired: Bool) {
        if applyDesired {
            applyMute(desiredMuted, syncDesiredFromHardware: false)
            return
        }

        do {
            let deviceID = try audio.defaultInputDeviceID()
            updateDeviceLabel(defaultID: deviceID)

            if audio.supportsMute(deviceID) {
                let muted = try audio.isMuted(deviceID)
                state = muted ? .muted : .unmuted
                desiredMuted = muted
                lastError = nil
            } else {
                // If mute-all mode, still try to infer from any muted device
                if preferences.muteAllInputs {
                    let anyMuted = audio.listInputDevices().contains { device in
                        (try? audio.isMuted(device.id)) == true
                    }
                    state = anyMuted ? .muted : .unmuted
                    desiredMuted = anyMuted
                    lastError = anyMuted ? nil : "Default input does not support mute."
                } else {
                    state = .unsupported(deviceName: audio.deviceName(deviceID))
                    lastError = "Default input does not support mute."
                }
            }
        } catch {
            lastError = error.localizedDescription
            state = .unknown
            log.error("Refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Private

    private func applyMute(_ muted: Bool, syncDesiredFromHardware: Bool) {
        if preferences.muteAllInputs {
            applyMuteAll(muted)
        } else {
            applyMuteDefault(muted)
        }

        if syncDesiredFromHardware, case .muted = state {
            desiredMuted = true
        } else if syncDesiredFromHardware, case .unmuted = state {
            desiredMuted = false
        }
    }

    private func applyMuteDefault(_ muted: Bool) {
        do {
            let deviceID = try audio.defaultInputDeviceID()
            deviceName = audio.deviceName(deviceID)
            try audio.setMuted(muted, deviceID: deviceID)

            if audio.supportsMute(deviceID) {
                let actual = try audio.isMuted(deviceID)
                state = actual ? .muted : .unmuted
                if actual != muted {
                    lastError = "Device reported a different mute state than requested."
                    log.warning("Mute mismatch desired=\(muted) actual=\(actual)")
                } else {
                    lastError = nil
                }
            } else {
                state = muted ? .muted : .unmuted
                lastError = nil
            }
            log.info("Mute set to \(muted) on default \(self.deviceName, privacy: .public)")
        } catch {
            lastError = error.localizedDescription
            if let deviceID = try? audio.defaultInputDeviceID() {
                deviceName = audio.deviceName(deviceID)
                state = .unsupported(deviceName: deviceName)
            } else {
                state = .unknown
            }
            log.error("Failed to set mute on default: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyMuteAll(_ muted: Bool) {
        let devices = audio.listInputDevices()
        guard !devices.isEmpty else {
            state = .unknown
            deviceName = "No input devices"
            lastError = "No input devices found."
            return
        }

        let result = audio.setAllInputsMuted(muted)
        updateDeviceLabel(defaultID: try? audio.defaultInputDeviceID())

        if result.allFailed {
            state = .unsupported(deviceName: deviceName)
            lastError = result.failed.map { "\($0.name): \($0.message)" }.joined(separator: "; ")
            log.error("Mute-all failed for every device")
            return
        }

        // Prefer reporting desired state if at least one device succeeded.
        // Re-check default when possible for icon accuracy.
        if let defaultID = try? audio.defaultInputDeviceID(), audio.supportsMute(defaultID) {
            if let actual = try? audio.isMuted(defaultID) {
                state = actual ? .muted : .unmuted
            } else {
                state = muted ? .muted : .unmuted
            }
        } else {
            state = muted ? .muted : .unmuted
        }

        if result.failed.isEmpty {
            lastError = nil
        } else {
            let names = result.failed.map(\.name).joined(separator: ", ")
            lastError = "No system mute on: \(names)"
            log.warning("Partial mute-all; failed: \(names, privacy: .public)")
        }

        // Log successes so Console.app can verify scope (e.g. MacBook mic vs Jabra only).
        if !result.succeededNames.isEmpty {
            log.info("Muted/unmuted OK: \(result.succeededNames.joined(separator: ", "), privacy: .public)")
        }

        log.info(
            "Mute-all set to \(muted); ok=\(result.succeededNames.count) fail=\(result.failed.count)"
        )
    }

    private func updateDeviceLabel(defaultID: AudioDeviceID?) {
        if preferences.muteAllInputs {
            let count = audio.listInputDevices().count
            if let defaultID {
                let name = audio.deviceName(defaultID)
                deviceName = count <= 1 ? name : "All inputs (\(count)) · \(name)"
            } else {
                deviceName = "All inputs (\(count))"
            }
        } else if let defaultID {
            deviceName = audio.deviceName(defaultID)
        } else {
            deviceName = "—"
        }
    }

    private func handleDevicesChanged() {
        log.info(
            "Audio devices changed; re-applying desired mute=\(self.desiredMuted) all=\(self.preferences.muteAllInputs)"
        )
        refreshFromHardware(applyDesired: true)
    }
}
