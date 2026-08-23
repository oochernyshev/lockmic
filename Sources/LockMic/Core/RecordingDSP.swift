import Accelerate
import AVFoundation
import Foundation

/// Shared 0…1 meter scale so HAL peaks and AVAudioRecorder dB match on the wave.
enum RecordingLevelDisplay {
    static let noiseFloorDB: Float = -38
    static let fullScaleDB: Float = -6

    static func fromAverageDB(_ db: Float) -> Float {
        min(1, max(0, (db - noiseFloorDB) / (fullScaleDB - noiseFloorDB)))
    }

    static func fromLinearPeak(_ peak: Float) -> Float {
        let p = min(1, max(0, peak))
        guard p > 0.0002 else { return 0 }
        return fromAverageDB(20 * log10(p))
    }
}

/// Hot-path DSP for capture IO. Avoid per-sample Swift loops and extra allocations.
enum RecordingDSP {
    static func peak(in buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else {
            return peak(in: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList))
        }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var peak: Float = 0
        for ch in 0..<Int(buffer.format.channelCount) {
            var channelPeak: Float = 0
            vDSP_maxmgv(channels[ch], 1, &channelPeak, vDSP_Length(frames))
            peak = max(peak, channelPeak)
        }
        return min(1, peak)
    }

    static func peak(in abl: UnsafeMutableAudioBufferListPointer) -> Float {
        var peak: Float = 0
        for buffer in abl {
            guard let raw = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            var channelPeak: Float = 0
            vDSP_maxmgv(raw.assumingMemoryBound(to: Float.self), 1, &channelPeak, vDSP_Length(count))
            peak = max(peak, channelPeak)
        }
        return min(1, peak)
    }

    static func isLinearFloat32(_ format: AVAudioFormat) -> Bool {
        if format.commonFormat == .pcmFormatFloat32 { return true }
        let asbd = format.streamDescription.pointee
        return asbd.mFormatID == kAudioFormatLinearPCM
            && asbd.mBitsPerChannel == 32
            && (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    }

    /// Frame count from a float ABL. Uses the buffer layout, not `AVAudioFormat` interleaving.
    static func floatFrames(in abl: UnsafeMutableAudioBufferListPointer) -> Int {
        guard let first = abl.first, first.mDataByteSize > 0 else { return 0 }
        let channels = max(1, Int(first.mNumberChannels))
        var count = Int(first.mDataByteSize) / (channels * MemoryLayout<Float>.size)
        if abl.count > 1, abl[1].mDataByteSize > 0 {
            let ch = max(1, Int(abl[1].mNumberChannels))
            count = min(count, Int(abl[1].mDataByteSize) / (ch * MemoryLayout<Float>.size))
        }
        return max(0, count)
    }

    static func copy(_ abl: UnsafeMutableAudioBufferListPointer, into dest: AVAudioPCMBuffer) {
        let dst = UnsafeMutableAudioBufferListPointer(dest.mutableAudioBufferList)
        for (from, to) in zip(abl, dst) {
            guard let source = from.mData, let destPtr = to.mData else { continue }
            memcpy(destPtr, source, min(Int(from.mDataByteSize), Int(to.mDataByteSize)))
        }
    }

    static func copyStrided(
        source: UnsafePointer<Float>,
        stride: Int,
        frames: Int,
        dest: UnsafeMutablePointer<Float>
    ) {
        guard frames > 0, stride > 0 else { return }
        cblas_scopy(Int32(frames), source, Int32(stride), dest, 1)
    }

    static func deinterleaveStereo(
        source: UnsafePointer<Float>,
        sourceChannels: Int,
        leftOffset: Int,
        frames: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>
    ) {
        guard frames > 0, sourceChannels > 0 else { return }
        copyStrided(source: source + leftOffset, stride: sourceChannels, frames: frames, dest: left)
        let rightOffset = min(leftOffset + 1, sourceChannels - 1)
        copyStrided(source: source + rightOffset, stride: sourceChannels, frames: frames, dest: right)
    }

    /// RMS of two equal-length channels (playback ducking).
    static func rms(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frames: Int
    ) -> Float {
        guard frames > 0 else { return 0 }
        var sumL: Float = 0
        var sumR: Float = 0
        let n = vDSP_Length(frames)
        vDSP_svesq(left, 1, &sumL, n)
        vDSP_svesq(right, 1, &sumR, n)
        return sqrt((sumL + sumR) / Float(frames * 2))
    }

    static func clear(_ dest: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        vDSP_vclr(dest, 1, vDSP_Length(frames))
    }

    static func add(
        _ source: UnsafePointer<Float>,
        onto dest: UnsafeMutablePointer<Float>,
        frames: Int
    ) {
        guard frames > 0 else { return }
        vDSP_vadd(source, 1, dest, 1, dest, 1, vDSP_Length(frames))
    }

    /// `out = clamp(play + mono * gain, -1, 1)` on both channels.
    static func mixMonoOntoStereo(
        mono: UnsafePointer<Float>,
        playLeft: UnsafePointer<Float>,
        playRight: UnsafePointer<Float>,
        gain: Float,
        frames: Int,
        outLeft: UnsafeMutablePointer<Float>,
        outRight: UnsafeMutablePointer<Float>
    ) {
        guard frames > 0 else { return }
        var scalar = gain
        let n = vDSP_Length(frames)
        vDSP_vsma(mono, 1, &scalar, playLeft, 1, outLeft, 1, n)
        vDSP_vsma(mono, 1, &scalar, playRight, 1, outRight, 1, n)
        var lo: Float = -1
        var hi: Float = 1
        vDSP_vclip(outLeft, 1, &lo, &hi, outLeft, 1, n)
        vDSP_vclip(outRight, 1, &lo, &hi, outRight, 1, n)
    }
}

enum RecordingSilence {
    static func frameCount(in abl: UnsafeMutableAudioBufferListPointer, format: AVAudioFormat) -> AVAudioFrameCount {
        guard let first = abl.first else { return 0 }
        if format.isInterleaved {
            let bytesPerFrame = max(1, Int(format.streamDescription.pointee.mBytesPerFrame))
            return AVAudioFrameCount(Int(first.mDataByteSize) / bytesPerFrame)
        }
        return AVAudioFrameCount(Int(first.mDataByteSize) / MemoryLayout<Float>.size)
    }

    static func zero(_ buffer: AVAudioPCMBuffer) {
        buffer.frameLength = buffer.frameCapacity
        if let channels = buffer.floatChannelData {
            for ch in 0..<Int(buffer.format.channelCount) {
                channels[ch].update(repeating: 0, count: Int(buffer.frameCapacity))
            }
        } else {
            let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for buf in abl {
                if let dest = buf.mData {
                    memset(dest, 0, Int(buf.mDataByteSize))
                }
            }
        }
    }
}
