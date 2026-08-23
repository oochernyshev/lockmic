import AVFoundation
import CoreAudio
import Foundation
import QuartzCore

/// HAL input capture for the selected microphone. One writer; `retarget` moves IO to another device.
final class InputDeviceCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.lockmic.input-capture")
    private var deviceID: AudioDeviceID
    private var ioProcID: AudioDeviceIOProcID?
    private var writer: CompressedStemWriter?
    weak var mixer: LiveMixer?
    private var format: AVAudioFormat?
    private var scratch: AVAudioPCMBuffer?
    private let sessionStart: CFTimeInterval
    private var didAlign = false
    private var ioGapStartedAt: CFTimeInterval = 0
    private let lock = NSLock()
    private var _level: Float = 0
    private var _enabled = true

    let fileURL: URL

    var captureEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _enabled }
        set { lock.lock(); _enabled = newValue; lock.unlock() }
    }

    var level: Float {
        lock.lock(); defer { lock.unlock() }
        return RecordingLevelDisplay.fromLinearPeak(_level)
    }

    init(deviceID: AudioDeviceID, fileURL: URL?, sessionStart: CFTimeInterval, bitRate: Int) throws {
        self.deviceID = deviceID
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
        try attachIO()
    }

    func retarget(deviceID newID: AudioDeviceID) throws {
        guard newID != deviceID else { return }
        let previous = deviceID
        lock.lock()
        ioGapStartedAt = CACurrentMediaTime()
        lock.unlock()
        detachIO()
        deviceID = newID
        do {
            try attachIO()
        } catch {
            deviceID = previous
            try? attachIO()
            throw error
        }
    }

    func stop() {
        detachIO()
        writer?.finish()
        writer = nil
    }

    deinit { stop() }

    private func attachIO() throws {
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
            detachIO()
            throw SessionRecorderError.ioFailed(startStatus)
        }
    }

    private func detachIO() {
        if let proc = ioProcID {
            AudioDeviceStop(deviceID, proc)
            AudioDeviceDestroyIOProcID(deviceID, proc)
        }
        ioProcID = nil
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

        if enabled {
            let peak = RecordingDSP.peak(in: abl)
            lock.lock()
            _level = max(peak, _level * 0.65)
            lock.unlock()
            if mixer?.pushMic(abl, format: format) == true {
                return
            }
            guard let dest = scratchBuffer(frames: frames, format: format) else { return }
            RecordingDSP.copy(abl, into: dest)
            dest.frameLength = frames
            writer?.write(dest)
            mixer?.pushMic(dest)
            return
        }

        lock.lock()
        _level *= 0.65
        lock.unlock()
        writer?.padSilence(inputFrames: frames, sampleRate: format.sampleRate)
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
