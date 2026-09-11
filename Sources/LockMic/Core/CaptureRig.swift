import Foundation
import QuartzCore

/// Owns the live HAL capture/tap/mixer state for a session: the per-device input
/// captures, the playback taps, the system playback tap, the live mixer, and the
/// file/bit-rate/start-time of the current mix. Not thread-safe on its own —
/// `SessionRecorder` touches this exclusively from its own queue-confined methods.
final class CaptureRig {
    var inputCaptures: [String: InputDeviceCapture] = [:]
    var playbackTaps: [String: PlaybackCapturing] = [:]
    /// System process mix — not bound to a hardware output, so device switches stay continuous.
    var systemPlaybackTap: PlaybackCapturing?
    var liveMixer: LiveMixer?
    var sessionFile: URL?
    var sessionBitRate: Int = RecordingBitRate.default.bitsPerSecond
    var sessionStart: CFTimeInterval = 0
    /// Bumped on every playback-tap resync request; a completed resync checks it's
    /// still current before applying its results.
    var playbackTapSync = 0

    struct HardwareSnapshot {
        var inputs: [InputDeviceCapture]
        var taps: [PlaybackCapturing]
        var mixer: LiveMixer?
    }

    @available(macOS 14.2, *)
    func attachPlaybackTap(_ tap: PlaybackTap, onFormatChange: @escaping () -> Void) {
        tap.mixer = liveMixer
        tap.onFormatChange = onFormatChange
    }

    /// Pull out (and stop tracking) any narrowband tap whose preferred stream index has
    /// moved. Caller is responsible for `.stop()`-ing the returned taps and, if any were
    /// removed, resyncing playback taps afterward.
    @available(macOS 14.2, *)
    func detachRetargetedNarrowbandTaps(audio: AudioDeviceService) -> [PlaybackCapturing] {
        var toStop: [PlaybackCapturing] = []
        for uid in Array(playbackTaps.keys) {
            guard let tap = playbackTaps[uid], tap.isNarrowband else { continue }
            guard let device = audio.listOutputDevices().first(where: { $0.uid == uid }) else { continue }
            let preferred = PlaybackTap.preferredOutputStreamIndex(device.id)
            guard preferred != tap.streamIndex else { continue }
            sessionRecorderLog.info(
                "Retarget playback tap \(uid, privacy: .public) stream \(tap.streamIndex, privacy: .public) → \(preferred, privacy: .public)"
            )
            playbackTaps.removeValue(forKey: uid)
            liveMixer?.removePlaybackSource(uid)
            toStop.append(tap)
        }
        return toStop
    }

    /// Detach every HAL resource this rig owns, returning it as an inert snapshot for
    /// off-queue teardown via `stopHardware`. Leaves the rig empty.
    func takeSnapshot() -> HardwareSnapshot {
        let inputs = Array(inputCaptures.values)
        inputCaptures.removeAll()
        let taps: [PlaybackCapturing] = Array(playbackTaps.values) + [systemPlaybackTap].compactMap { $0 }
        playbackTaps.removeAll()
        systemPlaybackTap = nil
        let mixer = liveMixer
        liveMixer = nil
        mixer?.removeAllPlaybackSources()
        return HardwareSnapshot(inputs: inputs, taps: taps, mixer: mixer)
    }

    /// Stop every HAL resource immediately (used on `deinit`, where nothing can be awaited).
    /// Returns the live mixer, if any, so the caller can stop it off-queue.
    func stopAllForTeardown() -> LiveMixer? {
        for capture in inputCaptures.values { capture.stop() }
        for tap in playbackTaps.values { tap.stop() }
        systemPlaybackTap?.stop()
        let mixer = liveMixer
        liveMixer = nil
        return mixer
    }

    /// HAL Stop/Destroy and the ADTS→m4a wrap never run on the recording queue or
    /// MainActor — those deadlocks Core Audio and freeze the monitor.
    nonisolated static func stopHardware(_ snapshot: HardwareSnapshot) async -> URL? {
        for capture in snapshot.inputs { capture.stop() }
        for tap in snapshot.taps { tap.stop() }
        await withTaskGroup(of: Void.self) { group in
            for capture in snapshot.inputs {
                group.addTask { await capture.waitUntilStopped() }
            }
            for tap in snapshot.taps {
                group.addTask { await tap.waitUntilStopped() }
            }
            await group.waitForAll()
        }
        guard let mixer = snapshot.mixer else { return nil }
        let mixQueue = DispatchQueue(label: "com.lockmic.mix-halt")
        return await AudioHAL.run(on: mixQueue, timeout: 20) {
            mixer.stop()
            return mixer.url
        } ?? mixer.url
    }
}
