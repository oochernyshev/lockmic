import Accelerate
import AVFoundation
import CoreAudio
import Foundation
import os.log
import QuartzCore

private let log = Logger(subsystem: "com.lockmic.app", category: "RecordingCapture")

enum RecordingDeviceKind: Equatable, Sendable {
    case input
    case output
}

struct RecordingDeviceRow: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let kind: RecordingDeviceKind
    let isDefault: Bool
    let isVirtual: Bool
    /// Hardware exists but we cannot open a dedicated capture (virtual / failed).
    let canCapture: Bool
    var isEnabled: Bool
    var level: Float
    var detail: String?
}

struct StemGate: Sendable, Codable {
    var events: [(TimeInterval, Bool)]

    init(events: [(TimeInterval, Bool)]) {
        self.events = events
    }

    func enabled(at time: TimeInterval) -> Bool {
        var on = true
        for (at, enabled) in events where at <= time {
            on = enabled
        }
        return on
    }

    mutating func append(_ enabled: Bool, at time: TimeInterval) {
        events.append((max(0, time), enabled))
    }

    var wasEverEnabled: Bool {
        events.contains { $0.1 }
    }

    private enum CodingKeys: String, CodingKey {
        case events
    }

    private struct Event: Codable {
        var at: TimeInterval
        var enabled: Bool
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        events = try container.decode([Event].self, forKey: .events).map { ($0.at, $0.enabled) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(events.map { Event(at: $0.0, enabled: $0.1) }, forKey: .events)
    }
}

struct MixGates: Sendable, Codable {
    var microphone: StemGate
    var playback: StemGate
    var extras: [String: StemGate]
}

/// Shared 0…1 meter scale so HAL peaks and AVAudioRecorder dB match on the wave.
enum RecordingLevelDisplay {
    static let noiseFloorDB: Float = -38
    static let fullScaleDB: Float = -6

    static func fromAverageDB(_ db: Float) -> Float {
        min(1, max(0, (db - noiseFloorDB) / (fullScaleDB - noiseFloorDB)))
    }

    static func fromLinearPeak(_ peak: Float) -> Float {
        let p = min(1, max(0, peak))
        guard p > 0.0002 else { return 0 }
        return fromAverageDB(20 * log10(p))
    }
}

/// Hot-path DSP for capture IO. Avoid per-sample Swift loops and extra allocations.
enum RecordingDSP {
    static func peak(in buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else {
            return peak(in: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList))
        }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var peak: Float = 0
        for ch in 0..<Int(buffer.format.channelCount) {
            var channelPeak: Float = 0
            vDSP_maxmgv(channels[ch], 1, &channelPeak, vDSP_Length(frames))
            peak = max(peak, channelPeak)
        }
        return min(1, peak)
    }

    static func peak(in abl: UnsafeMutableAudioBufferListPointer) -> Float {
        var peak: Float = 0
        for buffer in abl {
            guard let raw = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            var channelPeak: Float = 0
            vDSP_maxmgv(raw.assumingMemoryBound(to: Float.self), 1, &channelPeak, vDSP_Length(count))
            peak = max(peak, channelPeak)
        }
        return min(1, peak)
    }

    static func copy(_ abl: UnsafeMutableAudioBufferListPointer, into dest: AVAudioPCMBuffer) {
        let dst = UnsafeMutableAudioBufferListPointer(dest.mutableAudioBufferList)
        for (from, to) in zip(abl, dst) {
            guard let source = from.mData, let destPtr = to.mData else { continue }
            memcpy(destPtr, source, min(Int(from.mDataByteSize), Int(to.mDataByteSize)))
        }
    }

    static func copyStrided(
        source: UnsafePointer<Float>,
        stride: Int,
        frames: Int,
        dest: UnsafeMutablePointer<Float>
    ) {
        guard frames > 0, stride > 0 else { return }
        cblas_scopy(Int32(frames), source, Int32(stride), dest, 1)
    }

