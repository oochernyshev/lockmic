import AVFoundation
import CoreAudio
import Foundation
import os.log

private let log = Logger(subsystem: "com.lockmic.app", category: "PlaybackTap")

protocol PlaybackCapturing: AnyObject {
    func stop()
    func waitUntilStopped() async
    /// Core Audio stops IO procs after an output sample-rate change (Jabra 48→16 kHz).
    func ensureRunning()
    func setMixEnabled(_ on: Bool)
    var level: Float { get }
    /// `kAudioTapPropertyFormat` — can be 16 kHz (VPIO) while the speakers stay at 48 kHz.
    var sourceSampleRate: Double { get }
    var isNarrowband: Bool { get }
    /// Sample rate of the buffers we mix, after the private aggregate.
    var mixSampleRate: Double { get }
    var isMixNarrowband: Bool { get }
    var streamIndex: UInt { get }
    var onFormatChange: (() -> Void)? { get set }
}

// MARK: - Playback tap (system audio)

/// Private tap-only aggregate. Do not put the output UID in the composition.
@available(macOS 14.2, *)
final class PlaybackTap: PlaybackCapturing, @unchecked Sendable {
    /// IO callbacks only. Start/Stop/Destroy run on `haltQueue`.
    private let queue = DispatchQueue(label: "com.lockmic.playback-tap", qos: .userInitiated)
    private static let ioQueueKey = DispatchSpecificKey<UInt8>()
    /// Per tap so a hung Destroy cannot block Start on another output.
    private let haltQueue = DispatchQueue(label: "com.lockmic.playback-tap.halt")
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
    private var _sourceSampleRate: Double = 0
    private var _onFormatChange: (() -> Void)?
    private var stopped = false
    private var haltScheduled = false

    var level: Float {
        lock.lock(); defer { lock.unlock() }
        return RecordingLevelDisplay.fromLinearPeak(_level)
    }

    var sourceSampleRate: Double {
        lock.lock(); defer { lock.unlock() }
        return _sourceSampleRate
    }

    var isNarrowband: Bool {
        let rate = sourceSampleRate
        return rate > 0 && rate < 44_100
    }

    var mixSampleRate: Double {
        lock.lock(); defer { lock.unlock() }
        return ioFormat?.sampleRate ?? 0
    }

    var isMixNarrowband: Bool {
        let rate = mixSampleRate
        return rate > 0 && rate < 44_100
    }

    var streamIndex: UInt { tapStreamIndex }

