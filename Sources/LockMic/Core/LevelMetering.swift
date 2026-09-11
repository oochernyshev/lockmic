import AVFoundation
import Foundation

/// Component responsible for level metering functionality
class LevelMetering {
    // MARK: - Properties
    
    /// Lock for thread-safe access to level snapshot
    private let levelLock = NSLock()
    
    /// Current level snapshot
    private var levelSnapshot = LevelSnapshot()
    
    // MARK: - Level Snapshot Management
    
    /// Creates a new LevelSnapshot with current values
    func publishLevels(
        inputs: [String: InputDeviceCapture],
        taps: [String: PlaybackCapturing],
        system: PlaybackCapturing?,
        playbackDeviceUID: String,
        defaultOutputUID: String,
        selectedInputUID: String,
        selectedOutputUIDs: Set<String>,
        mixMuted: Bool,
        mixer: LiveMixer?,
        sessionFile: URL?,
        sessionBitRate: Int,
        startedAt: Date?
    ) {
        levelLock.lock()
        defer { levelLock.unlock() }
        
        var snap = LevelSnapshot()
        snap.inputs = inputs
        snap.taps = taps
        snap.system = system
        snap.playbackDeviceUID = playbackDeviceUID
        snap.defaultOutputUID = defaultOutputUID
        snap.selectedInputUID = selectedInputUID
        snap.selectedOutputUIDs = selectedOutputUIDs
        snap.mixMuted = mixMuted
        snap.mixer = mixer
        snap.sessionFile = sessionFile
        snap.sessionBitRate = sessionBitRate
        snap.startedAt = startedAt
        levelSnapshot = snap
    }
    
    // MARK: - Level Metering Methods
    
    /// Live meter for the monitor. Does not publish `devices` (that rebuilt SwiftUI).
    func meterLevel(for row: RecordingDeviceRow) -> Float {
        levelLock.lock()
        let snap = levelSnapshot
        levelLock.unlock()
        
        switch row.kind {
        case .input:
            return snap.inputs[row.id]?.level ?? 0
        case .output:
            let uid = String(row.id.dropFirst(4))
            let device = snap.taps[uid]?.level ?? 0
            if uid == snap.playbackDeviceUID || uid == snap.defaultOutputUID {
                return max(device, snap.system?.level ?? 0)
            }
            return device
        }
    }
    
    func meterLinearPeak(for row: RecordingDeviceRow) -> Float {
        guard row.kind == .input else { return 0 }
        levelLock.lock()
        let capture = levelSnapshot.inputs[row.id]
        levelLock.unlock()
        return capture?.linearPeak ?? 0
    }
    
    /// Actual rate delivered by the currently open source stream.
    func sourceSampleRate(for row: RecordingDeviceRow) -> Double {
        levelLock.lock()
        let snap = levelSnapshot
        levelLock.unlock()
        
        switch row.kind {
        case .input:
            return snap.inputs[row.id]?.sourceSampleRate ?? 0
        case .output:
            let uid = String(row.id.dropFirst(4))
            if uid == snap.playbackDeviceUID || uid == snap.defaultOutputUID {
                return snap.system?.sourceSampleRate ?? snap.taps[uid]?.sourceSampleRate ?? 0
            }
            return snap.taps[uid]?.sourceSampleRate ?? 0
        }
    }
    
    /// Real file size plus a bitrate guess for PCM not yet on disk (current RAM chunk).
    /// Elapsed audio in the current mix file (resets if the file is recreated).
    func recordedElapsedSeconds() -> Int {
        levelLock.lock()
        let mixer = levelSnapshot.mixer
        let started = levelSnapshot.startedAt
        levelLock.unlock()
        
        if let mixer {
            return max(0, Int(mixer.recordedDuration()))
        }
        guard let start = started else { return 0 }
        return max(0, Int(Date().timeIntervalSince(start)))
    }
    
    func mixSizeChipText() -> String {
        levelLock.lock()
        let url = levelSnapshot.sessionFile
        let extra = levelSnapshot.mixer?.unflushedDuration() ?? 0
        let rate = levelSnapshot.sessionBitRate
        levelLock.unlock()
        
        let bytes: Int64
        if let url,
           FileManager.default.fileExists(atPath: url.path),
           let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        {
            bytes = size.int64Value
        } else {
            bytes = 0
        }
        return RecordingBitRate.resolved(rate / 1_000).sizeChipText(onDisk: bytes, extra: extra)
    }
    
    /// Peak of mic + playback — for the monitor waveform.
    func liveWaveformLevel() -> Float {
        levelLock.lock()
        let snap = levelSnapshot
        levelLock.unlock()
        
        let mic = snap.mixMuted ? 0 : (snap.inputs[snap.selectedInputUID]?.level ?? 0)
        let defaultUID = snap.defaultOutputUID
        var play: Float = 0
        if !defaultUID.isEmpty, snap.selectedOutputUIDs.contains(defaultUID) {
            play = max(play, snap.system?.level ?? 0)
        }
        for uid in snap.selectedOutputUIDs where uid != defaultUID {
            play = max(play, snap.taps[uid]?.level ?? 0)
        }
        return min(1, max(mic, play))
    }
    
    // MARK: - Access to Level Snapshot Properties
    
    /// Get current selected input UID
    var selectedInputUID: String {
        levelLock.lock()
        let uid = levelSnapshot.selectedInputUID
        levelLock.unlock()
        return uid
    }
    
    /// Get current mix muted state
    var mixMuted: Bool {
        levelLock.lock()
        let muted = levelSnapshot.mixMuted
        levelLock.unlock()
        return muted
    }
    
    /// Get current inputs
    var inputs: [String: InputDeviceCapture] {
        levelLock.lock()
        let inputs = levelSnapshot.inputs
        levelLock.unlock()
        return inputs
    }
    
    /// Set the mix muted state
    func setMixMuted(_ muted: Bool) {
        levelLock.lock()
        levelSnapshot.mixMuted = muted
        levelLock.unlock()
    }
}
