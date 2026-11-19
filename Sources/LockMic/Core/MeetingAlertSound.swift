import AppKit
import Foundation

/// Glass alert on the default output, and on every physical output in the last 15 seconds.
@MainActor
final class MeetingAlertSound {
    private let audio: AudioDeviceService
    private var players: [(sound: NSSound, started: TimeInterval)] = []
    private var deviceCacheAt: TimeInterval = -1000
    private var extraUIDs: [String] = []
    private static let glassPath = "/System/Library/Sounds/Glass.aiff"
    private static let glassSeconds: TimeInterval = 1.7

    init(audio: AudioDeviceService) {
        self.audio = audio
    }

    func stop() {
        for item in players {
            item.sound.stop()
        }
        players.removeAll()
    }

    func play(allPhysical: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        prune(now: now)
        playGlass(deviceUID: nil, now: now)
        if allPhysical {
            for uid in physicalUIDs(now: now) {
                playGlass(deviceUID: uid, now: now)
            }
        }
    }

    private func playGlass(deviceUID: String?, now: TimeInterval) {
        if players.count >= 6 {
            let oldest = players.removeFirst()
            oldest.sound.stop()
        }
        guard let sound = NSSound(contentsOfFile: Self.glassPath, byReference: true) else {
            if deviceUID == nil { NSSound.beep() }
            return
        }
        if let deviceUID {
            sound.playbackDeviceIdentifier = deviceUID
        }
        sound.volume = 1
        guard sound.play() else { return }
        players.append((sound, now))
    }

    private func prune(now: TimeInterval) {
        players.removeAll { item in
            if now - item.started >= Self.glassSeconds {
                return true
            }
            return false
        }
    }

    private func physicalUIDs(now: TimeInterval) -> [String] {
        if now - deviceCacheAt < 5 {
            return extraUIDs
        }
        let defaultUID = (try? audio.defaultOutputDeviceID()).flatMap { audio.deviceUID($0) }
        extraUIDs = audio.listOutputDevices().compactMap { device in
            guard !device.isVirtual else { return nil }
            guard device.uid != defaultUID else { return nil }
            return device.uid
        }
        deviceCacheAt = now
        return extraUIDs
    }
}
