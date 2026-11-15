import AVFAudio
import Foundation

/// Brings audio files into a project. PCM WAV/AIFF at the project rate is
/// played straight from the file; anything else (MP3, AAC, FLAC, ALAC, CAF,
/// another sample rate) is decoded once into a float WAV in `mediaFolder`.
public enum AudioImporter {
    public struct Result: Sendable {
        public var source: SourceRef
        /// True when the samples were decoded into a new file.
        public var decoded: Bool
        /// Something the user should know about what opened: the file was cut short, so less
        /// sound came in than its header promises.
        public var warning: String?
    }

    /// The words for a file that holds less than it says.
    static func shortWarning(_ name: String, got: Double, claimed: Double) -> String {
        String(format: "%@ is cut short or damaged: %.1f s of the %.1f s it says it has could be read.", name, got, claimed)
    }

    /// The most a decoded file may take on disk unless the caller says otherwise: what is free
    /// where the media goes, less a margin so the Mac isn't left full, and never more than 64 GB.
    /// A compressed file can decode to thousands of times its size (hours of silence in a small
    /// FLAC), and its header can lie about how long it is.
    public static func decodedLimit(in folder: URL) -> Int64 {
        var at = folder
        while !FileManager.default.fileExists(atPath: at.path), at.path != "/" { at.deleteLastPathComponent() }
        let free = (try? at.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        return max(0, min(64 << 30, free - (2 << 30)))
    }

    /// - Parameter sampleRate: the project's rate, or nil to keep the file's.
    /// - Parameter maxDecodedBytes: see `decodedLimit(in:)`; nil uses it.
    public static func importFile(_ url: URL, sampleRate: Double? = nil, mediaFolder: URL, maxDecodedBytes: Int64? = nil,
                                  progress: @Sendable (Double) -> Void = { _ in }) throws -> Result {
        let name = url.deletingPathExtension().lastPathComponent
        let own: AudioFileInfo?
        do { own = try AudioFileReader.info(at: url) } catch AudioFileError.unreadable(let why) where isPCMContainer(url) {
            // It is a WAV or AIFF and Jämmer's own reader found it broken or absurd. Handing it to
            // the system's decoder for a second opinion would let through what was just refused.
            throw AudioFileError.unreadable("Jämmer can't open \(url.lastPathComponent). \(why)")
        } catch { own = nil }
        if let info = own, info.frames == 0 {
            throw AudioFileError.unreadable("\(url.lastPathComponent) has no sound in it (the file may have been cut off).")
        }
        let ownWarning = own.flatMap { info in
            info.claimedFrames.map { shortWarning(url.lastPathComponent, got: Double(info.frames) / info.sampleRate, claimed: Double($0) / info.sampleRate) }
        }
        if let info = own, sampleRate == nil || sampleRate == info.sampleRate {
            let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            return Result(source: SourceRef(name: name, path: url.path, bookmark: bookmark, info: info), decoded: false, warning: ownWarning)
        }
        let (decodedURL, claimedSeconds) = try decode(url, to: mediaFolder, sampleRate: sampleRate, limit: maxDecodedBytes ?? decodedLimit(in: mediaFolder), progress: progress)
        var info: AudioFileInfo
        do {
            info = try AudioFileReader.info(at: decodedURL)
            guard info.frames > 0 else { throw AudioFileError.unreadable("\(url.lastPathComponent) has no sound in it (the file may be cut off or damaged).") }
        } catch {
            try? FileManager.default.removeItem(at: decodedURL)
            throw error
        }
        // Keep markers and Broadcast Wave data from the original when it had them.
        if let original = try? AudioFileReader.info(at: url) {
            let ratio = info.sampleRate / original.sampleRate
            info.markers = original.markers.map { FileMarker(position: Int64(Double($0.position) * ratio), length: Int64(Double($0.length) * ratio), name: $0.name) }
            info.bext = original.bext
            info.ixml = original.ixml
        }
        // A compressed file that stops early decodes to less than its header promised.
        let got = Double(info.frames) / info.sampleRate
        let warning = ownWarning ?? (claimedSeconds > 0.5 && got < claimedSeconds * 0.98 ? shortWarning(url.lastPathComponent, got: got, claimed: claimedSeconds) : nil)
        return Result(source: SourceRef(name: name, path: decodedURL.path, info: info, originalPath: url.path), decoded: true, warning: warning)
    }

    /// True when the file starts like a WAV (RIFF, RF64, BW64) or an AIFF (FORM), whatever its name says.
    static func isPCMContainer(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let magic = String(decoding: (try? h.read(upToCount: 4)) ?? Data(), as: UTF8.self)
        return ["RIFF", "RF64", "BW64", "FORM"].contains(magic)
    }

    /// Decodes any file AVFoundation reads into a 32-bit float WAV (RF64 past 4 GB).
    /// Returns the decoded file and how long the original says it is, in seconds.
    static func decode(_ url: URL, to folder: URL, sampleRate: Double?, limit: Int64, progress: (Double) -> Void) throws -> (URL, Double) {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch {
            // AVFoundation's own text is a bare error code; say what it means.
            throw AudioFileError.unsupported("Jämmer can't read \(url.lastPathComponent): it isn't audio in a format this Mac can decode.")
        }
        let input = file.processingFormat
        let channels = Int(input.channelCount)
        let rate = sampleRate ?? input.sampleRate
        // What the decoder says about the file is as untrusted as the file.
        if let no = AudioFileInfo.refusal(channels: channels, sampleRate: input.sampleRate) { throw AudioFileError.unsupported("Jämmer can't read \(url.lastPathComponent). \(no)") }
        func tooLarge(_ bytes: Double) -> AudioFileError {
            .unsupported(String(format: "%@ is too large to open here: decoded it would take %.1f GB, and %.1f GB is what Jämmer may use on this disk.",
                                url.lastPathComponent, bytes / 1_073_741_824, Double(limit) / 1_073_741_824))
        }
        // By what it says of itself first, so a long file is refused before any of it is written…
        let claimed = Double(max(0, file.length)) * rate / input.sampleRate * Double(channels) * 4
        guard claimed <= Double(limit) else { throw tooLarge(claimed) }
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                         channels: AVAudioChannelCount(channels), interleaved: true) else {
            throw AudioFileError.unsupported("Unsupported channel layout in \(url.lastPathComponent).")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appending(path: "\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.prefix(8)).wav")
        let writer = try WAVWriter(url: dest, options: .init(encoding: .float32, channels: channels, sampleRate: rate))
        // Whatever goes wrong from here, no half-decoded file is left behind.
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: dest) } }
        var written: Int64 = 0
        guard let converter = AVAudioConverter(from: input, to: output) else {
            throw AudioFileError.unsupported("Can't convert \(url.lastPathComponent) to \(Int(rate)) Hz.")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        let chunk: AVAudioFrameCount = 32_768
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: chunk) else { throw AudioFileError.unsupported("Out of memory.") }
        let outCapacity = AVAudioFrameCount(Double(chunk) * rate / input.sampleRate) + 1_024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: outCapacity) else { throw AudioFileError.unsupported("Out of memory.") }
        let total = max(1, Double(file.length))
        final class State: @unchecked Sendable { var done = false; var error: Error? }
        let state = State()
        while true {
            outBuf.frameLength = 0
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError) { _, outStatus in
                if state.done || file.framePosition >= file.length {
                    state.done = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inBuf, frameCount: chunk)
                } catch {
                    state.error = error
                    state.done = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inBuf.frameLength == 0 {
                    state.done = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuf
            }
            if let e = convError ?? state.error {
                // -39 is "end of file": the audio stops before the file says it should.
                if (e as NSError).code == -39 {
                    throw AudioFileError.unsupported("\(url.lastPathComponent) is cut short: it ends before the sound it says it has, so it can't be opened.")
                }
                throw AudioFileError.unsupported("\(url.lastPathComponent) couldn't be decoded; it is damaged or not what its name says (error \((e as NSError).code)).")
            }
            if outBuf.frameLength > 0, let data = outBuf.floatChannelData {
                // …and by what actually comes out, since the header can say less than there is.
                written += Int64(outBuf.frameLength) * Int64(channels) * 4
                guard written <= limit else { throw tooLarge(Double(written)) }
                try writer.write(UnsafeBufferPointer(start: data[0], count: Int(outBuf.frameLength) * channels))
            }
            progress(min(1, Double(file.framePosition) / total))
            if status == .endOfStream || status == .error { break }
        }
        try writer.finish()
        finished = true
        return (dest, Double(max(0, file.length)) / input.sampleRate)
    }
}
