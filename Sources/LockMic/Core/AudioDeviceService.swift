import CoreAudio
import Foundation
import os.log

private let log = Logger(subsystem: "com.lockmic.app", category: "AudioDevice")

struct AudioInputDevice: Identifiable, Equatable, Sendable {
    let id: AudioDeviceID
    let name: String
    /// True if any mute or volume control was found on the input scope.
    let canControlLevel: Bool
}

enum AudioDeviceServiceError: LocalizedError {
    case noDefaultInput
    case propertyFailed(String)
    case muteUnsupported

    var errorDescription: String? {
        switch self {
        case .noDefaultInput:
            return "No default input device is available."
        case .propertyFailed(let detail):
            return "Audio property failed: \(detail)"
        case .muteUnsupported:
            return "This input device cannot be muted by the system."
        }
    }
}

/// Core Audio HAL access for input devices and mute state.
///
/// Mute strategy (best-effort, per device):
/// 1. Set `kAudioDevicePropertyMute` on master + every input channel
/// 2. When muting, also force input volume to 0 (restore previous on unmute)
///
/// Many USB/Bluetooth/virtual devices ignore master-only mute; Jabra-style headsets
/// often honor it (and announce “Muted”). Channel mute + volume covers the rest.
final class AudioDeviceService: @unchecked Sendable {
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?
    private let lock = NSLock()
    private var onDevicesChangedHandlers: [UUID: () -> Void] = [:]

    /// Saved input volumes while we force volume to 0 for mute fallback.
    /// Key: "\(deviceID):\(element)"
    private var savedVolumes: [String: Float32] = [:]

    init() {
        installListeners()
    }

    deinit {
        removeListeners()
    }

    // MARK: - Public API

