import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import os.log

private let log = Logger(subsystem: "com.lockmic.app", category: "SessionMix")

/// Mix microphone + playback stems and optionally discard them after a successful mix.
enum SessionMix {
    /// Mix stems into a dated `LockMic yyyy-MM-dd HH.mm.m4a`.
    /// Mic is ducked while playback has energy so speaker bleed does not double.
    static func mix(
        in folder: URL,
        bitRate: Int,
        mixFileName: String,
        destinationFolder: URL
    ) async throws {
        let micURL = folder.appendingPathComponent(SessionRecorder.micFileName)
        let playbackURL = folder.appendingPathComponent(SessionRecorder.playbackFileName)
        let base = (mixFileName as NSString).deletingPathExtension
        let outputURL = destinationFolder.appendingPathComponent(mixFileName)

        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            removeProcessingMixes(named: base, in: destinationFolder)
            do {
                let processingURL = try renderDuckedMix(
                    mic: micURL,
                    playback: playbackURL,
                    bitRate: bitRate,
                    destFolder: destinationFolder,
                    baseName: base
                )
                try? fm.removeItem(at: outputURL)
                try fm.moveItem(at: processingURL, to: outputURL)
            } catch {
                removeProcessingMixes(named: base, in: destinationFolder)
                throw error
            }
        }.value
    }

    /// Fold leftover `live-NNN.m4a` pieces into `mix.m4a`, then copy to the dated file.
    static func concatLiveSegments(
        in folder: URL,
        mixFileName: String,
        destinationFolder: URL
    ) async throws {
        recoverInterruptedAppend(in: folder)
        let mix = LiveMixer.mixURL(in: folder)
        for segment in LiveMixer.playableSegmentURLs(in: folder) {
            try appendSegment(segment, onto: mix, bitRate: RecordingBitRate.default.bitsPerSecond)
        }
        guard FileManager.default.fileExists(atPath: mix.path) else {
            throw SessionRecorderError.mixFailed
        }
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        let outputURL = destinationFolder.appendingPathComponent(mixFileName)
        if outputURL.standardizedFileURL != mix.standardizedFileURL {
            try? FileManager.default.removeItem(at: outputURL)
            try FileManager.default.copyItem(at: mix, to: outputURL)
        }
    }

    static func recoverInterruptedAppend(in folder: URL) {
        let fm = FileManager.default
        let mix = LiveMixer.mixURL(in: folder)
        let temp = folder.appendingPathComponent("mix-tmp.m4a")
        let tempOK = (try? AVAudioFile(forReading: temp)) != nil
        let mixOK = (try? AVAudioFile(forReading: mix)) != nil
        if tempOK, !mixOK {
            try? fm.removeItem(at: mix)
            try? fm.moveItem(at: temp, to: mix)
        } else {
            try? fm.removeItem(at: temp)
        }
    }

    /// Attach a finished slice onto the running playable mix; then delete the segment.
    /// Never replaces `mix` until the new file is playable and longer.
    static func appendSegment(_ segment: URL, onto mix: URL, bitRate: Int) throws {
        let fm = FileManager.default
        try waitUntilPlayable(segment)
        if segment.pathExtension.lowercased() == "aac" {
            try appendADTS(segment, onto: mix)
            return
        }
        if !fm.fileExists(atPath: mix.path) {
            try fm.moveItem(at: segment, to: mix)
            return
        }
        try waitUntilPlayable(mix)
        let before = audioSeconds(mix)
        let added = audioSeconds(segment)
        let temp = fm.temporaryDirectory.appendingPathComponent("lockmic-mix-\(UUID().uuidString).m4a")
        defer { try? fm.removeItem(at: temp) }
        try concatenatePCM([mix, segment], bitRate: bitRate, to: temp)
        try waitUntilPlayable(temp)
        let after = audioSeconds(temp)
        guard after + 0.05 >= before + added * 0.95 else {
            log.error("Concat too short: \(after, format: .fixed(precision: 2))s vs \(before + added, format: .fixed(precision: 2))s")
            throw SessionRecorderError.mixFailed
        }
        _ = try fm.replaceItemAt(mix, withItemAt: temp)
        try? fm.removeItem(at: segment)
    }

    /// ADTS AAC frames are self-contained — append bytes, no re-encode.
    private static func appendADTS(_ segment: URL, onto mix: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: mix.path) {
            try fm.moveItem(at: segment, to: mix)
            return
        }
        let data = try Data(contentsOf: segment)
        guard !data.isEmpty else { throw SessionRecorderError.mixFailed }
        let handle = try FileHandle(forWritingTo: mix)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try? fm.removeItem(at: segment)
    }

    /// Copy ADTS packets into an m4a so Finder/QuickTime duration matches playback (no re-encode).
    static func wrapADTStoM4A(from input: URL, to output: URL) throws {
        try? FileManager.default.removeItem(at: output)
        var inFile: AudioFileID?
        var status = AudioFileOpenURL(input as CFURL, .readPermission, kAudioFileAAC_ADTSType, &inFile)
        guard status == noErr, let inFile else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        defer { AudioFileClose(inFile) }

        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioFileGetProperty(inFile, kAudioFilePropertyDataFormat, &asbdSize, &asbd)
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        var outFile: AudioFileID?
        status = AudioFileCreateWithURL(output as CFURL, kAudioFileM4AType, &asbd, .eraseFile, &outFile)
        guard status == noErr, let outFile else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        defer { AudioFileClose(outFile) }

        var cookieSize: UInt32 = 0
        if AudioFileGetPropertyInfo(inFile, kAudioFilePropertyMagicCookieData, &cookieSize, nil) == noErr,
           cookieSize > 0
        {
            var cookie = [UInt8](repeating: 0, count: Int(cookieSize))
            AudioFileGetProperty(inFile, kAudioFilePropertyMagicCookieData, &cookieSize, &cookie)
            AudioFileSetProperty(outFile, kAudioFilePropertyMagicCookieData, cookieSize, cookie)
        }

        var packet: Int64 = 0
        let maxPackets: UInt32 = 64
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        while true {
            var numBytes = UInt32(buffer.count)
            var numPackets = maxPackets
            var descs = [AudioStreamPacketDescription](
                repeating: AudioStreamPacketDescription(), count: Int(maxPackets)
            )
            status = AudioFileReadPacketData(
                inFile, false, &numBytes, &descs, packet, &numPackets, &buffer
            )
            if numPackets == 0 { break }
            if status != noErr, status != kAudioFileEndOfFileError {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            var written = numPackets
            status = AudioFileWritePackets(outFile, false, numBytes, descs, packet, &written, buffer)
            guard status == noErr else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            packet += Int64(numPackets)
        }
        guard packet > 0 else { throw SessionRecorderError.mixFailed }
    }

    private static func waitUntilPlayable(_ url: URL) throws {
        for _ in 0..<50 {
            if (try? AVAudioFile(forReading: url)) != nil { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw SessionRecorderError.mixFailed
    }

    private static func audioSeconds(_ url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / max(1, file.processingFormat.sampleRate)
    }

    /// Decode slices to PCM and encode one AAC file at the session bitrate.
    /// Packet-copy and passthrough both fail for 32 kHz / 64 kbps slices.
    private static func concatenatePCM(_ urls: [URL], bitRate: Int, to output: URL) throws {
        try? FileManager.default.removeItem(at: output)
        let settings = RecordingCodec.aacSettings(channels: 2, bitRate: bitRate)
        var outFile: AVAudioFile?
        var converter: AVAudioConverter?
        var converterFrom: AVAudioFormat?
        let chunk: AVAudioFrameCount = 8192
        for url in urls {
            let src = try AVAudioFile(forReading: url)
            let proc = src.processingFormat
            guard let buf = AVAudioPCMBuffer(pcmFormat: proc, frameCapacity: chunk) else {
                throw SessionRecorderError.mixFailed
            }
            while src.framePosition < src.length {
                let toRead = min(chunk, AVAudioFrameCount(src.length - src.framePosition))
                try src.read(into: buf, frameCount: toRead)
                if buf.frameLength == 0 { break }
                if outFile == nil {
                    outFile = try AVAudioFile(
                        forWriting: output,
                        settings: settings,
                        commonFormat: .pcmFormatFloat32,
                        interleaved: false
                    )
                }
                guard let outFile else { throw SessionRecorderError.mixFailed }
                let destFmt = outFile.processingFormat
                if proc.sampleRate == destFmt.sampleRate,
                   proc.channelCount == destFmt.channelCount,
                   proc.commonFormat == destFmt.commonFormat,
                   proc.isInterleaved == destFmt.isInterleaved
                {
                    try outFile.write(from: buf)
                    continue
                }
                if converter == nil || converterFrom != proc {
                    converter = AVAudioConverter(from: proc, to: destFmt)
                    converterFrom = proc
                }
                guard let converter else { throw SessionRecorderError.mixFailed }
                let cap = AVAudioFrameCount(Double(buf.frameLength) * destFmt.sampleRate / proc.sampleRate + 32)
                guard let dest = AVAudioPCMBuffer(pcmFormat: destFmt, frameCapacity: cap) else {
                    throw SessionRecorderError.mixFailed
                }
                var error: NSError?
                var consumed = false
                converter.convert(to: dest, error: &error) { _, status in
                    if consumed {
                        status.pointee = .noDataNow
                        return nil
                    }
                    consumed = true
                    status.pointee = .haveData
                    return buf
                }
                if let error { throw error }
                if dest.frameLength > 0 {
                    try outFile.write(from: dest)
                }
            }
        }
    }

    /// Delete the session folder (stems). The dated mix already lives in `destinationFolder`.
    static func discardDeviceRecordings(in folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Visible in-progress mix: `LockMic 2026-08-19 13.29 mixing 37%.m4a`.
    nonisolated private static func processingMixName(base: String, percent: Int) -> String {
        "\(base) mixing \(percent)%.m4a"
    }

    nonisolated private static func removeProcessingMixes(named base: String, in folder: URL) {
        let prefix = "\(base) mixing "
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent.hasPrefix(prefix) && item.pathExtension == "m4a" {
            try? FileManager.default.removeItem(at: item)
        }
    }

    private enum MixDuck {
        static let playbackRMSThreshold: Float = 0.01
        static let playbackRMSOff: Float = 0.004
        static let duckedMicGain: Float = 0.18
        static let openMicGain: Float = 1
        static let attackSeconds: Float = 0.008
        static let releaseSeconds: Float = 0.18
        static let chunkFrames: AVAudioFrameCount = 1024
    }

    nonisolated private static func renderDuckedMix(
        mic micURL: URL,
        playback playbackURL: URL,
        bitRate: Int,
        destFolder: URL,
        baseName: String
    ) throws -> URL {
        guard let mixFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ) else {
            throw SessionRecorderError.mixFailed
        }

        let micReader = try StemReader(url: micURL, destFormat: mixFormat)
        let playReader = try StemReader(url: playbackURL, destFormat: mixFormat)
        let totalDuration = max(micReader.duration, playReader.duration)

        var currentURL = destFolder.appendingPathComponent(processingMixName(base: baseName, percent: 0))
        try? FileManager.default.removeItem(at: currentURL)
        let outFile = try AVAudioFile(
            forWriting: currentURL,
            settings: RecordingCodec.aacSettings(channels: 2, bitRate: bitRate),
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let mixed = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: MixDuck.chunkFrames) else {
            throw SessionRecorderError.mixFailed
        }

        var gain = MixDuck.openMicGain
        var wantDuck = false
        var time: TimeInterval = 0
        var lastPercent = 0
        let dt = Float(MixDuck.chunkFrames) / Float(mixFormat.sampleRate)
        let attack = 1 - exp(-dt / MixDuck.attackSeconds)
        let release = 1 - exp(-dt / MixDuck.releaseSeconds)

        while true {
            let micBuf = try micReader.read(MixDuck.chunkFrames)
            let playBuf = try playReader.read(MixDuck.chunkFrames)
            if micBuf == nil, playBuf == nil { break }

            let frames = max(micBuf?.frameLength ?? 0, playBuf?.frameLength ?? 0)
            guard frames > 0 else { break }
            mixed.frameLength = frames

            let playRMS = playBuf.map(rms) ?? 0
            if playRMS > MixDuck.playbackRMSThreshold {
                wantDuck = true
            } else if playRMS < MixDuck.playbackRMSOff {
                wantDuck = false
            }
            let target = wantDuck ? MixDuck.duckedMicGain : MixDuck.openMicGain
            let coeff = target < gain ? attack : release
            gain += (target - gain) * coeff

            mix(mic: micBuf, playback: playBuf, into: mixed, frames: Int(frames), voiceGain: gain)
            try outFile.write(from: mixed)
            time += Double(frames) / mixFormat.sampleRate
            if totalDuration > 0 {
                let percent = min(99, Int((time / totalDuration) * 100))
                if percent > lastPercent {
                    lastPercent = percent
                    let next = destFolder.appendingPathComponent(
                        processingMixName(base: baseName, percent: percent)
                    )
                    // Rename while the encoder keeps the open fd (inode follows).
                    if (try? FileManager.default.moveItem(at: currentURL, to: next)) != nil {
                        currentURL = next
                    }
                }
            }
        }
        return currentURL
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        let count = Int(buffer.format.channelCount)
        guard frames > 0, count > 0 else { return 0 }
        var sum: Float = 0
        for ch in 0..<count {
            let samples = channels[ch]
            for i in 0..<frames {
                let s = samples[i]
                sum += s * s
            }
        }
        return sqrt(sum / Float(frames * count))
    }

    nonisolated private static func mix(
        mic: AVAudioPCMBuffer?,
        playback: AVAudioPCMBuffer?,
        into dest: AVAudioPCMBuffer,
        frames: Int,
        voiceGain: Float
    ) {
        guard let out = dest.floatChannelData else { return }
        let micData = mic?.floatChannelData
        let playData = playback?.floatChannelData
        let micFrames = Int(mic?.frameLength ?? 0)
        let playFrames = Int(playback?.frameLength ?? 0)
        let micChans = Int(mic?.format.channelCount ?? 0)
        let playChans = Int(playback?.format.channelCount ?? 0)

        for i in 0..<frames {
            var voice: Float = 0
            if let micData, i < micFrames, micChans > 0 {
                voice += micData[0][i] * voiceGain
            }
            let playL: Float
            let playR: Float
            if let playData, i < playFrames, playChans > 0 {
                playL = playData[0][i]
                playR = playChans > 1 ? playData[1][i] : playL
            } else {
                playL = 0
                playR = 0
            }
            out[0][i] = max(-1, min(1, playL + voice))
            out[1][i] = max(-1, min(1, playR + voice))
        }
    }
}

/// Pulls a stem and converts it to the mix format.
private final class StemReader: @unchecked Sendable {
    private let file: AVAudioFile?
    private let converter: AVAudioConverter?
    private let destFormat: AVAudioFormat

    var duration: TimeInterval {
        guard let file, file.processingFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    init(url: URL, destFormat: AVAudioFormat) throws {
        self.destFormat = destFormat
        guard FileManager.default.fileExists(atPath: url.path) else {
            file = nil
            converter = nil
            return
        }
        let opened = try AVAudioFile(forReading: url)
        file = opened
        if opened.processingFormat == destFormat {
            converter = nil
        } else {
            converter = AVAudioConverter(from: opened.processingFormat, to: destFormat)
        }
    }

    func read(_ frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        guard let file, file.framePosition < file.length else { return nil }
        guard let dest = AVAudioPCMBuffer(pcmFormat: destFormat, frameCapacity: frames) else {
            throw SessionRecorderError.mixFailed
        }

        if converter == nil {
            try file.read(into: dest, frameCount: min(frames, AVAudioFrameCount(file.length - file.framePosition)))
            return dest.frameLength > 0 ? dest : nil
        }

        guard let converter else { return nil }
        var error: NSError?
        var finished = false
        let status = converter.convert(to: dest, error: &error) { inNumPackets, outStatus in
            if finished || file.framePosition >= file.length {
                outStatus.pointee = .endOfStream
                return nil
            }
            let toRead = min(AVAudioFrameCount(inNumPackets), AVAudioFrameCount(file.length - file.framePosition))
            guard toRead > 0,
                  let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: toRead)
            else {
                outStatus.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: input, frameCount: toRead)
            } catch {
                outStatus.pointee = .endOfStream
                return nil
            }
            if input.frameLength == 0 {
                finished = true
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            return input
        }
        if status == .error {
            throw error ?? SessionRecorderError.mixFailed
        }
        return dest.frameLength > 0 ? dest : nil
    }
}