    static func deinterleaveStereo(
        source: UnsafePointer<Float>,
        sourceChannels: Int,
        leftOffset: Int,
        frames: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>
    ) {
        guard frames > 0, sourceChannels > 0 else { return }
        copyStrided(source: source + leftOffset, stride: sourceChannels, frames: frames, dest: left)
        let rightOffset = min(leftOffset + 1, sourceChannels - 1)
        copyStrided(source: source + rightOffset, stride: sourceChannels, frames: frames, dest: right)
    }
}

/// AAC bitrate for recorded files.
enum RecordingBitRate: Int, CaseIterable, Equatable, Sendable {
    case kbps48 = 48
    case kbps64 = 64
    case kbps96 = 96
    case kbps128 = 128
    case kbps160 = 160

    static let `default` = kbps128

    var bitsPerSecond: Int { rawValue * 1_000 }

    func estimatedSessionBytes(duration: TimeInterval) -> Int64 {
        Int64((Double(bitsPerSecond) / 8) * duration)
    }

    func formattedSessionSize(duration: TimeInterval) -> String {
        Self.sizeFormatter.string(fromByteCount: estimatedSessionBytes(duration: duration))
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()

    static func resolved(_ stored: Int) -> RecordingBitRate {
        RecordingBitRate(rawValue: stored) ?? .default
    }
}

/// AAC settings for recording stems. Uncompressed float CAF is ~1.3 GB/hour stereo;
/// 128 kbps AAC is ~55 MB for the same hour.
enum RecordingCodec {
    static let sampleRate: Double = 48_000

    static func aacSampleRate(nearest rate: Double) -> Double {
        let allowed: [Double] = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000]
        return allowed.min(by: { abs($0 - rate) < abs($1 - rate) }) ?? sampleRate
    }

    static func aacSettings(
        channels: AVAudioChannelCount,
        bitRate: Int,
        sampleRate: Double = sampleRate
    ) -> [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVEncoderBitRateKey: bitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
    }

    static func pcmFormat(channels: AVAudioChannelCount, sampleRate: Double = sampleRate) -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
    }
}

/// Encodes PCM to AAC off the HAL thread. IO copies into ~170 ms batches;
/// disabled time is one silence pad on resume or finish.
final class CompressedStemWriter: @unchecked Sendable {
    private let queue: DispatchQueue
    private var file: AVAudioFile?
    let writeFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var converterFromRate: Double = 0
    private var converterFromChannels: AVAudioChannelCount = 0
    private var leftover: AVAudioPCMBuffer?
    private var convertDest: AVAudioPCMBuffer?
    private var silenceChunk: AVAudioPCMBuffer?
    private let chunkFrames: AVAudioFrameCount = 8192
    private let ioLock = NSLock()
    private var ioBatch: AVAudioPCMBuffer?
    private var freeBatches: [AVAudioPCMBuffer] = []
    private var ioPendingSilenceFrames: AVAudioFrameCount = 0
    private var pendingSilenceFrames: AVAudioFrameCount = 0

