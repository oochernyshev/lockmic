import AVFoundation
import CoreAudio
import Foundation
import os.log

private let log = Logger(subsystem: "com.lockmic.app", category: "PlaybackTap")

protocol PlaybackCapturing: AnyObject {
    func stop()
    /// Core Audio stops IO procs after an output sample-rate change (Jabra 48→16 kHz).
    func ensureRunning()
    func setMixEnabled(_ on: Bool)
    var level: Float { get }
}

// MARK: - Playback tap (system audio)

/// Private tap-only aggregate. Do not put the output UID in the composition.
@available(macOS 14.2, *)
final class PlaybackTap: PlaybackCapturing {
    /// Non-nil queue is required — `nil` silently fails to register the IO block on macOS 26.
    private let queue = DispatchQueue(label: "com.lockmic.playback-tap", qos: .userInitiated)
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?
    weak var mixer: LiveMixer?
    private var scratch: AVAudioPCMBuffer?
    private var mix48: AVAudioPCMBuffer?
    private let mixResampler = MixRateResampler(channels: 2)
    private var loggedFirstBuffer = false
    let sourceID: String
    /// Off until SessionRecorder enables this tap for the mix.
    private var mixEnabled = false
    private var tapDeviceUID: String
    private var tapStreamIndex: UInt = 0
    private var ioFormat: AVAudioFormat?
    private var formatListener: AudioObjectPropertyListenerBlock?
    private let lock = NSLock()
    private var _level: Float = 0

    var level: Float {
        lock.lock(); defer { lock.unlock() }
        return RecordingLevelDisplay.fromLinearPeak(_level)
    }

    init(audio: AudioDeviceService, deviceUID: String?) async throws {
        self.sourceID = deviceUID ?? PlaybackMix.systemSourceID
        self.tapDeviceUID = deviceUID ?? ""
        try attachHardware(using: audio)
        try await waitForIOStart()
    }

    func stop() {
        detachHardware()
    }

    func setMixEnabled(_ on: Bool) {
        lock.lock()
        mixEnabled = on
        lock.unlock()
    }

    func ensureRunning() {
        let aggregate = aggregateID
        let proc = ioProcID
        guard aggregate != 0, let proc else { return }
        reloadFormat()
        queue.async {
            let status = AudioDeviceStart(aggregate, proc)
            if status != noErr {
                log.error(
                    "Playback tap restart failed (\(status, privacy: .public)) device=\(self.tapDeviceUID, privacy: .public)"
                )
            }
        }
    }

    private func attachHardware(using audio: AudioDeviceService) throws {
        var exclude: [AudioObjectID] = []
        if let selfProcess = audio.processObjectID(for: ProcessInfo.processInfo.processIdentifier) {
            exclude.append(selfProcess)
        }

        let description: CATapDescription
        if tapDeviceUID.isEmpty {
            // System mix, not a hardware device. Switching default output
            // (speakers → Jabra) does not stop this tap; a device-bound tap
            // goes silent while USB/DECT reconfigures.
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
            tapStreamIndex = 0
        } else {
            guard let device = audio.listOutputDevices().first(where: { $0.uid == tapDeviceUID }),
                  !audio.isLockMicRecorder(device.id)
            else {
                throw AudioDeviceServiceError.propertyFailed("output UID")
            }
            // Device-bound tap must not also list that device as a sub-device —
            // that pair hangs a mixdown on the speakers.
            tapStreamIndex = Self.preferredOutputStreamIndex(device.id)
            description = CATapDescription(
                excludingProcesses: exclude,
                deviceUID: device.uid,
                stream: tapStreamIndex
            )
        }
        description.name = "LockMic Playback"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var createdTap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &createdTap)
        guard tapStatus == noErr, createdTap != kAudioObjectUnknown else {
            throw SessionRecorderError.tapFailed(tapStatus)
        }
        tapID = createdTap

