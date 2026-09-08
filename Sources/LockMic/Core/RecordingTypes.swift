import Darwin
import Foundation

/// Mixer bus id for the system process tap (current default output).
enum PlaybackMix {
    static let systemSourceID = "system"
}

/// Which playback to capture. Mic is always the system default input only.
enum PlaybackRecordScope: Sendable {
    /// Audio routed to the default output device.
    case `default`
    /// Mix of every app's playback, regardless of output device.
    case all
}

enum CaptureAccess: Equatable, Sendable {
    case unknown
    case denied
    case granted
}

enum SessionRecorderError: LocalizedError {
    case alreadyRecording
    case notRecording
    case needsMacOS142
    case microphoneDenied
    case playbackDenied
    case micStartFailed
    case tapFailed(OSStatus)
    case aggregateFailed(OSStatus)
    case ioFailed(OSStatus)
    case invalidTapFormat
    case fileFailed
    case mixFailed

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return L10n.recordingErrorAlready
        case .notRecording: return L10n.recordingErrorNotRecording
        case .needsMacOS142: return L10n.recordingErrorNeedsMacOS
        case .microphoneDenied: return L10n.recordingErrorMicDenied
        case .playbackDenied: return L10n.recordingErrorPlaybackDenied
        case .micStartFailed: return L10n.recordingErrorMicStart
        case .tapFailed(let status): return L10n.recordingErrorTap(Int(status))
        case .aggregateFailed(let status): return L10n.recordingErrorAggregate(Int(status))
        case .ioFailed(let status): return L10n.recordingErrorIO(Int(status))
        case .invalidTapFormat: return L10n.recordingErrorInvalidFormat
        case .fileFailed: return L10n.recordingErrorFile
        case .mixFailed: return L10n.recordingErrorMix
        }
    }
}

enum RecordingDeviceKind: Equatable, Sendable {
    case input
    case output
}

/// Consecutive quiet time on the mix before the session stops itself.
enum RecordingSilenceTimeout: Int, CaseIterable, Equatable, Sendable, Identifiable {
    case off = 0
    case seconds30 = 30
    case minutes1 = 60
    case minutes2 = 120

    var id: Int { rawValue }

    /// `nil` means never stop for silence.
    var duration: TimeInterval? {
        rawValue > 0 ? TimeInterval(rawValue) : nil
    }

    static func resolved(_ stored: Int) -> RecordingSilenceTimeout {
        RecordingSilenceTimeout(rawValue: stored) ?? .off
    }
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
    /// Bluetooth headset is in HFP because its microphone IO is running.
    var isCallQuality: Bool
}