    init(url: URL, channels: AVAudioChannelCount, bitRate: Int, sampleRate: Double = RecordingCodec.sampleRate) throws {
        let rate = RecordingCodec.aacSampleRate(nearest: sampleRate)
        writeFormat = RecordingCodec.pcmFormat(channels: channels, sampleRate: rate)
        queue = DispatchQueue(label: "com.lockmic.stem-write.\(url.lastPathComponent)", qos: .userInitiated)
        try? FileManager.default.removeItem(at: url)
        file = try AVAudioFile(
            forWriting: url,
            settings: RecordingCodec.aacSettings(channels: channels, bitRate: bitRate, sampleRate: rate),
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    /// Copies `buffer` into a recycled batch. Safe if HAL reuses the source after return.
    func write(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        ioLock.lock()
        var offset: AVAudioFrameCount = 0
        while offset < buffer.frameLength {
            if ioBatch == nil || !Self.sameProcessingFormat(ioBatch!.format, buffer.format) {
                if let old = ioBatch, old.frameLength > 0 {
                    enqueueBatchLocked(old)
                }
                ioBatch = obtainBatchLocked(format: buffer.format)
                ioBatch?.frameLength = 0
            }
            guard let batch = ioBatch else {
                ioLock.unlock()
                return
            }
            let take = min(batch.frameCapacity - batch.frameLength, buffer.frameLength - offset)
            Self.copyFrames(from: buffer, at: offset, to: batch, at: batch.frameLength, count: take)
            batch.frameLength += take
            offset += take
            if batch.frameLength >= batch.frameCapacity {
                enqueueBatchLocked(batch)
                ioBatch = nil
            }
        }
        ioLock.unlock()
    }

    func writeSilence(seconds: TimeInterval) {
        let frames = AVAudioFrameCount((seconds * writeFormat.sampleRate).rounded(.toNearestOrAwayFromZero))
        padWriteSilence(frames: frames)
    }

    func writeSilence(frames: AVAudioFrameCount) {
        padWriteSilence(frames: frames)
    }

    /// Accrue HAL frames of silence at `sampleRate` without encoding them yet.
    func padSilence(inputFrames: AVAudioFrameCount, sampleRate: Double) {
        let seconds = Double(inputFrames) / max(1, sampleRate)
        writeSilence(seconds: seconds)
    }

    /// Drain the encoder and close the file so the m4a atom is finalized.
    func finish() {
        flushIOBatch()
        ioLock.lock()
        let trailingSilence = ioPendingSilenceFrames
        ioPendingSilenceFrames = 0
        ioLock.unlock()
        queue.sync {
            pendingSilenceFrames += trailingSilence
            flushPendingSilence()
            flushLeftover()
            file = nil
            converter = nil
            leftover = nil
            convertDest = nil
            silenceChunk = nil
        }
    }

    private func padWriteSilence(frames: AVAudioFrameCount) {
        guard frames > 0 else { return }
        flushIOBatch()
        ioLock.lock()
        ioPendingSilenceFrames += frames
        ioLock.unlock()
    }

    private func flushIOBatch() {
        ioLock.lock()
        let batch = ioBatch
        ioBatch = nil
        if let batch, batch.frameLength > 0 {
            enqueueBatchLocked(batch)
        }
        ioLock.unlock()
    }

    /// Caller must hold `ioLock`.
    private func enqueueBatchLocked(_ batch: AVAudioPCMBuffer) {
        let silence = ioPendingSilenceFrames
        ioPendingSilenceFrames = 0
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingSilenceFrames += silence
            self.flushPendingSilence()
            self.ingest(batch)
            self.recycleBatch(batch)
        }
    }

    private func obtainBatchLocked(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if let index = freeBatches.lastIndex(where: {
            Self.sameProcessingFormat($0.format, format) && $0.frameCapacity >= self.chunkFrames
        }) {
            return freeBatches.remove(at: index)
        }
        if let first = freeBatches.first, !Self.sameProcessingFormat(first.format, format) {
            freeBatches.removeAll(keepingCapacity: true)
        }
        return AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)
    }

    private func recycleBatch(_ batch: AVAudioPCMBuffer) {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard freeBatches.count < 3 else { return }
        if let first = freeBatches.first, !Self.sameProcessingFormat(first.format, batch.format) {
            freeBatches.removeAll(keepingCapacity: true)
        }
        batch.frameLength = 0
        freeBatches.append(batch)
    }

