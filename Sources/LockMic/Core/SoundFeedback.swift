import AppKit
import Foundation

/// Plays short mute/unmute cues on the **default output** device via `NSSound`.
@MainActor
final class SoundFeedback {
    private let audio: AudioDeviceService

    init(audio: AudioDeviceService) {
        self.audio = audio
    }

    func play(muted: Bool) {
        // Resolve on every cue so output changes are respected. Never fall back to
        // the separate system-effects output if routing or playback fails.
        guard let deviceID = try? audio.defaultOutputDeviceID(),
              let deviceUID = audio.deviceUID(deviceID) else { return }
        let name = muted ? "Tink" : "Pop"
        let path = "/System/Library/Sounds/\(name).aiff"
        guard let sound = NSSound(contentsOfFile: path, byReference: true) else {
            return
        }
        sound.playbackDeviceIdentifier = deviceUID
        sound.volume = 0.7
        sound.delegate = SoundPlaybackDelegate.shared
        if sound.play() {
            SoundPlaybackDelegate.shared.retain(sound)
        }
    }
}

/// Retains `NSSound` until playback finishes (otherwise ARC can cut it off).
private final class SoundPlaybackDelegate: NSObject, NSSoundDelegate {
    static let shared = SoundPlaybackDelegate()
    private var retained: [NSSound] = []

    func retain(_ sound: NSSound) {
        retained.append(sound)
    }

    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        retained.removeAll { $0 === sound }
    }
}
