import AVFoundation
import CoreAudio
import Foundation
import QuartzCore

/// HAL input capture. Mixes only while `captureEnabled`; otherwise peak-only for the monitor.
final class InputDeviceCapture: @unchecked Sendable {
    private let queue: DispatchQueue
    private var deviceID: AudioDeviceID
    private var ioProcID: AudioDeviceIOProcID?
    private var writer: CompressedStemWriter?
    weak var mixer: LiveMixer?
    private var format: AVAudioFormat?
    private var scratch: AVAudioPCMBuffer?
    private var mix48: AVAudioPCMBuffer?
    private let mixResampler = MixRateResampler(channels: 1)
    private let sessionStart: CFTimeInterval
    private var didAlign = false
    private var ioGapStartedAt: CFTimeInterval = 0
    private let lock = NSLock()
    private var _level: Float = 0
    private var _enabled = true
    private let haltQueue = DispatchQueue(label: "com.lockmic.input-capture.halt")
    private static let ioQueueKey = DispatchSpecificKey<UInt8>()
    private var haltScheduled = false

    let fileURL: URL

    var captureEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _enabled }
        set { lock.lock(); _enabled = newValue; lock.unlock() }
    }

    var level: Float {
        lock.lock(); defer { lock.unlock() }
        return RecordingLevelDisplay.fromLinearPeak(_level)
    }

    /// Raw 0…1 peak before the meter dB mapping — for bleed comparison.
    var linearPeak: Float {
        lock.lock(); defer { lock.unlock() }
        return _level
    }

    init(
        deviceID: AudioDeviceID,
        fileURL: URL?,
        sessionStart: CFTimeInterval,
        bitRate: Int,
        startIO: Bool = true
    ) async throws {
        self.deviceID = deviceID
        self.queue = DispatchQueue(label: "com.lockmic.input-capture.\(deviceID)")
        self.queue.setSpecific(key: Self.ioQueueKey, value: 1)
        self.fileURL = fileURL ?? URL(fileURLWithPath: "/dev/null")
        self.sessionStart = sessionStart

        var asbd = try Self.inputStreamFormat(deviceID)
        guard let format = AVAudioFormat(streamDescription: &asbd), format.channelCount > 0 else {
            throw SessionRecorderError.invalidTapFormat
        }
        if let fileURL {
            writer = try CompressedStemWriter(
                url: fileURL,
                channels: 1,
                bitRate: bitRate
            )
        }
        if startIO {
            try await attachIO()
        }
    }

    /// Stop HAL IO so system mute can stick (Jabra unmutes while an IO proc is running).
    func setIORunning(_ on: Bool) {
        haltQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let dead = self.haltScheduled
            self.lock.unlock()
            guard !dead else { return }
            if on {
                if self.ioProcID == nil { try? self.attachIOOnHalt() }
            } else {
                self.detachIOOnHalt()
                self.lock.lock()
                self._level = 0
                self.lock.unlock()
            }
        }
    }

    func retarget(deviceID newID: AudioDeviceID) throws {
        guard newID != deviceID else { return }
        let previous = deviceID
        lock.lock()
        ioGapStartedAt = CACurrentMediaTime()
        lock.unlock()
        var caught: Error?
        haltQueue.sync {
            self.detachIOOnHalt()
            self.mixResampler.reset()
            self.mix48 = nil
            self.scratch = nil
            self.deviceID = newID
            do {
                try self.attachIOOnHalt()
            } catch {
                self.deviceID = previous
                try? self.attachIOOnHalt()
                caught = error
            }
        }
        if let caught { throw caught }
    }

    func stop() {
        scheduleHalt()
        writer?.finish()
        writer = nil
    }

    func waitUntilStopped() async {
        scheduleHalt()
        _ = await AudioHAL.run(on: haltQueue, timeout: AudioHAL.haltSeconds) {}
    }

    deinit { stop() }

    private func scheduleHalt() {
        lock.lock()
        guard !haltScheduled else {
            lock.unlock()
            return
        }
        haltScheduled = true
        lock.unlock()
        // Read ioProcID inside the haltQueue block, not at schedule time: an
        // attachIO() dispatched just before us may still be pending on this
        // same serial queue and hasn't set it yet.
        AudioHAL.haltAsync(on: haltQueue) { [self] in
            self.detachIOOnHalt()
        }
    }

    private func attachIO() async throws {
        let result: Result<Void, Error>? = await AudioHAL.run(on: haltQueue, timeout: AudioHAL.startSeconds) {
            Result { try self.attachIOOnHalt() }
        }
        guard let result else {
            throw SessionRecorderError.ioFailed(-2)
        }
        try result.get()
    }

    private func attachIOOnHalt() throws {
        var asbd = try Self.inputStreamFormat(deviceID)
        guard let format = AVAudioFormat(streamDescription: &asbd), format.channelCount > 0 else {
            throw SessionRecorderError.invalidTapFormat
        }
        self.format = format

        var proc: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, deviceID, queue) { [weak self] _, inInput, _, _, _ in
            self?.write(inInput, format: format)
        }
        guard ioStatus == noErr, let proc else {
            throw SessionRecorderError.ioFailed(ioStatus)
        }
        ioProcID = proc
        let startStatus = AudioDeviceStart(deviceID, proc)
        guard startStatus == noErr else {
            detachIOOnHalt()
            throw SessionRecorderError.ioFailed(startStatus)
        }
        lock.lock()
        let haltedAlready = haltScheduled
        lock.unlock()
        if haltedAlready {
            // scheduleHalt() ran (and found nothing to tear down) before we
            // finished attaching. Don't leave this IO proc running forever.
            detachIOOnHalt()
            throw SessionRecorderError.notRecording
        }
    }

    private func detachIOOnHalt() {
        lock.lock()
        let proc = ioProcID
        let device = deviceID
        ioProcID = nil
        lock.unlock()
        guard let proc else { return }
        AudioDeviceStop(device, proc)
        AudioDeviceDestroyIOProcID(device, proc)
    }

    private func write(_ input: UnsafePointer<AudioBufferList>, format: AVAudioFormat) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard !abl.isEmpty else { return }

        lock.lock()
        let needsSessionAlign = !didAlign
        let gapStart = ioGapStartedAt
        if needsSessionAlign {
            didAlign = true
            ioGapStartedAt = 0
        } else if gapStart > 0 {
            ioGapStartedAt = 0
        }
        let enabled = _enabled
        lock.unlock()

        if needsSessionAlign {
            let delay = max(0, CACurrentMediaTime() - sessionStart)
            if delay > 0.001 {
                writer?.writeSilence(seconds: delay)
            }
        } else if gapStart > 0 {
            let gap = max(0, CACurrentMediaTime() - gapStart)
            if gap > 0.001 {
                writer?.writeSilence(seconds: gap)
            }
        }

        let frames = RecordingSilence.frameCount(in: abl, format: format)
        guard frames > 0 else { return }

        let peak = RecordingDSP.peak(in: abl)
        lock.lock()
        _level = max(peak, _level * 0.65)
        lock.unlock()
        guard enabled else { return }
        guard let dest = scratchBuffer(frames: frames, format: format) else { return }
        RecordingDSP.copy(abl, into: dest)
        dest.frameLength = frames
        writer?.write(dest)
        guard let mixed = RecordingDSP.convertToMixRate(dest, dest: &mix48, using: mixResampler) else { return }
        mixer?.pushMic(mixed)
    }

    private func scratchBuffer(frames: AVAudioFrameCount, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if let scratch, scratch.format == format, scratch.frameCapacity >= frames {
            scratch.frameLength = frames
            return scratch
        }
        scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 2048))
        scratch?.frameLength = frames
        return scratch
    }

    private static func inputStreamFormat(_ deviceID: AudioDeviceID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &asbd)
        guard status == noErr, asbd.mSampleRate > 0 else {
            throw SessionRecorderError.invalidTapFormat
        }
        return asbd
    }
}
