import AVFoundation
import Foundation

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
        // AAC-LC at 8–24 kHz rejects typical 96–160 kbps settings (`!dat` / 560226676).
        // Stems always land on 44.1/48 kHz; CompressedStemWriter resamples HAL into this.
        rate >= 46_000 ? 48_000 : 44_100
    }

    static func clampedBitRate(_ bitsPerSecond: Int, channels: AVAudioChannelCount) -> Int {
        let minBPS = 48_000
        let maxBPS = channels >= 2 ? 192_000 : 160_000
        return min(max(bitsPerSecond, minBPS), maxBPS)
    }

    static func aacSettings(
        channels: AVAudioChannelCount,
        bitRate: Int,
        sampleRate: Double = sampleRate
    ) -> [String: Any] {
        let rate = aacSampleRate(nearest: sampleRate)
        let bps = clampedBitRate(bitRate, channels: channels)
        return [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: Int(max(1, min(channels, 2))),
            AVEncoderBitRateKey: bps,
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