    var onFormatChange: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onFormatChange }
        set { lock.lock(); _onFormatChange = newValue; lock.unlock() }
    }

    init(audio: AudioDeviceService, deviceUID: String?) async throws {
        self.sourceID = deviceUID ?? PlaybackMix.systemSourceID
        self.tapDeviceUID = deviceUID ?? ""
        queue.setSpecific(key: Self.ioQueueKey, value: 1)
        do {
            try await attachHardware(using: audio)
            try await startIO()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        scheduleHalt()
    }

    func waitUntilStopped() async {
        scheduleHalt()
        _ = await AudioHAL.run(on: haltQueue, timeout: AudioHAL.haltSeconds) {}
    }

    private func scheduleHalt() {
        lock.lock()
        stopped = true
        guard !haltScheduled else {
            lock.unlock()
            return
        }
        haltScheduled = true
        lock.unlock()

        let listenerQueue = queue
        // Read the IDs inside the haltQueue block, not at schedule time: an
        // attachHardwareOnHalt()/startIO() dispatched just before us may still
        // be pending on this same serial queue and hasn't set them yet.
        AudioHAL.haltAsync(on: haltQueue) { [self] in
            self.lock.lock()
            let proc = self.ioProcID
            let aggregate = self.aggregateID
            let tap = self.tapID
            let listener = self.formatListener
            self.ioProcID = nil
            self.aggregateID = 0
            self.tapID = 0
            self.formatListener = nil
            self.lock.unlock()
            Self.halt(
                proc: proc,
                aggregate: aggregate,
                tap: tap,
                listener: listener,
                listenerQueue: listenerQueue
            )
        }
    }

    /// Stop/Destroy must not run on the IO queue (HAL can `dispatch_sync` onto it).
    private static func halt(
        proc: AudioDeviceIOProcID?,
        aggregate: AudioDeviceID,
        tap: AudioObjectID,
        listener: AudioObjectPropertyListenerBlock?,
        listenerQueue: DispatchQueue
    ) {
        if let listener, tap != 0 {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(tap, &address, listenerQueue, listener)
        }
        if let proc, aggregate != 0 {
            AudioDeviceStop(aggregate, proc)
            AudioDeviceDestroyIOProcID(aggregate, proc)
        }
        if aggregate != 0 {
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != 0 {
            AudioHardwareDestroyProcessTap(tap)
        }
    }

    func setMixEnabled(_ on: Bool) {
        lock.lock()
        mixEnabled = on
        lock.unlock()
    }

    func ensureRunning() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        let aggregate = aggregateID
        let proc = ioProcID
        let pinMixRate = tapDeviceUID.isEmpty
        lock.unlock()
        guard aggregate != 0, let proc else { return }
        if pinMixRate {
            Self.setNominalSampleRate(aggregate, RecordingCodec.sampleRate)
        }
        reloadFormat()
        // Start on haltQueue, never the IO queue — HAL Start there deadlocks.
        haltQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let live = !self.stopped && self.aggregateID == aggregate && self.ioProcID != nil
            self.lock.unlock()
            guard live else { return }
            let status = AudioDeviceStart(aggregate, proc)
            if status != noErr {
                log.error(
                    "Playback tap restart failed (\(status, privacy: .public)) device=\(self.tapDeviceUID, privacy: .public)"
                )
            }
        }
    }

    private func attachHardware(using audio: AudioDeviceService) async throws {
        let result: Result<Void, Error>? = await AudioHAL.run(on: haltQueue, timeout: AudioHAL.startSeconds) {
            Result { try self.attachHardwareOnHalt(using: audio) }
        }
        guard let result else {
            stop()
            throw SessionRecorderError.ioFailed(-2)
        }
        try result.get()
    }

    private func attachHardwareOnHalt(using audio: AudioDeviceService) throws {
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
            stop()
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
            stop()
            throw SessionRecorderError.invalidTapFormat
        }

        listenForFormatChanges()

        var proc: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { [weak self] _, inInput, _, _, _ in
            self?.write(inInput)
        }
        guard ioStatus == noErr, let proc else {
            stop()
            throw SessionRecorderError.ioFailed(ioStatus)
        }
        ioProcID = proc

        lock.lock()
        let haltedAlready = haltScheduled
        let aggregate = aggregateID
        let tap = tapID
        let listener = formatListener
        if haltedAlready {
            ioProcID = nil
            aggregateID = 0
            tapID = 0
            formatListener = nil
        }
        lock.unlock()
        guard haltedAlready else { return }
        // scheduleHalt() already ran (and found nothing to tear down, since we
        // hadn't set these fields yet) before we finished attaching. stop()
        // is now a no-op, so tear down directly.
        Self.halt(proc: proc, aggregate: aggregate, tap: tap, listener: listener, listenerQueue: queue)
        throw SessionRecorderError.notRecording
    }

    /// `AudioDeviceStart` is when macOS shows the system-audio sheet. Never call
    /// it on the IO queue — HAL Start there deadlocks.
    private func startIO() async throws {
        let startStatus = await AudioHAL.run(on: haltQueue, timeout: AudioHAL.startSeconds) { () -> OSStatus in
            let aggregate = self.aggregateID
            guard aggregate != 0, let proc = self.ioProcID else { return -1 }
            return AudioDeviceStart(aggregate, proc)
        }
        guard let startStatus else {
            stop()
            log.error("Playback AudioDeviceStart timed out")
            throw SessionRecorderError.playbackDenied
        }
        guard startStatus == noErr else {
            stop()
            log.error("Playback AudioDeviceStart failed (\(startStatus, privacy: .public))")
            throw SessionRecorderError.playbackDenied
        }
        log.info("Playback tap IO started")
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

    /// Highest-rate output stream (stereo preferred). Call/VPIO often adds a 16 kHz
    /// stream at index 0 while media stays on another stream at 48 kHz.
    static func preferredOutputStreamIndex(_ deviceID: AudioDeviceID) -> UInt {
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
        var bestIndex: UInt = 0
        var bestScore: Double = -1
        for (index, stream) in streams.enumerated() {
            guard let asbd = streamVirtualFormat(stream), asbd.mChannelsPerFrame > 0 else { continue }
            let wide: Double = asbd.mSampleRate >= 44_100 ? 1_000_000 : 0
            let stereo: Double = asbd.mChannelsPerFrame >= 2 ? 1_000 : 0
            let score = wide + stereo + asbd.mSampleRate
            if score > bestScore {
                bestScore = score
                bestIndex = UInt(index)
            }
        }
        return bestIndex
    }

    private static func streamVirtualFormat(_ stream: AudioStreamID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &asbd) == noErr else {
            return nil
        }
        return asbd
    }

    @discardableResult
    private func reloadFormat() -> AVAudioFormat? {
        lock.lock()
        let tap = tapID
        let aggregate = aggregateID
        let pinMixRate = tapDeviceUID.isEmpty
        let live = !stopped && tap != 0
        lock.unlock()
        guard live else { return nil }
        if pinMixRate, aggregate != 0 {
            Self.setNominalSampleRate(aggregate, RecordingCodec.sampleRate)
        }
        do {
            let tapASBD = try Self.tapStreamFormat(tap)
            let ioRate: Double
            if let aggregateASBD = Self.aggregateIOFormat(aggregate), aggregateASBD.mSampleRate > 0 {
                ioRate = aggregateASBD.mSampleRate
            } else {
                ioRate = tapASBD.mSampleRate
            }
            guard ioRate > 0 else { return nil }
            guard let next = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: ioRate,
                channels: 2,
                interleaved: false
            ) else { return nil }
            lock.lock()
            guard !stopped else {
                lock.unlock()
                return nil
            }
            let sourceChanged = _sourceSampleRate != tapASBD.mSampleRate
            let ioChanged = ioFormat?.sampleRate != next.sampleRate
                || ioFormat?.channelCount != next.channelCount
            _sourceSampleRate = tapASBD.mSampleRate
            ioFormat = next
            if ioChanged {
                scratch = nil
                mix48 = nil
                mixResampler.reset()
            }
            lock.unlock()
            if sourceChanged || ioChanged {
                log.info(
                    "Playback tap source \(Int(tapASBD.mSampleRate), privacy: .public) Hz IO \(Int(ioRate), privacy: .public) Hz device=\(self.tapDeviceUID, privacy: .public)"
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
            self?.onFormatChange?()
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

    private static func aggregateIOFormat(_ deviceID: AudioDeviceID) -> AudioStreamBasicDescription? {
        guard deviceID != 0 else { return nil }
        let scopes: [AudioObjectPropertyScope] = [
            kAudioDevicePropertyScopeInput,
            kAudioObjectPropertyScopeGlobal,
            kAudioDevicePropertyScopeOutput,
        ]
        for scope in scopes {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamFormat,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &asbd) == noErr,
               asbd.mSampleRate > 0
            {
                return asbd
            }
        }
        return nil
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
