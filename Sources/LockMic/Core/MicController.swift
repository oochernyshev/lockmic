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
    let uid: String
    let name: String
    let isDefault: Bool
    let supportsMute: Bool
    let isMuted: Bool?
    let isVirtual: Bool
    /// Controlled by LockMic under the current mute-all / default scope.
    let isInScope: Bool

    enum ControlStatus: Equatable, Sendable {
        case muted
        case unmuted
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
        case false?: return .unmuted
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

    /// When true (e.g. push-to-talk held), device-change handlers only refresh the list —
    /// they must not re-apply mute and clobber hold/restore state.
    var suppressDeviceResync = false

    private let audio: AudioDeviceService
    private let preferences: PreferencesStore
    private var devicesToken: UUID?
    private var isApplyingMute = false
    private var deviceChangeWorkItem: DispatchWorkItem?

    /// While user intent is muted, re-check HAL periodically and re-apply if a new
    /// capture client (e.g. Meet/Chrome) or the driver cleared mute without a device-list event.
    private var muteEnforceTimer: Timer?
    private static let muteEnforceInterval: TimeInterval = 2.0

    init(audio: AudioDeviceService = AudioDeviceService(), preferences: PreferencesStore) {
        self.audio = audio
        self.preferences = preferences
        devicesToken = audio.onDevicesChanged { [weak self] in
            Task { @MainActor in
                self?.scheduleHandleDevicesChanged()
            }
        }
        refreshFromHardware(applyDesired: false)
        // refreshFromHardware already rebuilds the list and starts mute enforcement if needed.
    }

    deinit {
        muteEnforceTimer?.invalidate()
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
        syncMuteEnforcementTimer()
    }

    func preferenceMuteScopeChanged() {
        if desiredMuted {
            applyMute(true) // includes refreshDeviceList
        } else {
            refreshFromHardware(applyDesired: false) // includes refreshDeviceList
        }
    }

    /// - Parameter applyDesired: `true` re-writes HAL from sticky intent (device change,
    ///   app activation). `false` seeds intent from HAL — only safe at launch or when
    ///   the user is not holding a mute.
    func refreshFromHardware(applyDesired: Bool) {
        if applyDesired {
            applyMute(desiredMuted)
            syncMuteEnforcementTimer()
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
        syncMuteEnforcementTimer()
    }

    /// Rebuild the Preferences device table from Core Audio.
    func refreshDeviceList() {
        let defaultID = try? audio.defaultInputDeviceID()
        inputDevices = audio.listInputDevices().map { device in
            let isDefault = device.id == defaultID
            // Virtual-transport devices are listed but never controlled.
            let inScope = !device.isVirtual && (preferences.muteAllInputs || isDefault)
            let muted: Bool? = device.supportsMute ? (try? audio.isMuted(device.id)) : nil
            return InputDeviceRow(
                id: device.id,
                uid: device.uid,
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

    /// Start/stop the background re-assert timer based on `desiredMuted`.
    private func syncMuteEnforcementTimer() {
        if desiredMuted {
            guard muteEnforceTimer == nil else { return }
            let timer = Timer(timeInterval: Self.muteEnforceInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.enforceDesiredMuteIfNeeded()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            muteEnforceTimer = timer
        } else {
            muteEnforceTimer?.invalidate()
            muteEnforceTimer = nil
        }
    }

    /// If intent is muted but HAL (or a driver) dropped mute, write it again quietly.
    private func enforceDesiredMuteIfNeeded() {
        guard desiredMuted, !suppressDeviceResync, !isApplyingMute else { return }
        guard !isHardwareRespectingDesiredMute() else { return }
        log.debug("Re-asserting mute (hardware or capture client cleared it)")
        applyMute(true)
    }

    /// True when every in-scope controllable input still reports muted.
    private func isHardwareRespectingDesiredMute() -> Bool {
        if preferences.muteAllInputs {
            for device in audio.listInputDevices() where !device.isVirtual && device.supportsMute {
                if let muted = try? audio.isMuted(device.id), !muted {
                    return false
                }
            }
            return true
        }
        guard let id = try? audio.defaultInputDeviceID(), audio.supportsMute(id) else {
            return true
        }
        return (try? audio.isMuted(id)) ?? true
    }

    private func scheduleHandleDevicesChanged() {
        if isApplyingMute { return }
        deviceChangeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isApplyingMute else { return }
            if self.suppressDeviceResync {
                // Hold in progress (PTT/PTM/flip): list only, no mute re-apply.
                self.refreshDeviceList()
                return
            }
            // applyDesired → applyMute already ends with refreshDeviceList().
            self.refreshFromHardware(applyDesired: true)
        }
        deviceChangeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