    func defaultInputDeviceID() throws -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw AudioDeviceServiceError.noDefaultInput
        }
        return deviceID
    }

    func deviceName(_ deviceID: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.stride)
        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        if status == noErr {
            return name as String
        }
        return "Input \(deviceID)"
    }

    func supportsMute(_ deviceID: AudioDeviceID) -> Bool {
        inputElements(deviceID).contains { element in
            isMuteSettable(deviceID, element: element)
        }
    }

    func isMuted(_ deviceID: AudioDeviceID) throws -> Bool {
        let elements = inputElements(deviceID)
        var sawMuteProperty = false
        for element in elements {
            if let muted = getMute(deviceID, element: element) {
                sawMuteProperty = true
                // Device is considered muted if master or any channel reports muted.
                if muted { return true }
            }
        }
        // Volume-only mute: treat as muted if all controllable volumes are ~0
        let volumes = elements.compactMap { getVolume(deviceID, element: $0) }
        if !volumes.isEmpty, volumes.allSatisfy({ $0 < 0.001 }) {
            return true
        }
        if sawMuteProperty {
            return false
        }
        throw AudioDeviceServiceError.muteUnsupported
    }

    /// Apply mute using mute flags + volume zeroing across all input channels.
    func setMuted(_ muted: Bool, deviceID: AudioDeviceID) throws {
        let elements = inputElements(deviceID)
        var muteOK = false
        var volumeOK = false

        for element in elements {
            if setMute(muted, deviceID: deviceID, element: element) {
                muteOK = true
            }

            if muted {
                if let current = getVolume(deviceID, element: element) {
                    // Only remember non-zero levels so we can restore later.
                    if current > 0.001 {
                        savedVolumes[volumeKey(deviceID, element)] = current
                    }
                }
                if setVolume(0, deviceID: deviceID, element: element) {
                    volumeOK = true
                }
            } else {
                // Unmute: restore volume if we lowered it; otherwise leave hardware as-is
                // after clearing mute flags (avoid blasting unknown devices to 100%).
                if let saved = savedVolumes.removeValue(forKey: volumeKey(deviceID, element)) {
                    if setVolume(saved, deviceID: deviceID, element: element) {
                        volumeOK = true
                    }
                } else if getVolume(deviceID, element: element) != nil {
                    // We may have muted via volume without a save (e.g. already 0).
                    // Nudge to a usable level only if currently silent.
                    if let v = getVolume(deviceID, element: element), v < 0.001 {
                        if setVolume(0.75, deviceID: deviceID, element: element) {
                            volumeOK = true
                        }
                    } else {
                        volumeOK = true
                    }
                }
            }
        }

        guard muteOK || volumeOK else {
            throw AudioDeviceServiceError.muteUnsupported
        }

        log.info(
            "setMuted(\(muted)) \(self.deviceName(deviceID), privacy: .public) muteOK=\(muteOK) volumeOK=\(volumeOK) elements=\(elements.count)"
        )
    }

    func defaultInputIsMuted() throws -> Bool {
        try isMuted(try defaultInputDeviceID())
    }

    func setDefaultInputMuted(_ muted: Bool) throws {
        try setMuted(muted, deviceID: try defaultInputDeviceID())
    }

    /// Result of applying mute to one or more devices.
    struct MuteBatchResult: Sendable {
        var succeededNames: [String] = []
        var failed: [(name: String, message: String)] = []

        var didSucceedAny: Bool { !succeededNames.isEmpty }
        var allFailed: Bool { succeededNames.isEmpty && !failed.isEmpty }
    }

    /// Mute/unmute every input device that has channels (best-effort).
    func setAllInputsMuted(_ muted: Bool) -> MuteBatchResult {
        var result = MuteBatchResult()
        let devices = listInputDevices()
        log.info("setAllInputsMuted(\(muted)) — \(devices.count) input device(s)")

        for device in devices {
            do {
                try setMuted(muted, deviceID: device.id)
                result.succeededNames.append(device.name)
                log.info("  ✓ \(device.name, privacy: .public)")
            } catch {
                result.failed.append((device.name, error.localizedDescription))
                log.warning(
                    "  ✗ \(device.name, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return result
    }

    func listInputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else {
            return []
        }

        return deviceIDs.compactMap { id in
            guard hasInputChannels(id) else { return nil }
            let elements = inputElements(id)
            let canControl = elements.contains {
                isMuteSettable(id, element: $0) || isVolumeSettable(id, element: $0)
            }
            return AudioInputDevice(
                id: id,
                name: deviceName(id),
                canControlLevel: canControl
            )
        }
    }

    /// Register for default-input / device-list changes. Returns a token for removal.
    @discardableResult
    func onDevicesChanged(_ handler: @escaping () -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        onDevicesChangedHandlers[token] = handler
        lock.unlock()
        return token
    }

    func removeDevicesChangedHandler(_ token: UUID) {
        lock.lock()
        onDevicesChangedHandlers.removeValue(forKey: token)
        lock.unlock()
    }

    // MARK: - Channel / property helpers

    /// Master + each input channel index (1-based) from stream config.
    private func inputElements(_ deviceID: AudioDeviceID) -> [AudioObjectPropertyElement] {
        var elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain]
        let channelCount = inputChannelCount(deviceID)
        if channelCount > 0 {
            for ch in 1...channelCount {
                elements.append(AudioObjectPropertyElement(ch))
            }
        } else {
            // Some drivers omit stream config but still expose channels 1–2.
            elements.append(1)
            elements.append(2)
        }
        // Unique while preserving order
        var seen = Set<AudioObjectPropertyElement>()
        return elements.filter { seen.insert($0).inserted }
    }

    private func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0
        else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, raw) == noErr else {
            return 0
        }
        let bufferList = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        inputChannelCount(deviceID) > 0
    }

    private func muteAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: element
        )
    }

    private func volumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: element
        )
    }

    private func isMuteSettable(_ deviceID: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
        var address = muteAddress(element: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr else {
            return false
        }
        return settable.boolValue
    }

    private func isVolumeSettable(_ deviceID: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
        var address = volumeAddress(element: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr else {
            return false
        }
        return settable.boolValue
    }

    private func getMute(_ deviceID: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool? {
        var address = muteAddress(element: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)
        guard status == noErr else { return nil }
        return muted != 0
    }

    @discardableResult
    private func setMute(_ muted: Bool, deviceID: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
        guard isMuteSettable(deviceID, element: element) else { return false }
        var address = muteAddress(element: element)
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value) == noErr
    }

    private func getVolume(_ deviceID: AudioDeviceID, element: AudioObjectPropertyElement) -> Float32? {
        var address = volumeAddress(element: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value
    }

    @discardableResult
    private func setVolume(_ volume: Float32, deviceID: AudioDeviceID, element: AudioObjectPropertyElement) -> Bool {
        guard isVolumeSettable(deviceID, element: element) else { return false }
        var address = volumeAddress(element: element)
        var value = max(0, min(1, volume))
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value) == noErr
    }

    private func volumeKey(_ deviceID: AudioDeviceID, _ element: AudioObjectPropertyElement) -> String {
        "\(deviceID):\(element)"
    }

    // MARK: - Listeners

    private func notifyDevicesChanged() {
        lock.lock()
        let handlers = Array(onDevicesChangedHandlers.values)
        lock.unlock()
        DispatchQueue.main.async {
            handlers.forEach { $0() }
        }
    }

    private func installListeners() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.notifyDevicesChanged()
        }
        defaultDeviceListenerBlock = block
        deviceListListenerBlock = block

        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            DispatchQueue.main,
            block
        )

        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddress,
            DispatchQueue.main,
            block
        )
    }

    private func removeListeners() {
        guard let block = defaultDeviceListenerBlock else { return }
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            DispatchQueue.main,
            block
        )
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddress,
            DispatchQueue.main,
            block
        )
    }
}
