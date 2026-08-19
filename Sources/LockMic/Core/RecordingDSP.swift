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
