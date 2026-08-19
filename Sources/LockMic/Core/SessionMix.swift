import AVFoundation
import Foundation
import os.log

private let log = Logger(subsystem: "com.lockmic.app", category: "SessionMix")

/// Mix stems and optionally discard per-device files after a successful mix.
enum SessionMix {
    /// Mix stems into a dated `LockMic yyyy-MM-dd HH.mm.m4a`.
    /// Mic is ducked while playback has energy so speaker bleed does not double.
    static func mix(
        in folder: URL,
        extraUIDs: [String],
        gates: MixGates,
        bitRate: Int,
        mixFileName: String
    ) async throws {
        let micURL = folder.appendingPathComponent(SessionRecorder.micFileName)
        let playbackURL = folder.appendingPathComponent(SessionRecorder.playbackFileName)
        let extraURLs = extraUIDs.map { ($0, folder.appendingPathComponent(SessionRecorder.extraMicFileName(uid: $0))) }
        let outputURL = folder.appendingPathComponent(mixFileName)

        try await Task.detached(priority: .userInitiated) {
            try renderDuckedMix(
                mic: micURL,
                playback: playbackURL,
                extras: extraURLs,
                gates: gates,
                bitRate: bitRate,
                to: outputURL
            )
        }.value
    }

    /// Delete per-device stems after a successful mix and lift the mix file
    /// next to the session folder so the dated mix is the recording.
    static func discardDeviceRecordings(in folder: URL, mixFileName: String) {
        let fm = FileManager.default
        let mix = folder.appendingPathComponent(mixFileName)
        guard fm.fileExists(atPath: mix.path) else { return }
        let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent != mixFileName {
            try? fm.removeItem(at: item)
        }
        let dest = folder.deletingLastPathComponent().appendingPathComponent(mixFileName)
        if dest.standardizedFileURL != mix.standardizedFileURL {
            try? fm.removeItem(at: dest)
            do {
                try fm.moveItem(at: mix, to: dest)
            } catch {
                log.error("Could not move mix out of session folder: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        let leftover = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        if leftover.filter({ !$0.lastPathComponent.hasPrefix(".") }).isEmpty {
            try? fm.removeItem(at: folder)
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
        extras: [(String, URL)],
        gates: MixGates,
        bitRate: Int,
        to outputURL: URL
    ) throws {
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
        let extraReaders = try extras.map { ($0.0, try StemReader(url: $0.1, destFormat: mixFormat)) }

        try? FileManager.default.removeItem(at: outputURL)
        let outFile = try AVAudioFile(
            forWriting: outputURL,
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
        let dt = Float(MixDuck.chunkFrames) / Float(mixFormat.sampleRate)
        let attack = 1 - exp(-dt / MixDuck.attackSeconds)
        let release = 1 - exp(-dt / MixDuck.releaseSeconds)

        while true {
            let micBuf = try micReader.read(MixDuck.chunkFrames)
            let playBuf = try playReader.read(MixDuck.chunkFrames)
            var extraBufs: [AVAudioPCMBuffer?] = []
            extraBufs.reserveCapacity(extraReaders.count)
            for reader in extraReaders {
                extraBufs.append(try reader.1.read(MixDuck.chunkFrames))
            }
            if micBuf == nil, playBuf == nil, extraBufs.allSatisfy({ $0 == nil }) { break }

            let frames = [micBuf?.frameLength ?? 0, playBuf?.frameLength ?? 0]
                .reduce(extraBufs.map { $0?.frameLength ?? 0 }.max() ?? 0, max)
            guard frames > 0 else { break }
            mixed.frameLength = frames

            let playOn = gates.playback.enabled(at: time)
            let playRMS = playOn ? (playBuf.map(rms) ?? 0) : 0
            if playRMS > MixDuck.playbackRMSThreshold {
                wantDuck = true
            } else if playRMS < MixDuck.playbackRMSOff {
                wantDuck = false
            }
            let target = wantDuck ? MixDuck.duckedMicGain : MixDuck.openMicGain
            let coeff = target < gain ? attack : release
            gain += (target - gain) * coeff

            let defaultMicOn = gates.microphone.enabled(at: time)
            mix(
                mic: defaultMicOn ? micBuf : nil,
                extras: zip(extras.map { $0.0 }, extraBufs).map { uid, buf in
                    (buf, gates.extras[uid]?.enabled(at: time) ?? true)
                },
                playback: playOn ? playBuf : nil,
                into: mixed,
                frames: Int(frames),
                voiceGain: gain
            )
            try outFile.write(from: mixed)
            time += Double(frames) / mixFormat.sampleRate
        }
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
        extras: [(AVAudioPCMBuffer?, Bool)],
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
            for (buf, enabled) in extras where enabled {
                guard let data = buf?.floatChannelData, i < Int(buf?.frameLength ?? 0) else { continue }
                voice += data[0][i] * voiceGain
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
