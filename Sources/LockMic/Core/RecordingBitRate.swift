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
        Self.formattedBytes(estimatedSessionBytes(duration: duration))
    }

    /// On-disk size plus unflushed audio at this bitrate, as one figure.
    func sizeChipText(onDisk bytes: Int64, extra duration: TimeInterval = 0) -> String {
        Self.formattedBytes(bytes + estimatedSessionBytes(duration: duration))
    }

    static func formattedBytes(_ bytes: Int64) -> String {
        sizeFormatter.string(fromByteCount: max(0, bytes))
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.allowsNonnumericFormatting = false
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

    /// AAC-LC at 48 kHz stereo ignores 48–64 kbps and encodes ~200 kbps.
    /// Pair low bitrates with 32 kHz; keep 44.1/48 kHz for 96 kbps and up.
    static func aacSampleRate(bitRate: Int, channels: AVAudioChannelCount) -> Double {
        let bps = clampedBitRate(bitRate, channels: channels)
        if channels >= 2 {
            if bps <= 64_000 { return 32_000 }
            if bps <= 96_000 { return 44_100 }
            return 48_000
        }
        return bps <= 48_000 ? 32_000 : 48_000
    }

    static func clampedBitRate(_ bitsPerSecond: Int, channels: AVAudioChannelCount) -> Int {
        let minBPS = 48_000
        let maxBPS = channels >= 2 ? 192_000 : 160_000
        return min(max(bitsPerSecond, minBPS), maxBPS)
    }

    static func aacSettings(
        channels: AVAudioChannelCount,
        bitRate: Int
    ) -> [String: Any] {
        let rate = aacSampleRate(bitRate: bitRate, channels: channels)
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