    private func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let pcm = convertStreaming(buffer) else { return }
        append(pcm)
    }

    private func convertStreaming(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if Self.sameProcessingFormat(buffer.format, writeFormat) {
            return buffer
        }
        if converter == nil
            || converterFromRate != buffer.format.sampleRate
            || converterFromChannels != buffer.format.channelCount {
            converter = AVAudioConverter(from: buffer.format, to: writeFormat)
            converterFromRate = buffer.format.sampleRate
            converterFromChannels = buffer.format.channelCount
        }
        guard let converter else { return nil }
        let ratio = writeFormat.sampleRate / max(1, buffer.format.sampleRate)
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        if convertDest == nil || convertDest!.frameCapacity < capacity {
            convertDest = AVAudioPCMBuffer(pcmFormat: writeFormat, frameCapacity: max(capacity, chunkFrames))
        }
        guard let dest = convertDest else { return nil }
        dest.frameLength = 0
        var error: NSError?
        var consumed = false
        // Keep the converter primed — `endOfStream` every HAL slice resets it and clicks.
        converter.convert(to: dest, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return dest.frameLength > 0 ? dest : nil
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        var offset: AVAudioFrameCount = 0
        while offset < buffer.frameLength {
            if leftover == nil {
                leftover = AVAudioPCMBuffer(pcmFormat: writeFormat, frameCapacity: chunkFrames)
                leftover?.frameLength = 0
            }
            guard let dest = leftover else { return }
            let take = min(dest.frameCapacity - dest.frameLength, buffer.frameLength - offset)
            Self.copyFrames(from: buffer, at: offset, to: dest, at: dest.frameLength, count: take)
            dest.frameLength += take
            offset += take
            if dest.frameLength >= dest.frameCapacity {
                writeFile(dest)
                dest.frameLength = 0
            }
        }
    }

    private func appendSilence(frames: AVAudioFrameCount) {
        guard frames > 0 else { return }
        if silenceChunk == nil {
            silenceChunk = AVAudioPCMBuffer(pcmFormat: writeFormat, frameCapacity: chunkFrames)
            if let silenceChunk {
                RecordingSilence.zero(silenceChunk)
            }
        }
        guard let zero = silenceChunk else { return }
        var remaining = frames
        while remaining > 0 {
            let chunk = min(remaining, zero.frameCapacity)
            zero.frameLength = chunk
            append(zero)
            remaining -= chunk
        }
    }

    private func flushPendingSilence() {
        let frames = pendingSilenceFrames
        pendingSilenceFrames = 0
        if frames > 0 {
            appendSilence(frames: frames)
        }
    }

    private func flushLeftover() {
        if let leftover, leftover.frameLength > 0 {
            writeFile(leftover)
            leftover.frameLength = 0
        }
    }

    private func writeFile(_ buffer: AVAudioPCMBuffer) {
        guard let file, buffer.frameLength > 0 else { return }
        do {
            try file.write(from: buffer)
        } catch {
            log.error("AAC write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func sameProcessingFormat(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate
            && a.channelCount == b.channelCount
            && a.commonFormat == b.commonFormat
            && a.isInterleaved == b.isInterleaved
    }

    private static func copyFrames(
        from src: AVAudioPCMBuffer,
        at srcOff: AVAudioFrameCount,
        to dst: AVAudioPCMBuffer,
        at dstOff: AVAudioFrameCount,
        count: AVAudioFrameCount
    ) {
        guard count > 0 else { return }
        if let samples = src.floatChannelData, let dest = dst.floatChannelData {
            let n = Int(count)
            let channels = min(Int(src.format.channelCount), Int(dst.format.channelCount))
            for ch in 0..<channels {
                (dest[ch] + Int(dstOff)).update(from: samples[ch] + Int(srcOff), count: n)
            }
            return
        }
        let bytesPerFrame = Int(src.format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return }
        let source = UnsafeMutableAudioBufferListPointer(src.mutableAudioBufferList)
        let dest = UnsafeMutableAudioBufferListPointer(dst.mutableAudioBufferList)
        for (from, to) in zip(source, dest) {
            guard let s = from.mData, let d = to.mData else { continue }
            memcpy(
                d.advanced(by: Int(dstOff) * bytesPerFrame),
                s.advanced(by: Int(srcOff) * bytesPerFrame),
                Int(count) * bytesPerFrame
            )
        }
    }
}

/// HAL input capture for a non-default microphone.
final class InputDeviceCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.lockmic.input-capture")
    private let deviceID: AudioDeviceID
    private var ioProcID: AudioDeviceIOProcID?
    private var writer: CompressedStemWriter?
    private var format: AVAudioFormat?
    private var scratch: AVAudioPCMBuffer?
    private let sessionStart: CFTimeInterval
    private var didAlign = false
    private let lock = NSLock()
    private var _level: Float = 0
    private var _enabled = false

    let fileURL: URL

    var captureEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _enabled }
        set { lock.lock(); _enabled = newValue; lock.unlock() }
    }

    var level: Float {
        lock.lock(); defer { lock.unlock() }
        return RecordingLevelDisplay.fromLinearPeak(_level)
    }

    init(deviceID: AudioDeviceID, fileURL: URL, sessionStart: CFTimeInterval, bitRate: Int) throws {
        self.deviceID = deviceID
        self.fileURL = fileURL
        self.sessionStart = sessionStart

        var asbd = try Self.inputStreamFormat(deviceID)
        guard let format = AVAudioFormat(streamDescription: &asbd), format.channelCount > 0 else {
            throw SessionRecorderError.invalidTapFormat
        }
        self.format = format
        writer = try CompressedStemWriter(
            url: fileURL,
            channels: 1,
            bitRate: bitRate,
            sampleRate: format.sampleRate
        )

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
            stop()
            throw SessionRecorderError.ioFailed(startStatus)
        }
    }

    func stop() {
        if let proc = ioProcID {
            AudioDeviceStop(deviceID, proc)
            AudioDeviceDestroyIOProcID(deviceID, proc)
        }
        ioProcID = nil
        writer?.finish()
        writer = nil
    }

    deinit { stop() }

    private func write(_ input: UnsafePointer<AudioBufferList>, format: AVAudioFormat) {
        guard let writer else { return }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard !abl.isEmpty else { return }

        if !didAlign {
            didAlign = true
            let delay = max(0, CACurrentMediaTime() - sessionStart)
            if delay > 0.001 {
                writer.writeSilence(seconds: delay)
            }
        }

        let frames = RecordingSilence.frameCount(in: abl, format: format)
        guard frames > 0 else { return }

        lock.lock()
        let enabled = _enabled
        lock.unlock()

        if enabled, let dest = scratchBuffer(frames: frames, format: format) {
            RecordingDSP.copy(abl, into: dest)
            dest.frameLength = frames
            let peak = RecordingDSP.peak(in: dest)
            lock.lock()
            _level = max(peak, _level * 0.65)
            lock.unlock()
            writer.write(dest)
            return
        }

        lock.lock()
        _level *= 0.65
        lock.unlock()
        writer.padSilence(inputFrames: frames, sampleRate: format.sampleRate)
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

enum RecordingSilence {
    static func frameCount(in abl: UnsafeMutableAudioBufferListPointer, format: AVAudioFormat) -> AVAudioFrameCount {
        guard let first = abl.first else { return 0 }
        if format.isInterleaved {
            let bytesPerFrame = max(1, Int(format.streamDescription.pointee.mBytesPerFrame))
            return AVAudioFrameCount(Int(first.mDataByteSize) / bytesPerFrame)
        }
        return AVAudioFrameCount(Int(first.mDataByteSize) / MemoryLayout<Float>.size)
    }

    static func write(seconds: TimeInterval, format: AVAudioFormat, to file: AVAudioFile) {
        let frames = AVAudioFrameCount((seconds * format.sampleRate).rounded(.toNearestOrAwayFromZero))
        write(frames: frames, format: format, to: file)
    }

    static func write(frames: AVAudioFrameCount, format: AVAudioFormat, to file: AVAudioFile) {
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: min(frames, 8192)) else {
            return
        }
        zero(buffer)
        var remaining = frames
        do {
            while remaining > 0 {
                let chunk = min(remaining, buffer.frameCapacity)
                buffer.frameLength = chunk
                try file.write(from: buffer)
                remaining -= chunk
            }
        } catch {
            log.error("Silence pad failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func zero(_ buffer: AVAudioPCMBuffer) {
        buffer.frameLength = buffer.frameCapacity
        if let channels = buffer.floatChannelData {
            for ch in 0..<Int(buffer.format.channelCount) {
                channels[ch].update(repeating: 0, count: Int(buffer.frameCapacity))
            }
        } else {
            let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for buf in abl {
                if let dest = buf.mData {
                    memset(dest, 0, Int(buf.mDataByteSize))
                }
            }
        }
    }
}
