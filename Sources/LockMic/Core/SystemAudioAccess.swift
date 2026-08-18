import Darwin
import Foundation

/// System-audio TCC (`kTCCServiceAudioCapture`). No public preflight API —
/// same probe AudioCap uses so we can fail before capture starts.
enum SystemAudioAccess {
    static var current: CaptureAccess {
        guard let preflight = tccPreflight else { return .unknown }
        switch preflight("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    static func request() async -> Bool {
        switch current {
        case .granted: return true
        case .denied: return false
        case .unknown:
            break
        }
        guard let request = tccRequest else { return true }
        return await withCheckedContinuation { continuation in
            request("kTCCServiceAudioCapture" as CFString, nil) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let tccHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    }()

    private static let tccPreflight: PreflightFn? = {
        guard let tccHandle, let symbol = dlsym(tccHandle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(symbol, to: PreflightFn.self)
    }()

    private static let tccRequest: RequestFn? = {
        guard let tccHandle, let symbol = dlsym(tccHandle, "TCCAccessRequest") else { return nil }
        return unsafeBitCast(symbol, to: RequestFn.self)
    }()
}
