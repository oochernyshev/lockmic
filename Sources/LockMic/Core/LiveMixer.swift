import AVFoundation
import Foundation
import os.log

private let log = Logger(subsystem: "com.lockmic.app", category: "LiveMixer")

/// Mixes mic + playback to 48 kHz stereo AAC as the session runs.
///
/// Mixed PCM is held in RAM for 30 seconds, encoded to ADTS AAC, then appended
/// as raw frames onto the dated `.aac` mix (no re-encode). A crash only loses
/// the unflushed slice. Slices that fail to fold are kept and retried.
final class LiveMixer: @unchecked Sendable {
    static let sampleRate: Double = RecordingCodec.sampleRate
    static let mixFileName = "mix.m4a"
    static let segmentPrefix = "live-"
    static let segmentSeconds: Double = 30
    private static let chunkFrames: AVAudioFrameCount = 1024
    private static let segmentFrames = AVAudioFrameCount(sampleRate * segmentSeconds)
    private static let encodeFrames: AVAudioFrameCount = 8192
    private static let ringSeconds = 4

    private let queue = DispatchQueue(label: "com.lockmic.live-mix", qos: .userInitiated)
    private let appendQueue = DispatchQueue(label: "com.lockmic.live-mix.append")
    private(set) var url: URL
    private let bitRate: Int
    private let sessionStart: CFTimeInterval

    private var pendingPCM: [AVAudioPCMBuffer] = []

    private var segmentBuffer: AVAudioPCMBuffer?
    private var mixChunkBuffer: AVAudioPCMBuffer?
    private var micConvertDest: AVAudioPCMBuffer?
    private var playConvertDest: AVAudioPCMBuffer?
    private var micScratch: [Float] = []
    private var playLScratch: [Float] = []
    private var playRScratch: [Float] = []
    private let unflushedLock = NSLock()
    private var unflushedFrames: AVAudioFrameCount = 0
    private var pendingFrames: AVAudioFrameCount = 0
    private var timer: DispatchSourceTimer?
    private var startedOutput = false
    private var receivedAudio = false
    private var stopped = false

    private var micConverter: AVAudioConverter?
    private var micFrom: AVAudioFormat?
    private var playConverter: AVAudioConverter?
    private var playFrom: AVAudioFormat?

    private var micRing = FloatRing(capacity: Int(sampleRate) * ringSeconds)
    private var playLRing = FloatRing(capacity: Int(sampleRate) * ringSeconds)
    private var playRRing = FloatRing(capacity: Int(sampleRate) * ringSeconds)
    private let ringLock = NSLock()

    private var duckGain: Float = MixDuck.openMicGain
    private var wantDuck = false

    init(url: URL, bitRate: Int, sessionStart: CFTimeInterval) {
        self.url = url
        self.bitRate = bitRate
        self.sessionStart = sessionStart
    }

    deinit {
        timer?.cancel()
    }

