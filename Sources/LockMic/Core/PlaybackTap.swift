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

/// Private aggregate = default output (clock) + process tap. Never changes the system default device.
@available(macOS 14.2, *)
final class PlaybackTap: PlaybackCapturing {
    /// Non-nil queue is required — `nil` silently fails to register the IO block on macOS 26.
    private let queue = DispatchQueue(label: "com.lockmic.playback-tap", qos: .userInteractive)
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var writer: CompressedStemWriter?
    private var loggedFirstBuffer = false
    private let sessionStart: CFTimeInterval
    private let bitRate: Int
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
        try attachHardware(using: audio, fileURL: fileURL, scope: scope)
        try await waitForIOStart()
    }

    func retarget(using audio: AudioDeviceService) throws {
        detachHardware()
        try attachHardware(using: audio, fileURL: nil, scope: nil)
        let aggregate = aggregateID
        let proc = ioProcID
        let outputRate = pendingOutputRate
        let outputID = pendingOutputID
        queue.async {
            let status = AudioDeviceStart(aggregate, proc)
            if status == noErr, let outputRate {
                Self.setNominalSampleRate(outputID, outputRate)
            }
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
        let outputID = try audio.defaultOutputDeviceID()
        guard !audio.isLockMicRecorder(outputID), let outputUID = audio.deviceUID(outputID) else {
            throw AudioDeviceServiceError.propertyFailed("output UID")
        }
        // Keep whatever rate the speakers already use. Binding a tap to the
        // hardware device (deviceUID) or letting the aggregate pick 48 kHz
        // inserts a resampler on the live output and the music sounds worse.
        let outputRate = Self.nominalSampleRate(outputID)

        var exclude: [AudioObjectID] = []
        if let selfProcess = audio.processObjectID(for: ProcessInfo.processInfo.processIdentifier) {
            exclude.append(selfProcess)
        }

        // Process-level tap only — do not set `deviceUID` or Core Audio hangs
        // a mixdown on the output device itself.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
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

        // Output device must be the main sub-device. Tap-only aggregates
        // (empty subdevice list) produce silent buffers.
        // HAL wants CFNumber for these flags — a Swift `Bool` becomes CFBoolean
        // and the aggregate is published as a public “LockMic Recorder” device.
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LockMic Recorder",
            kAudioAggregateDeviceUIDKey: "com.lockmic.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            // 0 so AudioDeviceStart returns after the TCC prompt instead of
            // waiting for the first tapped buffer (which hung Start Recording).
            kAudioAggregateDeviceTapAutoStartKey: 0,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID],
            ],
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
        if let outputRate {
            Self.setNominalSampleRate(createdAggregate, outputRate)
            Self.setNominalSampleRate(outputID, outputRate)
        }

        let ioRate = outputRate ?? Self.nominalSampleRate(aggregateID) ?? 48_000
        guard let ioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: ioRate,
            channels: 2,
            interleaved: false
        ) else {
            detachHardware()
            throw SessionRecorderError.invalidTapFormat
        }
        if writer == nil, let fileURL {
            log.info("Playback write format AAC \(ioFormat.sampleRate, privacy: .public) Hz scope=\(String(describing: scope), privacy: .public)")
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
        pendingOutputRate = outputRate
        pendingOutputID = outputID
    }

    private var pendingOutputRate: Double?
    private var pendingOutputID: AudioDeviceID = 0

    /// `AudioDeviceStart` is when macOS shows the system-audio sheet. Wait for
    /// it off the main thread so a denial is visible before we mark recording.
    private func waitForIOStart() async throws {
        let aggregate = aggregateID
        let proc = ioProcID
        let outputRate = pendingOutputRate
        let outputID = pendingOutputID
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
        if let outputRate {
            Self.setNominalSampleRate(outputID, outputRate)
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

    /// Writes tap channels only. The aggregate may also expose the clock device's
    /// inputs (built-in speakers share a device ID with the built-in mic).
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

        let peak = Self.tapPeak(in: abl)
        lock.lock()
        _level = max(peak, _level * 0.65)
        let enabled = _enabled
        lock.unlock()

        if !loggedFirstBuffer {
            loggedFirstBuffer = true
            let layout = abl.map { "ch\($0.mNumberChannels):\($0.mDataByteSize)b" }.joined(separator: ",")
            log.info("First playback buffer: buffers=\(abl.count, privacy: .public) layout=\(layout, privacy: .public) peak=\(peak, privacy: .public)")
        }

        if !enabled {
            let frames = Self.tapFrameCount(in: abl)
            writer.writeSilence(seconds: Double(frames) / ioFormat.sampleRate)
            return
        }
        guard let raw = Self.stereoBuffer(from: abl, format: ioFormat) else { return }
        writer.write(raw)
    }

    /// Tap streams are last. Earlier buffers are often the clock device's mic.
    private static func tapStartIndex(in abl: UnsafeMutableAudioBufferListPointer) -> Int {
        max(0, abl.count - 2)
    }

    private static func frames(in buffer: AudioBuffer) -> AVAudioFrameCount {
        let channels = max(1, Int(buffer.mNumberChannels))
        guard buffer.mDataByteSize > 0 else { return 0 }
        return AVAudioFrameCount(Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size))
    }

    private static func tapFrameCount(in abl: UnsafeMutableAudioBufferListPointer) -> AVAudioFrameCount {
        let start = tapStartIndex(in: abl)
        guard start < abl.count else { return 0 }
        var count = frames(in: abl[start])
        if start + 1 < abl.count {
            count = min(count, frames(in: abl[start + 1]))
        }
        return count
    }

    private static func stereoBuffer(
        from abl: UnsafeMutableAudioBufferListPointer,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let frames = tapFrameCount(in: abl)
        guard frames > 0, let dest = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        dest.frameLength = frames
        guard let out = dest.floatChannelData else { return nil }
        let count = Int(frames)

        if abl.count == 1, abl[0].mNumberChannels >= 2, let raw = abl[0].mData {
            let src = UnsafeRawPointer(raw).assumingMemoryBound(to: Float.self)
            let srcCh = Int(abl[0].mNumberChannels)
            // Extra channels on a speaker/mic combo are inputs — take the tap pair.
            let tapOffset = srcCh >= 4 ? srcCh - 2 : 0
            for i in 0..<count {
                out[0][i] = src[i * srcCh + tapOffset]
                out[1][i] = src[i * srcCh + min(tapOffset + 1, srcCh - 1)]
            }
            return dest
        }

        let start = tapStartIndex(in: abl)
        func channel(_ index: Int) -> UnsafePointer<Float>? {
            let srcIndex = min(start + index, abl.count - 1)
            guard let raw = abl[srcIndex].mData else { return nil }
            return UnsafeRawPointer(raw).assumingMemoryBound(to: Float.self)
        }
        let left = channel(0)
        let right = channel(1) ?? left
        if let left {
            out[0].update(from: left, count: count)
        }
        if let right {
            out[1].update(from: right, count: count)
        }
        return dest
    }

    @discardableResult
    private static func setNominalSampleRate(_ deviceID: AudioDeviceID, _ rate: Double) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = Float64(rate)
        let size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value) == noErr
    }

    private static func nominalSampleRate(_ deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        guard status == noErr, rate > 0 else { return nil }
        return rate
    }

    private static func tapPeak(in abl: UnsafeMutableAudioBufferListPointer) -> Float {
        var peak: Float = 0
        let start = tapStartIndex(in: abl)
        guard start < abl.count else { return 0 }
        for index in start..<abl.count {
            let buffer = abl[index]
            guard let raw = buffer.mData else { continue }
            let count = Int(frames(in: buffer)) * max(1, Int(buffer.mNumberChannels))
            let samples = UnsafeRawPointer(raw).assumingMemoryBound(to: Float.self)
            for i in 0..<count {
                peak = max(peak, abs(samples[i]))
            }
        }
        return peak
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