        // HAL wants CFNumber for these flags — a Swift `Bool` becomes CFBoolean
        // and the aggregate is published as a public “LockMic Recorder” device.
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LockMic Recorder",
            kAudioAggregateDeviceUIDKey: "com.lockmic.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            // 0 so AudioDeviceStart returns after the TCC prompt instead of
            // waiting for the first tapped buffer (which hung Start Recording).
            kAudioAggregateDeviceTapAutoStartKey: 0,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    // Device taps (Jabra USB) drift vs the mix aggregate.
                    kAudioSubTapDriftCompensationKey: tapDeviceUID.isEmpty ? 0 : 1,
                ],
            ],
        ]

        var createdAggregate = AudioDeviceID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &createdAggregate)
        guard aggStatus == noErr, createdAggregate != kAudioObjectUnknown else {
            detachHardware()
            throw SessionRecorderError.aggregateFailed(aggStatus)
        }
        aggregateID = createdAggregate
        // Private aggregate only — never change the user's speaker buffer or rate.
        Self.setPreferredBufferFrameSize(createdAggregate, 2048)
        if tapDeviceUID.isEmpty {
            // Mix tap only. Pinning 48 kHz on a Jabra device tap stalls its meter.
            Self.setNominalSampleRate(createdAggregate, RecordingCodec.sampleRate)
        }

        guard reloadFormat() != nil else {
            detachHardware()
            throw SessionRecorderError.invalidTapFormat
        }

        listenForFormatChanges()

        var proc: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { [weak self] _, inInput, _, _, _ in
            self?.write(inInput)
        }
        guard ioStatus == noErr, let proc else {
            detachHardware()
            throw SessionRecorderError.ioFailed(ioStatus)
        }
        ioProcID = proc
    }

    /// `AudioDeviceStart` is when macOS shows the system-audio sheet. Wait for
    /// it off the main thread so a denial is visible before we mark recording.
    private func waitForIOStart() async throws {
        let aggregate = aggregateID
        let proc = ioProcID
        let startStatus: OSStatus = await withCheckedContinuation { continuation in
            queue.async {
                let status = AudioDeviceStart(aggregate, proc)
                continuation.resume(returning: status)
            }
        }
        guard startStatus == noErr else {
            detachHardware()
            log.error("Playback AudioDeviceStart failed (\(startStatus, privacy: .public))")
            throw SessionRecorderError.playbackDenied
        }
        log.info("Playback tap IO started")
    }

    private func detachHardware() {
        removeFormatListener()
        if let proc = ioProcID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        ioProcID = nil
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }

    deinit { stop() }

    private func write(_ input: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard !abl.isEmpty else { return }

        let frames = Self.tapFrameCount(in: abl)
        if !loggedFirstBuffer {
            loggedFirstBuffer = true
            let layout = abl.map { "ch\($0.mNumberChannels):\($0.mDataByteSize)b" }.joined(separator: ",")
            log.info("First playback buffer: buffers=\(abl.count, privacy: .public) layout=\(layout, privacy: .public) stream=\(self.tapStreamIndex, privacy: .public)")
        }
        guard frames > 0 else { return }

        let peak = RecordingDSP.peak(in: abl)
        lock.lock()
        _level = max(peak, _level * 0.65)
        let mixOn = mixEnabled
        let ioFormat = self.ioFormat
        lock.unlock()

        guard mixOn, let ioFormat else { return }
        guard let dest = stereoScratch(frames: frames, format: ioFormat),
              Self.fillStereo(from: abl, into: dest)
        else { return }
        if dest.format.sampleRate != RecordingCodec.sampleRate, mix48 == nil {
            log.info(
                "Playback SRC \(Int(dest.format.sampleRate), privacy: .public) Hz → \(Int(RecordingCodec.sampleRate), privacy: .public) Hz device=\(self.tapDeviceUID, privacy: .public)"
            )
        }
        guard let mixed = RecordingDSP.convertToMixRate(dest, dest: &mix48, using: mixResampler) else { return }
        mixer?.pushPlayback(mixed, source: sourceID)
    }

    private func stereoScratch(frames: AVAudioFrameCount, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if let scratch, scratch.format == format, scratch.frameCapacity >= frames {
            scratch.frameLength = frames
            return scratch
        }
        scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 2048))
        scratch?.frameLength = frames
        return scratch
    }

    private static func frames(in buffer: AudioBuffer) -> AVAudioFrameCount {
        let channels = max(1, Int(buffer.mNumberChannels))
        guard buffer.mDataByteSize > 0 else { return 0 }
        return AVAudioFrameCount(Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size))
    }

    private static func tapFrameCount(in abl: UnsafeMutableAudioBufferListPointer) -> AVAudioFrameCount {
        guard !abl.isEmpty else { return 0 }
        var count = frames(in: abl[0])
        if abl.count > 1 {
            count = min(count, frames(in: abl[1]))
        }
        return count
    }

    @discardableResult
    private static func fillStereo(
        from abl: UnsafeMutableAudioBufferListPointer,
        into dest: AVAudioPCMBuffer
    ) -> Bool {
        let frames = dest.frameLength
        guard frames > 0, let out = dest.floatChannelData else { return false }
        let count = Int(frames)
        let destChannels = Int(dest.format.channelCount)

        if abl.count == 1, let raw = abl[0].mData {
            let src = UnsafeRawPointer(raw).assumingMemoryBound(to: Float.self)
            let srcCh = max(1, Int(abl[0].mNumberChannels))
            if srcCh == 1 {
                out[0].update(from: src, count: count)
                if destChannels > 1 {
                    out[1].update(from: src, count: count)
                }
                return true
            }
            if destChannels > 1 {
                RecordingDSP.deinterleaveStereo(
                    source: src,
                    sourceChannels: srcCh,
                    leftOffset: 0,
                    frames: count,
                    left: out[0],
                    right: out[1]
                )
            } else {
                RecordingDSP.copyStrided(source: src, stride: srcCh, frames: count, dest: out[0])
            }
            return true
        }

        func channel(_ index: Int) -> UnsafePointer<Float>? {
            let srcIndex = min(index, abl.count - 1)
            guard srcIndex >= 0, let raw = abl[srcIndex].mData else { return nil }
            return UnsafeRawPointer(raw).assumingMemoryBound(to: Float.self)
        }
        let left = channel(0)
        let right = channel(1) ?? left
        if let left {
            out[0].update(from: left, count: count)
        }
        if destChannels > 1, let right {
            out[1].update(from: right, count: count)
        }
        return left != nil
    }

    /// First output stream with stereo (or any) channels — HDMI/USB often put the mix off index 0.
    private static func preferredOutputStreamIndex(_ deviceID: AudioDeviceID) -> UInt {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let count = Int(size) / MemoryLayout<AudioStreamID>.size
        var streams = [AudioStreamID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &streams) == noErr else {
            return 0
        }
        var firstWithAudio: UInt = 0
        var foundAudio = false
        for (index, stream) in streams.enumerated() {
            let channels = streamChannelCount(stream)
            if channels >= 2 {
                return UInt(index)
            }
            if !foundAudio, channels > 0 {
                firstWithAudio = UInt(index)
                foundAudio = true
            }
        }
        return foundAudio ? firstWithAudio : 0
    }

    private static func streamChannelCount(_ stream: AudioStreamID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &asbd) == noErr else {
            return 0
        }
        return asbd.mChannelsPerFrame
    }

    @discardableResult
    private func reloadFormat() -> AVAudioFormat? {
        guard tapID != 0 else { return nil }
        do {
            var asbd = try Self.tapStreamFormat(tapID)
            guard let tapFormat = AVAudioFormat(streamDescription: &asbd), tapFormat.channelCount > 0 else {
                return nil
            }
            guard let next = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: tapFormat.sampleRate,
                channels: 2,
                interleaved: false
            ) else { return nil }
            lock.lock()
            let changed = ioFormat?.sampleRate != next.sampleRate
                || ioFormat?.channelCount != next.channelCount
            ioFormat = next
            if changed {
                scratch = nil
                mix48 = nil
                mixResampler.reset()
            }
            lock.unlock()
            if changed {
                log.info(
                    "Playback tap format \(Int(next.sampleRate), privacy: .public) Hz device=\(self.tapDeviceUID, privacy: .public)"
                )
            }
            return next
        } catch {
            return nil
        }
    }

    private func listenForFormatChanges() {
        removeFormatListener()
        guard tapID != 0 else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.reloadFormat()
            self?.ensureRunning()
        }
        formatListener = block
        AudioObjectAddPropertyListenerBlock(tapID, &address, queue, block)
    }

    private func removeFormatListener() {
        guard let block = formatListener, tapID != 0 else {
            formatListener = nil
            return
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(tapID, &address, queue, block)
        formatListener = nil
    }

    /// IO period on the private tap aggregate only. Does not change speaker latency.
    @discardableResult
    private static func setPreferredBufferFrameSize(_ deviceID: AudioDeviceID, _ preferred: UInt32) -> Bool {
        var rangeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var frames = preferred
        var range = AudioValueRange()
        var rangeSize = UInt32(MemoryLayout<AudioValueRange>.size)
        if AudioObjectGetPropertyData(deviceID, &rangeAddress, 0, nil, &rangeSize, &range) == noErr {
            let lo = UInt32(max(1, range.mMinimum.rounded(.up)))
            let hi = UInt32(max(Double(lo), range.mMaximum.rounded(.down)))
            frames = min(max(preferred, lo), hi)
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = frames
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value) == noErr
    }

    @discardableResult
    private static func setNominalSampleRate(_ deviceID: AudioDeviceID, _ rate: Double) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = rate
        let size = UInt32(MemoryLayout<Double>.size)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value) == noErr
    }

    private static func tapStreamFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, asbd.mSampleRate > 0 else {
            throw SessionRecorderError.invalidTapFormat
        }
        return asbd
    }
}
