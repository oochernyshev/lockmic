import AppKit
import Foundation

/// Plays short mute/unmute cues on the **default output** device via `NSSound`.
@MainActor
final class SoundFeedback {
    func play(muted: Bool) {
        // System sounds route to the default output device (speakers / headset).
        let name = muted ? "Tink" : "Pop"
        let path = "/System/Library/Sounds/\(name).aiff"
        guard let sound = NSSound(contentsOfFile: path, byReference: true) else {
            NSSound.beep()
            return
        }
        sound.volume = 0.7
        sound.delegate = SoundPlaybackDelegate.shared
        SoundPlaybackDelegate.shared.retain(sound)
        if !sound.play() {
            NSSound.beep()
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
