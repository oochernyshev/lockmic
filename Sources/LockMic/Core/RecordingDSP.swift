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

    static func fill(_ dest: UnsafeMutablePointer<Float>, value: Float, frames: Int) {
        guard frames > 0 else { return }
        var scalar = value
        vDSP_vfill(&scalar, dest, 1, vDSP_Length(frames))
    }

    /// Resample linear float to mix rate, carrying phase across HAL callbacks.
    static func convertToMixRate(
        _ buffer: AVAudioPCMBuffer,
        dest: inout AVAudioPCMBuffer?,
        using state: MixRateResampler
    ) -> AVAudioPCMBuffer? {
        state.convert(buffer, dest: &dest)
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

/// Streaming linear SRC onto `RecordingCodec.sampleRate`.
///
/// Per-buffer endpoint mapping clicked at every USB period (Jabra ~90 ms)
/// because the interval between the last sample of one IO callback and the
/// first sample of the next was never interpolated.
final class MixRateResampler {
    private let channels: Int
    private let outRate: Double = RecordingCodec.sampleRate
    private var last: [Float]
    private var frac: Double = 0
    private var primed = false
    private var inRate: Double = 0

    init(channels: AVAudioChannelCount) {
        self.channels = Int(max(1, channels))
        last = [Float](repeating: 0, count: self.channels)
    }

    func reset() {
        frac = 0
        primed = false
        inRate = 0
        for i in last.indices { last[i] = 0 }
    }

    func convert(_ buffer: AVAudioPCMBuffer, dest: inout AVAudioPCMBuffer?) -> AVAudioPCMBuffer? {
        let target = RecordingCodec.pcmFormat(channels: AVAudioChannelCount(channels))
        if buffer.format.sampleRate == outRate
            && buffer.format.channelCount == AVAudioChannelCount(channels)
            && RecordingDSP.isLinearFloat32(buffer.format)
            && !buffer.format.isInterleaved
        {
            if primed { reset() }
            return buffer
        }
        guard RecordingDSP.isLinearFloat32(buffer.format),
              let src = buffer.floatChannelData
        else { return nil }
        let srcN = Int(buffer.frameLength)
        guard srcN > 0 else { return nil }
        let srcRate = buffer.format.sampleRate
        if abs(srcRate - inRate) > 0.01 {
            reset()
            inRate = srcRate
        }
        let step = inRate / outRate
        guard step > 0, step.isFinite else { return nil }
        let maxOut = max(1, Int((Double(srcN) / step).rounded(.up)) + 4)
        let need = AVAudioFrameCount(maxOut)
        if dest == nil || dest!.format.channelCount != AVAudioChannelCount(channels)
            || dest!.frameCapacity < need
        {
            dest = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: max(need, 2048))
        }
        guard let out = dest, let dst = out.floatChannelData else { return nil }
        let srcCh = Int(buffer.format.channelCount)
        let startFrac = frac
        let startPrimed = primed
        var produced = 0
        for ch in 0..<channels {
            var f = startFrac
            var p = startPrimed
            produced = Self.resampleChannel(
                source: src[min(ch, max(0, srcCh - 1))],
                srcCount: srcN,
                dest: dst[ch],
                destCapacity: maxOut,
                last: &last[ch],
                frac: &f,
                primed: &p,
                step: step
            )
            if ch == channels - 1 {
                frac = f
                primed = p
            }
        }
        out.frameLength = AVAudioFrameCount(produced)
        return produced > 0 ? out : nil
    }

    private static func resampleChannel(
        source: UnsafePointer<Float>,
        srcCount: Int,
        dest: UnsafeMutablePointer<Float>,
        destCapacity: Int,
        last: inout Float,
        frac: inout Double,
        primed: inout Bool,
        step: Double
    ) -> Int {
        var i = 0
        var s0 = last
        if !primed {
            s0 = source[0]
            primed = true
            i = 1
            frac = 0
            if srcCount == 1 {
                dest[0] = s0
                last = s0
                return 1
            }
        }
        var di = 0
        while di < destCapacity {
            while frac >= 1, i < srcCount {
                frac -= 1
                s0 = source[i]
                i += 1
            }
            if i >= srcCount { break }
            let s1 = source[i]
            dest[di] = s0 + (s1 - s0) * Float(frac)
            di += 1
            frac += step
        }
        last = s0
        return di
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
