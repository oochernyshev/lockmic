import CoreAudio
import Foundation
import os.log

private let log = Logger(subsystem: "com.lockmic.app", category: "AudioDevice")

struct AudioInputDevice: Identifiable, Equatable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let supportsMute: Bool
    let isVirtual: Bool
}

enum AudioDeviceServiceError: LocalizedError {
    case noDefaultInput
    case propertyFailed(String)
    case muteUnsupported

    var errorDescription: String? {
        switch self {
        case .noDefaultInput: return "No default input device is available."
        case .propertyFailed(let detail): return "Audio property failed: \(detail)"
        case .muteUnsupported: return "This input device does not support system mute."
        }
    }
}

/// Core Audio HAL — master input mute only.
final class AudioDeviceService: @unchecked Sendable {
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?
    private let lock = NSLock()
    private var onDevicesChangedHandlers: [UUID: () -> Void] = [:]

    init() {
        installListeners()
    }

    deinit {
        removeListeners()
    }

    func defaultInputDeviceID() throws -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = propertyAddress(
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
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
        stringProperty(deviceID, selector: kAudioDevicePropertyDeviceNameCFString) ?? "Input \(deviceID)"
    }

    func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    func supportsMute(_ deviceID: AudioDeviceID) -> Bool {
        isSettable(
            deviceID,
            selector: kAudioDevicePropertyMute,
            scope: kAudioDevicePropertyScopeInput,
            element: kAudioObjectPropertyElementMain
        )
    }

    func isMuted(_ deviceID: AudioDeviceID) throws -> Bool {
        guard supportsMute(deviceID) else { throw AudioDeviceServiceError.muteUnsupported }
        var address = propertyAddress(
            kAudioDevicePropertyMute,
            kAudioDevicePropertyScopeInput,
            kAudioObjectPropertyElementMain
        )
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)
        guard status == noErr else { throw AudioDeviceServiceError.propertyFailed("get mute (\(status))") }
        return muted != 0
    }

    func setMuted(_ muted: Bool, deviceID: AudioDeviceID) throws {
        guard supportsMute(deviceID) else { throw AudioDeviceServiceError.muteUnsupported }
        var address = propertyAddress(
            kAudioDevicePropertyMute,
            kAudioDevicePropertyScopeInput,
            kAudioObjectPropertyElementMain
        )
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
        guard status == noErr else { throw AudioDeviceServiceError.propertyFailed("set mute (\(status))") }
    }

    struct MuteBatchResult: Sendable {
        var succeededNames: [String] = []
        var failed: [(name: String, message: String)] = []
        var didSucceedAny: Bool { !succeededNames.isEmpty }
        var allFailed: Bool { succeededNames.isEmpty && !failed.isEmpty }
    }

    func setAllInputsMuted(_ muted: Bool) -> MuteBatchResult {
        var result = MuteBatchResult()
        // Skip virtual loopbacks (BlackHole, Teams Audio, etc.) — they often expose a
        // mute flag that does nothing or isn't a real microphone path.
        for device in listInputDevices() where !device.isVirtual {
            do {
                try setMuted(muted, deviceID: device.id)
                // Verify the driver actually honored mute.
                if muted, let nowMuted = try? isMuted(device.id), !nowMuted {
                    result.failed.append((device.name, "Mute not honored by driver"))
                } else {
                    result.succeededNames.append(device.name)
                }
            } catch {
                result.failed.append((device.name, error.localizedDescription))
            }
        }
        return result
    }

    func listInputDevices() -> [AudioInputDevice] {
        var address = propertyAddress(
            kAudioHardwarePropertyDevices,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.compactMap { id -> AudioInputDevice? in
            guard inputChannelCount(id) > 0 else { return nil }
            let name = deviceName(id)
            let uid = deviceUID(id) ?? "\(id)"

            return AudioInputDevice(
                id: id,
                uid: uid,
                name: name,
                supportsMute: supportsMute(id),
                isVirtual: isVirtualInput(deviceID: id)
            )
        }
    }

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

    // MARK: - Virtual device detection

    /// Virtual inputs are those Core Audio reports with transport type `Virtual` only.
    /// No name/UID heuristics — drivers that mis-report transport will be treated as normal devices.
    private func isVirtualInput(deviceID: AudioDeviceID) -> Bool {
        transportType(deviceID) == kAudioDeviceTransportTypeVirtual
    }

    private func transportType(_ deviceID: AudioDeviceID) -> UInt32? {
        var address = propertyAddress(
            kAudioDevicePropertyTransportType,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        guard status == noErr else { return nil }
        return transport
    }

    // MARK: - Private

    private func stringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = propertyAddress(selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.stride)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return value as String
    }

    private func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope,
        _ element: AudioObjectPropertyElement
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private func isSettable(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var address = propertyAddress(selector, scope, element)
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    private func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = propertyAddress(
            kAudioDevicePropertyStreamConfiguration,
            kAudioDevicePropertyScopeInput,
            kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, raw) == noErr else { return 0 }
        let bufferList = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        return UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func notifyDevicesChanged() {
        lock.lock()
        let handlers = Array(onDevicesChangedHandlers.values)
        lock.unlock()
        DispatchQueue.main.async { handlers.forEach { $0() } }
    }

    private func installListeners() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.notifyDevicesChanged()
        }
        defaultDeviceListenerBlock = block
        deviceListListenerBlock = block

        var defaultAddress = propertyAddress(
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            DispatchQueue.main,
            block
        )

        var listAddress = propertyAddress(
            kAudioHardwarePropertyDevices,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
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
        var defaultAddress = propertyAddress(
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            DispatchQueue.main,
            block
        )
        var listAddress = propertyAddress(
            kAudioHardwarePropertyDevices,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddress,
            DispatchQueue.main,
            block
        )
    }
}
