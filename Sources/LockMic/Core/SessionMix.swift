import AppKit
import AVFoundation
import AudioToolbox
import Foundation

/// Fold live-mix AAC slices and wrap ADTS to m4a.
enum SessionMix {
    /// Attach a finished ADTS slice onto the dated mix; then delete the slice.
    static func appendSegment(_ segment: URL, onto mix: URL) throws {
        try waitUntilPlayable(segment)
        try appendADTS(segment, onto: mix)
    }

    /// ADTS AAC frames are self-contained — append bytes, no re-encode.
    private static func appendADTS(_ segment: URL, onto mix: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: mix.path) {
            try fm.moveItem(at: segment, to: mix)
            return
        }
        let data = try Data(contentsOf: segment)
        guard !data.isEmpty else { throw SessionRecorderError.mixFailed }
        let handle = try FileHandle(forWritingTo: mix)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try? fm.removeItem(at: segment)
    }

    /// Decode `AppLogo` on the main thread before a background wrap touches metadata.
    static func prepareArtwork() {
        _ = albumArtPNG
    }

    /// Copy ADTS packets into an m4a so Finder/QuickTime duration matches playback (no re-encode).
    static func wrapADTStoM4A(from input: URL, to output: URL) throws {
        try? FileManager.default.removeItem(at: output)
        var inFile: AudioFileID?
        var status = AudioFileOpenURL(input as CFURL, .readPermission, kAudioFileAAC_ADTSType, &inFile)
        guard status == noErr, let inFile else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        defer { AudioFileClose(inFile) }

        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioFileGetProperty(inFile, kAudioFilePropertyDataFormat, &asbdSize, &asbd)
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }

        var outFile: AudioFileID?
        status = AudioFileCreateWithURL(output as CFURL, kAudioFileM4AType, &asbd, .eraseFile, &outFile)
        guard status == noErr, let outFile else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        defer { AudioFileClose(outFile) }

        var cookieSize: UInt32 = 0
        if AudioFileGetPropertyInfo(inFile, kAudioFilePropertyMagicCookieData, &cookieSize, nil) == noErr,
           cookieSize > 0
        {
            var cookie = [UInt8](repeating: 0, count: Int(cookieSize))
            AudioFileGetProperty(inFile, kAudioFilePropertyMagicCookieData, &cookieSize, &cookie)
            AudioFileSetProperty(outFile, kAudioFilePropertyMagicCookieData, cookieSize, cookie)
        }

        var packet: Int64 = 0
        let maxPackets: UInt32 = 64
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        while true {
            var numBytes = UInt32(buffer.count)
            var numPackets = maxPackets
            var descs = [AudioStreamPacketDescription](
                repeating: AudioStreamPacketDescription(), count: Int(maxPackets)
            )
            status = AudioFileReadPacketData(
                inFile, false, &numBytes, &descs, packet, &numPackets, &buffer
            )
            if numPackets == 0 { break }
            if status != noErr, status != kAudioFileEndOfFileError {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            var written = numPackets
            status = AudioFileWritePackets(outFile, false, numBytes, descs, packet, &written, buffer)
            guard status == noErr else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            packet += Int64(numPackets)
        }
        guard packet > 0 else { throw SessionRecorderError.mixFailed }
        applyLockMicMetadata(outFile, url: output)
    }

    /// Finder/Music tags + app logo as cover. Best-effort; wrap already has the audio.
    private static func applyLockMicMetadata(_ file: AudioFileID, url: URL) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let app = version.isEmpty ? "LockMic" : "LockMic \(version)"
        let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
        let year = String(Calendar.current.component(.year, from: Date()))
        var info: [String: String] = [
            kAFInfoDictionary_Title: url.deletingPathExtension().lastPathComponent,
            kAFInfoDictionary_Artist: "LockMic",
            kAFInfoDictionary_Album: "LockMic",
            kAFInfoDictionary_EncodingApplication: app,
            kAFInfoDictionary_Comments: "Recorded with \(app)",
            kAFInfoDictionary_RecordedDate: ISO8601DateFormatter().string(from: Date()),
            kAFInfoDictionary_Year: year,
        ]
        if !copyright.isEmpty {
            info[kAFInfoDictionary_Copyright] = copyright
        }
        var dict = info as CFDictionary
        _ = AudioFileSetProperty(
            file,
            kAudioFilePropertyInfoDictionary,
            UInt32(MemoryLayout<CFDictionary>.size),
            &dict
        )
        guard let art = albumArtPNG else { return }
        var writable: UInt32 = 0
        if AudioFileGetPropertyInfo(file, kAudioFilePropertyAlbumArtwork, nil, &writable) == noErr,
           writable == 0
        {
            return
        }
        var data = art as CFData
        _ = AudioFileSetProperty(
            file,
            kAudioFilePropertyAlbumArtwork,
            UInt32(MemoryLayout<CFData>.size),
            &data
        )
    }

    private static let albumArtPNG: Data? = {
        guard let image = NSImage(named: "AppLogo") ?? NSImage(named: "AppIcon") else { return nil }
        let dim = 512
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: dim,
            pixelsHigh: dim,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: dim, height: dim)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: dim, height: dim),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }()

    private static func waitUntilPlayable(_ url: URL) throws {
        for _ in 0..<50 {
            if (try? AVAudioFile(forReading: url)) != nil { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw SessionRecorderError.mixFailed
    }
}
