import AVFoundation
import Foundation

/// Microphone / system-audio TCC permission requests, plus small stateless start-path
/// helpers (error wrapping, session file naming). No `SessionRecorder` dependency.
enum SessionPermissions {
    static func liveMicrophoneAccess() -> CaptureAccess {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        default: return .unknown
        }
    }

    static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// `!dat` (560226676) and similar AVAudioFile failures arrive as raw OSStatus NSErrors.
    static func wrapStartError(_ error: Error) -> Error {
        if error is SessionRecorderError { return error }
        let ns = error as NSError
        if ns.domain == "com.apple.coreaudio.avfaudio" || ns.domain == NSOSStatusErrorDomain {
            return SessionRecorderError.fileFailed
        }
        return error
    }

    static func ensureMicrophonePermission() async throws {
        let granted = await requestMicrophoneAccess()
        guard granted else { throw SessionRecorderError.microphoneDenied }
    }

    static func ensureSystemAudioPermission() async throws {
        switch SystemAudioAccess.current {
        case .granted:
            return
        case .denied:
            throw SessionRecorderError.playbackDenied
        case .unknown:
            let granted = await SystemAudioAccess.request()
            guard granted else { throw SessionRecorderError.playbackDenied }
        }
    }

    static func makeSessionFile(in base: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let stamp = formatter.string(from: Date())
        let fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        var file = base.appendingPathComponent("LockMic \(stamp).aac")
        var n = 2
        while fm.fileExists(atPath: file.path) {
            file = base.appendingPathComponent("LockMic \(stamp) \(n).aac")
            n += 1
        }
        return file
    }
}
