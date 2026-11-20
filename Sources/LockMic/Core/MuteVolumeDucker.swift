import CoreAudio
import Foundation

/// Remembers each input's pre-mute volume so mute can also pull the input gain to 0.
///
/// HAL mute alone is not enough for every client: some apps (e.g. Messages voice
/// recording) unmute the device while starting capture, and a stream started in that
/// window can keep delivering audio after the flag is set again. Volume applies to
/// running streams, so it closes that gap. Saved levels are persisted so a crash or
/// quit while muted cannot leave the mic stuck at 0.
final class MuteVolumeDucker: @unchecked Sendable {
    private static let defaultsKey = "duckedInputVolumes"
    private static let silentThreshold: Float = 0.001

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var saved: [String: Float]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.defaultsKey) as? [String: Double] ?? [:]
        saved = stored.mapValues { Float($0) }
    }

    /// Records `current` for `uid` (unless already ducked at ~0) and returns whether a
    /// write to 0 is needed.
    func noteDuck(uid: String, currentVolume current: Float) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard current > Self.silentThreshold else { return false }
        // Volume raised while muted (user dragged the slider): remember the newer level.
        saved[uid] = current
        persistLocked()
        return true
    }

    func savedVolume(uid: String) -> Float? {
        lock.lock()
        defer { lock.unlock() }
        return saved[uid]
    }

    var duckedUIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(saved.keys)
    }

    func clear(uid: String) {
        lock.lock()
        defer { lock.unlock() }
        saved.removeValue(forKey: uid)
        persistLocked()
    }

    private func persistLocked() {
        defaults.set(saved.mapValues { Double($0) }, forKey: Self.defaultsKey)
    }
}

extension AudioDeviceService {
    /// Pull input gain to 0 for a muted device, remembering the previous level.
    /// Best-effort: devices without a settable volume are left to HAL mute alone.
    func duckInputVolume(deviceID: AudioDeviceID) {
        guard let uid = deviceUID(deviceID),
              supportsInputVolume(deviceID),
              let current = try? inputVolume(deviceID),
              ducker.noteDuck(uid: uid, currentVolume: current)
        else { return }
        do {
            try setInputVolume(0, deviceID: deviceID)
        } catch {
            ducker.clear(uid: uid)
        }
    }

    /// Restore every device whose volume LockMic pulled down, including ones that
    /// stopped being the default while muted.
    func restoreDuckedInputVolumes() {
        for uid in ducker.duckedUIDs {
            guard let level = ducker.savedVolume(uid: uid) else { continue }
            guard let id = deviceID(forInputUID: uid) else {
                // Device is unplugged; its level is the driver's concern now.
                ducker.clear(uid: uid)
                continue
            }
            if (try? setInputVolume(level, deviceID: id)) != nil {
                ducker.clear(uid: uid)
            }
        }
    }
}
