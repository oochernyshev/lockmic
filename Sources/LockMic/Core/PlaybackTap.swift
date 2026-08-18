import AVFoundation
import CoreAudio
import Foundation
import os.log
import QuartzCore

private let log = Logger(subsystem: "com.lockmic.app", category: "PlaybackTap")

protocol PlaybackCapturing: AnyObject {
    func stop()
    var captureEnabled: Bool { get set }
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
    private var writer: CompressedStemWriter?
    private var scratch: AVAudioPCMBuffer?
    private var loggedFirstBuffer = false
    private let sessionStart: CFTimeInterval
    private let bitRate: Int
    private var tapScope: PlaybackRecordScope = .default
    private var tapStreamIndex: UInt = 0
    private var didAlignToSession = false
    private let lock = NSLock()
    private var _level: Float = 0
    private var _enabled = true

    var captureEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _enabled }
        set { lock.lock(); _enabled = newValue; lock.unlock() }
    }

    var level: Float {
        lock.lock(); defer { lock.unlock() }
        return RecordingLevelDisplay.fromLinearPeak(_level)
    }

    init(
        audio: AudioDeviceService,
        scope: PlaybackRecordScope,
        fileURL: URL,
        sessionStart: CFTimeInterval,
        bitRate: Int
    ) async throws {
        self.sessionStart = sessionStart
        self.bitRate = bitRate
        self.tapScope = scope
        try attachHardware(using: audio, fileURL: fileURL, scope: scope)
        try await waitForIOStart()
    }

    func retarget(using audio: AudioDeviceService, scope: PlaybackRecordScope? = nil) throws {
        detachHardware()
        try attachHardware(using: audio, fileURL: nil, scope: scope)
        let aggregate = aggregateID
        let proc = ioProcID
        queue.async {
            _ = AudioDeviceStart(aggregate, proc)
        }
    }

    func stop() {
        detachHardware()
        writer?.finish()
        writer = nil
    }

    private func attachHardware(
        using audio: AudioDeviceService,
        fileURL: URL?,
        scope: PlaybackRecordScope?
    ) throws {
        if let scope {
            tapScope = scope
        }
        let outputID = try audio.defaultOutputDeviceID()
        guard !audio.isLockMicRecorder(outputID), let outputUID = audio.deviceUID(outputID) else {
            throw AudioDeviceServiceError.propertyFailed("output UID")
        }

        var exclude: [AudioObjectID] = []
        if let selfProcess = audio.processObjectID(for: ProcessInfo.processInfo.processIdentifier) {
            exclude.append(selfProcess)
        }

        // Device-bound tap must not also list that device as a sub-device —
        // that pair hangs a mixdown on the speakers.
        let description: CATapDescription
        if tapScope == .all {
            tapStreamIndex = 0
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        } else {
            tapStreamIndex = Self.preferredOutputStreamIndex(outputID)
            description = CATapDescription(
                excludingProcesses: exclude,
                deviceUID: outputUID,
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
                    kAudioSubTapDriftCompensationKey: 0,
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

        var asbd = try Self.tapStreamFormat(createdTap)
        guard let tapFormat = AVAudioFormat(streamDescription: &asbd), tapFormat.channelCount > 0 else {
            detachHardware()
            throw SessionRecorderError.invalidTapFormat
        }
        // Stem stays stereo so a 1-channel tap does not crash fill and mix stays aligned.
        guard let ioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: tapFormat.sampleRate,
            channels: 2,
            interleaved: false
        ) else {
            detachHardware()
            throw SessionRecorderError.invalidTapFormat
        }
        if writer == nil, let fileURL {
            log.info(
                "Playback write format AAC \(ioFormat.sampleRate, privacy: .public) Hz tap=\(tapFormat.sampleRate, privacy: .public)/\(tapFormat.channelCount, privacy: .public)ch stream=\(self.tapStreamIndex, privacy: .public) scope=\(String(describing: self.tapScope), privacy: .public)"
            )
            writer = try CompressedStemWriter(
                url: fileURL,
                channels: 2,
                bitRate: bitRate,
                sampleRate: ioFormat.sampleRate
            )
        }

        var proc: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { [weak self] _, inInput, _, _, _ in
            self?.write(inInput, ioFormat: ioFormat)
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

    private func write(_ input: UnsafePointer<AudioBufferList>, ioFormat: AVAudioFormat) {
        guard let writer else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard !abl.isEmpty else { return }

        if !didAlignToSession {
            didAlignToSession = true
            let delay = max(0, CACurrentMediaTime() - sessionStart)
            if delay > 0.001 {
                writer.writeSilence(seconds: delay)
                log.info("Aligned playback with \(String(format: "%.3f", delay), privacy: .public)s of leading silence")
            }
        }

        let frames = Self.tapFrameCount(in: abl)
        lock.lock()
        let enabled = _enabled
        lock.unlock()

        if !loggedFirstBuffer {
            loggedFirstBuffer = true
            let layout = abl.map { "ch\($0.mNumberChannels):\($0.mDataByteSize)b" }.joined(separator: ",")
            log.info("First playback buffer: buffers=\(abl.count, privacy: .public) layout=\(layout, privacy: .public) stream=\(self.tapStreamIndex, privacy: .public)")
        }

        guard frames > 0 else { return }
        if !enabled {
            lock.lock()
            _level *= 0.65
            lock.unlock()
            writer.padSilence(inputFrames: frames, sampleRate: ioFormat.sampleRate)
            return
        }
        guard let dest = stereoScratch(frames: frames, format: ioFormat),
              Self.fillStereo(from: abl, into: dest)
        else {
            writer.padSilence(inputFrames: frames, sampleRate: ioFormat.sampleRate)
            return
        }
        let peak = RecordingDSP.peak(in: dest)
        lock.lock()
        _level = max(peak, _level * 0.65)
        lock.unlock()
        writer.write(dest)
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
