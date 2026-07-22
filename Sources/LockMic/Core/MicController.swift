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

/// Snapshot of an input device for the Preferences → Devices list.
struct InputDeviceRow: Identifiable, Equatable, Sendable {
    let id: UInt32
    let name: String
    let isDefault: Bool
    let supportsMute: Bool
    let isMuted: Bool?
    let isVirtual: Bool
    /// Controlled by LockMic under the current mute-all / default scope.
    let isInScope: Bool

    enum ControlStatus: Equatable, Sendable {
        case muted
        case on
        case notControllable
        case virtualIgnored
        case outsideScope
        case unknown
    }

    var controlStatus: ControlStatus {
        if isVirtual { return .virtualIgnored }
        if !supportsMute { return .notControllable }
        if !isInScope { return .outsideScope }
        switch isMuted {
        case true?: return .muted
        case false?: return .on
        case nil: return .unknown
        }
    }
}

@MainActor
final class MicController: ObservableObject {
    @Published private(set) var state: MicState = .unknown
    @Published private(set) var deviceName: String = "—"
    @Published private(set) var lastError: String?
    @Published private(set) var inputDevices: [InputDeviceRow] = []

    /// Sticky user intent, re-applied when devices change.
    private(set) var desiredMuted: Bool = false

    private let audio: AudioDeviceService
    private let preferences: PreferencesStore
    private var devicesToken: UUID?
    private var isApplyingMute = false
    private var deviceChangeWorkItem: DispatchWorkItem?

    init(audio: AudioDeviceService = AudioDeviceService(), preferences: PreferencesStore) {
        self.audio = audio
        self.preferences = preferences
        devicesToken = audio.onDevicesChanged { [weak self] in
            Task { @MainActor in
                self?.scheduleHandleDevicesChanged()
            }
        }
        refreshFromHardware(applyDesired: false)
        refreshDeviceList()
    }

    deinit {
        if let devicesToken {
            audio.removeDevicesChangedHandler(devicesToken)
        }
    }

    /// Single source of truth for “is the mic muted?” for UI, hotkeys, and HUD.
    /// Uses HAL state when known; falls back to `desiredMuted` when unknown/unsupported.
    var effectiveMuted: Bool {
        switch state {
        case .muted: return true
        case .unmuted: return false
        case .unknown, .unsupported: return desiredMuted
        }
    }

    /// Alias of `effectiveMuted` for call sites that read “is muted?”.
    var isMuted: Bool { effectiveMuted }

    func toggle() {
        setMuted(!effectiveMuted)
    }

    func setMuted(_ muted: Bool) {
        desiredMuted = muted
        applyMute(muted)
    }

    func preferenceMuteScopeChanged() {
        if desiredMuted {
            applyMute(true)
        } else {
            refreshFromHardware(applyDesired: false)
        }
        refreshDeviceList()
    }

    func refreshFromHardware(applyDesired: Bool) {
        if applyDesired {
            applyMute(desiredMuted)
            return
        }
        do {
            let id = try audio.defaultInputDeviceID()
            deviceName = audio.deviceName(id)
            if audio.supportsMute(id) {
                let muted = try audio.isMuted(id)
                state = muted ? .muted : .unmuted
                desiredMuted = muted
                lastError = nil
            } else {
                state = .unsupported(deviceName: deviceName)
            }
        } catch {
            lastError = error.localizedDescription
            state = .unknown
        }
        refreshDeviceList()
    }

    /// Rebuild the Preferences device table from Core Audio.
    func refreshDeviceList() {
        let defaultID = try? audio.defaultInputDeviceID()
        inputDevices = audio.listInputDevices().map { device in
            let isDefault = device.id == defaultID
            // Virtual loopbacks are listed for visibility but never controlled.
            let inScope = !device.isVirtual && (preferences.muteAllInputs || isDefault)
            let muted: Bool? = device.supportsMute ? (try? audio.isMuted(device.id)) : nil
            return InputDeviceRow(
                id: device.id,
                name: device.name,
                isDefault: isDefault,
                supportsMute: device.supportsMute,
                isMuted: muted,
                isVirtual: device.isVirtual,
                isInScope: inScope
            )
        }
    }

    // MARK: - Private

    private func applyMute(_ muted: Bool) {
        isApplyingMute = true
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.isApplyingMute = false
            }
        }

        if preferences.muteAllInputs {
            let result = audio.setAllInputsMuted(muted)
            if let id = try? audio.defaultInputDeviceID() {
                deviceName = audio.deviceName(id)
            }
            if muted {
                if result.allFailed, !result.failed.isEmpty {
                    state = .unsupported(deviceName: deviceName)
                    lastError = result.failed.map { "\($0.name): \($0.message)" }.joined(separator: "; ")
                } else {
                    state = .muted
                    lastError = result.failed.isEmpty
                        ? nil
                        : "No system mute on: \(result.failed.map(\.name).joined(separator: ", "))"
                }
            } else {
                state = .unmuted
                lastError = nil
            }
        } else {
            // Default input only — never touch other devices.
            do {
                let id = try audio.defaultInputDeviceID()
                try audio.setMuted(muted, deviceID: id)
                deviceName = audio.deviceName(id)
                state = muted ? .muted : .unmuted
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                if muted {
                    state = .unsupported(deviceName: deviceName)
                } else {
                    state = .unknown
                }
            }
        }
        log.debug("\(muted ? "Muted" : "Unmuted", privacy: .public)")
        refreshDeviceList()
    }

    private func scheduleHandleDevicesChanged() {
        if isApplyingMute { return }
        deviceChangeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isApplyingMute else { return }
            self.refreshFromHardware(applyDesired: true)
            self.refreshDeviceList()
        }
        deviceChangeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
