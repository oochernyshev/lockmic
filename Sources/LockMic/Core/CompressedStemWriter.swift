import AVFoundation
import Foundation
import os.log

private let log = Logger(subsystem: "com.lockmic.app", category: "StemWriter")

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
        let channels = max(1, min(channels, 2))
        // Always 48 kHz AAC. HAL/tap rates (e.g. 16 kHz Bluetooth) are resampled on ingest.
        let rate = RecordingCodec.sampleRate
        writeFormat = RecordingCodec.pcmFormat(channels: channels, sampleRate: rate)
        queue = DispatchQueue(label: "com.lockmic.stem-write.\(url.lastPathComponent)", qos: .userInitiated)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: url)
        do {
            file = try Self.openAAC(url: url, channels: channels, bitRate: bitRate, sampleRate: rate)
        } catch {
            log.error("AAC open failed: \(error.localizedDescription, privacy: .public); retrying 48 kHz 128 kbps")
            try? FileManager.default.removeItem(at: url)
            do {
                file = try Self.openAAC(
                    url: url,
                    channels: channels,
                    bitRate: RecordingBitRate.default.bitsPerSecond,
                    sampleRate: RecordingCodec.sampleRate
                )
            } catch {
                throw SessionRecorderError.fileFailed
            }
        }
    }

    private static func openAAC(
        url: URL,
        channels: AVAudioChannelCount,
        bitRate: Int,
        sampleRate: Double
    ) throws -> AVAudioFile {
        try AVAudioFile(
            forWriting: url,
            settings: RecordingCodec.aacSettings(channels: channels, bitRate: bitRate, sampleRate: sampleRate),
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