    func start() throws {
        try queue.sync {
            stopped = false
            startedOutput = false
            receivedAudio = false
            try prepare()
            startTimer()
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {
            guard !stopped else { return }
            stopped = true
            drainRings()
            enqueueSlice()
            segmentBuffer = nil
            mixChunkBuffer = nil
        }
        appendQueue.sync {
            self.drainPending()
            self.finalizeToM4A()
        }
    }

    static func mixURL(in folder: URL) -> URL {
        folder.appendingPathComponent(mixFileName)
    }

    func pushMic(_ buffer: AVAudioPCMBuffer) {
        let copy = Self.copy(buffer)
        queue.async { [weak self] in
            self?.ingest(copy, asMic: true)
        }
    }

    func pushPlayback(_ buffer: AVAudioPCMBuffer) {
        let copy = Self.copy(buffer)
        queue.async { [weak self] in
            self?.ingest(copy, asMic: false)
        }
    }

    /// Seconds of mixed PCM not yet in the dated mix file.
    func unflushedDuration() -> TimeInterval {
        unflushedLock.lock()
        let frames = unflushedFrames + pendingFrames
        unflushedLock.unlock()
        return Double(frames) / Self.sampleRate
    }

    static func segmentURLs(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return items
            .filter { $0.pathExtension == "m4a" && $0.lastPathComponent.hasPrefix(segmentPrefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func playableSegmentURLs(in folder: URL) -> [URL] {
        segmentURLs(in: folder).filter { (try? AVAudioFile(forReading: $0)) != nil }
    }

    // MARK: - Ingest

    private func ingest(_ buffer: AVAudioPCMBuffer?, asMic: Bool) {
        guard !stopped, let buffer, buffer.frameLength > 0 else { return }
        receivedAudio = true
        if asMic {
            ingestMic(buffer)
        } else {
            ingestPlayback(buffer)
        }
    }

    private func ingestMic(_ buffer: AVAudioPCMBuffer) {
        guard let dest = convert(
            buffer,
            channels: 1,
            converter: &micConverter,
            from: &micFrom,
            destBuffer: &micConvertDest
        ) else { return }
        guard let samples = dest.floatChannelData else { return }
        ringLock.lock()
        micRing.write(samples[0], count: Int(dest.frameLength))
        ringLock.unlock()
    }

    private func ingestPlayback(_ buffer: AVAudioPCMBuffer) {
        guard let dest = convert(
            buffer,
            channels: 2,
            converter: &playConverter,
            from: &playFrom,
            destBuffer: &playConvertDest
        ) else { return }
        guard let samples = dest.floatChannelData else { return }
        let n = Int(dest.frameLength)
        ringLock.lock()
        playLRing.write(samples[0], count: n)
        if dest.format.channelCount > 1 {
            playRRing.write(samples[1], count: n)
        } else {
            playRRing.write(samples[0], count: n)
        }
        ringLock.unlock()
    }

    private func convert(
        _ buffer: AVAudioPCMBuffer,
        channels: AVAudioChannelCount,
        converter: inout AVAudioConverter?,
        from: inout AVAudioFormat?,
        destBuffer: inout AVAudioPCMBuffer?,
        recovering: Bool = false
    ) -> AVAudioPCMBuffer? {
        let target = RecordingCodec.pcmFormat(channels: channels)
        if buffer.format.sampleRate == target.sampleRate,
           buffer.format.channelCount == channels,
           buffer.format.commonFormat == .pcmFormatFloat32,
           !buffer.format.isInterleaved
        {
            return buffer
        }
        if converter == nil || from != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            from = buffer.format
        }
        guard let active = converter else { return nil }
        let ratio = target.sampleRate / max(1, buffer.format.sampleRate)
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        if destBuffer == nil || destBuffer!.format.channelCount != channels
            || destBuffer!.frameCapacity < capacity
        {
            destBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: max(capacity, Self.chunkFrames))
        }
        guard let dest = destBuffer else { return nil }
        dest.frameLength = 0
        var error: NSError?
        var consumed = false
        let status = active.convert(to: dest, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if (status == .error || error != nil), !recovering {
            log.error("Live mix convert failed: \(error?.localizedDescription ?? "status \(status.rawValue)", privacy: .public); rebuilding converter")
            converter = nil
            from = nil
            destBuffer = nil
            return convert(
                buffer,
                channels: channels,
                converter: &converter,
                from: &from,
                destBuffer: &destBuffer,
                recovering: true
            )
        }
        return dest.frameLength > 0 ? dest : nil
    }

    // MARK: - Mix clock

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = Double(Self.chunkFrames) / Self.sampleRate
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.mixTick()
        }
        timer.resume()
        self.timer = timer
    }

    private func mixTick() {
        guard !stopped, segmentBuffer != nil else { return }
        if !startedOutput {
            guard receivedAudio else { return }
            startedOutput = true
            let delay = max(0, CACurrentMediaTime() - sessionStart)
            if delay > 0.02 {
                appendSilence(seconds: delay)
            }
        }
        mixChunk()
    }

    private func mixChunk() {
        let frames = Int(Self.chunkFrames)
        if micScratch.count != frames {
            micScratch = [Float](repeating: 0, count: frames)
            playLScratch = [Float](repeating: 0, count: frames)
            playRScratch = [Float](repeating: 0, count: frames)
        }
        guard let mixed = mixChunkBuffer ?? AVAudioPCMBuffer(
            pcmFormat: RecordingCodec.pcmFormat(channels: 2),
            frameCapacity: Self.chunkFrames
        ) else { return }
        mixChunkBuffer = mixed
        mixed.frameLength = Self.chunkFrames
        guard let out = mixed.floatChannelData else { return }

        ringLock.lock()
        micRing.read(&micScratch, count: frames)
        playLRing.read(&playLScratch, count: frames)
        playRRing.read(&playRScratch, count: frames)
        ringLock.unlock()

        var playSum: Float = 0
        for i in 0..<frames {
            playSum += playLScratch[i] * playLScratch[i] + playRScratch[i] * playRScratch[i]
        }
        let playRMS = sqrt(playSum / Float(frames * 2))
        if playRMS > MixDuck.playbackRMSThreshold {
            wantDuck = true
        } else if playRMS < MixDuck.playbackRMSOff {
            wantDuck = false
        }
        let target = wantDuck ? MixDuck.duckedMicGain : MixDuck.openMicGain
        let dt = Float(Self.chunkFrames) / Float(Self.sampleRate)
        let coeff = target < duckGain ? MixDuck.attack(dt) : MixDuck.release(dt)
        duckGain += (target - duckGain) * coeff

        let voiceGain = duckGain
        for i in 0..<frames {
            let voice = micScratch[i] * voiceGain
            out[0][i] = max(-1, min(1, playLScratch[i] + voice))
            out[1][i] = max(-1, min(1, playRScratch[i] + voice))
        }
        appendToSegment(mixed)
    }

    private func drainRings() {
        ringLock.lock()
        let leftover = max(micRing.count, max(playLRing.count, playRRing.count))
        ringLock.unlock()
        var remain = leftover
        while remain > 0 {
            mixChunk()
            remain -= Int(Self.chunkFrames)
        }
    }

    // MARK: - RAM slice → dated mix

    private func prepare() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: url)
        let format = RecordingCodec.pcmFormat(channels: 2)
        segmentBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.segmentFrames)
        segmentBuffer?.frameLength = 0
        mixChunkBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.chunkFrames)
        setUnflushed(ram: 0, pendingDelta: 0)
        log.info("Live mix \(self.url.lastPathComponent, privacy: .public)")
    }

    private func appendSilence(seconds: TimeInterval) {
        let frames = AVAudioFrameCount((seconds * Self.sampleRate).rounded(.toNearestOrAwayFromZero))
        guard frames > 0, let dest = segmentBuffer, let ch = dest.floatChannelData else { return }
        var remain = frames
        while remain > 0 {
            if dest.frameLength >= dest.frameCapacity {
                enqueueSlice()
            }
            let take = min(dest.frameCapacity - dest.frameLength, remain)
            let start = Int(dest.frameLength)
            let n = Int(take)
            ch[0].advanced(by: start).update(repeating: 0, count: n)
            ch[1].advanced(by: start).update(repeating: 0, count: n)
            dest.frameLength += take
            remain -= take
        }
        setUnflushed(ram: dest.frameLength, pendingDelta: 0)
    }

    private func appendToSegment(_ chunk: AVAudioPCMBuffer) {
        guard let dest = segmentBuffer,
              let src = chunk.floatChannelData,
              let dst = dest.floatChannelData
        else { return }
        var srcOff: AVAudioFrameCount = 0
        var remain = chunk.frameLength
        while remain > 0 {
            if dest.frameLength >= dest.frameCapacity {
                enqueueSlice()
            }
            let take = min(dest.frameCapacity - dest.frameLength, remain)
            let n = Int(take)
            let dOff = Int(dest.frameLength)
            let sOff = Int(srcOff)
            dst[0].advanced(by: dOff).update(from: src[0].advanced(by: sOff), count: n)
            dst[1].advanced(by: dOff).update(from: src[1].advanced(by: sOff), count: n)
            dest.frameLength += take
            srcOff += take
            remain -= take
        }
        setUnflushed(ram: dest.frameLength, pendingDelta: 0)
    }

    private func enqueueSlice() {
        guard let dest = segmentBuffer, dest.frameLength > 0 else { return }
        let frames = dest.frameLength
        guard let copy = Self.copy(dest) else { return }
        dest.frameLength = 0
        setUnflushed(ram: 0, pendingDelta: Int(frames))
        appendQueue.async {
            self.fold(copy)
        }
    }

    private func setUnflushed(ram: AVAudioFrameCount, pendingDelta: Int) {
        unflushedLock.lock()
        unflushedFrames = ram
        if pendingDelta > 0 {
            pendingFrames += AVAudioFrameCount(pendingDelta)
        } else if pendingDelta < 0 {
            let drop = AVAudioFrameCount(-pendingDelta)
            pendingFrames = pendingFrames > drop ? pendingFrames - drop : 0
        }
        unflushedLock.unlock()
    }

    /// Encode a closed playable slice and fold it onto the dated mix. Keep PCM on failure.
    private func fold(_ pcm: AVAudioPCMBuffer) {
        pendingPCM.append(pcm)
        drainPending()
    }

    private func drainPending() {
        while let pcm = pendingPCM.first {
            do {
                try commitSlice(pcm)
                pendingPCM.removeFirst()
                setUnflushed(ram: unflushedRam(), pendingDelta: -Int(pcm.frameLength))
                log.info("Live mix flushed \(pcm.frameLength) frames → \(self.url.lastPathComponent, privacy: .public)")
            } catch {
                log.error("Live mix flush failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
    }

    private func unflushedRam() -> AVAudioFrameCount {
        unflushedLock.lock()
        let n = unflushedFrames
        unflushedLock.unlock()
        return n
    }

    private func commitSlice(_ pcm: AVAudioPCMBuffer) throws {
        let fm = FileManager.default
        let slice = fm.temporaryDirectory.appendingPathComponent("lockmic-slice-\(UUID().uuidString).aac")
        do {
            try encodeClosedM4A(pcm, to: slice)
            try SessionMix.appendSegment(slice, onto: url, bitRate: bitRate)
        } catch {
            try? fm.removeItem(at: slice)
            throw error
        }
    }

    private func encodeClosedM4A(_ pcm: AVAudioPCMBuffer, to output: URL) throws {
        try? FileManager.default.removeItem(at: output)
        var file: AVAudioFile? = try AVAudioFile(
            forWriting: output,
            settings: RecordingCodec.aacSettings(channels: 2, bitRate: bitRate),
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        defer { file = nil }
        guard let file else { throw SessionRecorderError.fileFailed }
        let destFormat = file.processingFormat
        if pcm.format.sampleRate == destFormat.sampleRate,
           pcm.format.channelCount == destFormat.channelCount,
           pcm.format.commonFormat == destFormat.commonFormat
        {
            try writePCM(pcm, to: file)
            return
        }
        guard let converter = AVAudioConverter(from: pcm.format, to: destFormat) else {
            throw SessionRecorderError.fileFailed
        }
        let ratio = destFormat.sampleRate / max(1, pcm.format.sampleRate)
        let outCap = AVAudioFrameCount(Double(Self.encodeFrames) * ratio + 4096)
        guard let resampled = AVAudioPCMBuffer(pcmFormat: destFormat, frameCapacity: outCap),
              let input = AVAudioPCMBuffer(pcmFormat: pcm.format, frameCapacity: Self.encodeFrames)
        else {
            throw SessionRecorderError.fileFailed
        }
        var offset: AVAudioFrameCount = 0
        while offset < pcm.frameLength {
            let take = min(Self.encodeFrames, pcm.frameLength - offset)
            input.frameLength = take
            Self.copyFrames(from: pcm, at: offset, to: input, at: 0, count: take)
            try Self.pullConverter(converter, input: input, endOfStream: false, dest: resampled, file: file)
            offset += take
        }
        try Self.pullConverter(converter, input: nil, endOfStream: true, dest: resampled, file: file)
    }

    /// Keep pulling until the converter has no more output (needed for 48 kHz → 32 kHz).
    private static func pullConverter(
        _ converter: AVAudioConverter,
        input: AVAudioPCMBuffer?,
        endOfStream: Bool,
        dest: AVAudioPCMBuffer,
        file: AVAudioFile
    ) throws {
        var supplied = false
        while true {
            dest.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: dest, error: &error) { _, status in
                if endOfStream {
                    status.pointee = .endOfStream
                    return nil
                }
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return input
            }
            if let error { throw error }
            if dest.frameLength > 0 {
                try file.write(from: dest)
            }
            if status == .error { throw SessionRecorderError.fileFailed }
            if status == .endOfStream { break }
            if dest.frameLength == 0 { break }
            if !endOfStream, dest.frameLength < dest.frameCapacity { break }
        }
    }

    private func finalizeToM4A() {
        guard url.pathExtension.lowercased() == "aac",
              FileManager.default.fileExists(atPath: url.path)
        else { return }
        let m4a = url.deletingPathExtension().appendingPathExtension("m4a")
        do {
            try SessionMix.wrapADTStoM4A(from: url, to: m4a)
            try FileManager.default.removeItem(at: url)
            url = m4a
            log.info("Live mix wrapped \(m4a.lastPathComponent, privacy: .public)")
        } catch {
            log.error("ADTS wrap failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func writePCM(_ pcm: AVAudioPCMBuffer, to file: AVAudioFile) throws {
        guard let left = pcm.floatChannelData?[0], let right = pcm.floatChannelData?[1] else {
            throw SessionRecorderError.fileFailed
        }
        guard let slice = AVAudioPCMBuffer(pcmFormat: pcm.format, frameCapacity: Self.encodeFrames),
              let destL = slice.floatChannelData?[0],
              let destR = slice.floatChannelData?[1]
        else {
            throw SessionRecorderError.fileFailed
        }
        var offset: AVAudioFrameCount = 0
        while offset < pcm.frameLength {
            let n = min(slice.frameCapacity, pcm.frameLength - offset)
            destL.update(from: left.advanced(by: Int(offset)), count: Int(n))
            destR.update(from: right.advanced(by: Int(offset)), count: Int(n))
            slice.frameLength = n
            try file.write(from: slice)
            offset += n
        }
    }

    private static func copyFrames(
        from src: AVAudioPCMBuffer,
        at srcOff: AVAudioFrameCount,
        to dst: AVAudioPCMBuffer,
        at dstOff: AVAudioFrameCount,
        count: AVAudioFrameCount
    ) {
        guard count > 0, let s = src.floatChannelData, let d = dst.floatChannelData else { return }
        let n = Int(count)
        let channels = min(Int(src.format.channelCount), Int(dst.format.channelCount))
        for ch in 0..<channels {
            (d[ch] + Int(dstOff)).update(from: s[ch] + Int(srcOff), count: n)
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let dest = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        dest.frameLength = buffer.frameLength
        if let src = buffer.floatChannelData, let dst = dest.floatChannelData {
            let n = Int(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)
            for ch in 0..<channels {
                dst[ch].update(from: src[ch], count: n)
            }
        } else {
            RecordingDSP.copy(
                UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                into: dest
            )
        }
        return dest
    }

    private enum MixDuck {
        static let playbackRMSThreshold: Float = 0.01
        static let playbackRMSOff: Float = 0.004
        static let duckedMicGain: Float = 0.18
        static let openMicGain: Float = 1
        static let attackSeconds: Float = 0.008
        static let releaseSeconds: Float = 0.18

        static func attack(_ dt: Float) -> Float { 1 - exp(-dt / attackSeconds) }
        static func release(_ dt: Float) -> Float { 1 - exp(-dt / releaseSeconds) }
    }
}

private struct FloatRing {
    private var buf: [Float]
    private var read = 0
    private var write = 0
    private(set) var count = 0

    init(capacity: Int) {
        buf = [Float](repeating: 0, count: max(capacity, 1024))
    }

    mutating func write(_ src: UnsafePointer<Float>, count n: Int) {
        let cap = buf.count
        for i in 0..<n {
            if count == cap {
                read = (read + 1) % cap
                count -= 1
            }
            buf[write] = src[i]
            write = (write + 1) % cap
            count += 1
        }
    }

    mutating func read(_ dst: UnsafeMutablePointer<Float>, count n: Int) {
        let cap = buf.count
        for i in 0..<n {
            if count == 0 {
                dst[i] = 0
            } else {
                dst[i] = buf[read]
                read = (read + 1) % cap
                count -= 1
            }
        }
    }
}
