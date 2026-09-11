import AVFoundation
import Foundation

/// A snapshot of the recording session's state at a specific point in time.
struct LevelSnapshot {
    var inputs: [String: InputDeviceCapture] = [:]
    var taps: [String: PlaybackCapturing] = [:]
    var system: PlaybackCapturing?
    var playbackDeviceUID = ""
    var defaultOutputUID = ""
    var selectedInputUID = ""
    var selectedOutputUIDs: Set<String> = []
    var mixMuted = false
    var mixer: LiveMixer?
    var sessionFile: URL?
    var sessionBitRate = 0
    var startedAt: Date?
}