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
            throw AudioFileError.unreadable(Said("error.file.cantOpen", "Jämmer can't open %1$@. %2$@", url.lastPathComponent, inner: why))
        } catch { own = nil }
        if let info = own, info.frames == 0 {
            throw AudioFileError.unreadable(Said("error.file.has_sound_file_may", "%@ has no sound in it (the file may have been cut off).", "\(url.lastPathComponent)"))
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
            guard info.frames > 0 else { throw AudioFileError.unreadable(Said("error.file.has_sound_file_may2", "%@ has no sound in it (the file may be cut off or damaged).", "\(url.lastPathComponent)")) }
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
            throw AudioFileError.unsupported(Said("error.export.j_mmer_can_t", "Jämmer can't read %@: it isn't audio in a format this Mac can decode.", "\(url.lastPathComponent)"))
        }
        let input = file.processingFormat
        let channels = Int(input.channelCount)
        let rate = sampleRate ?? input.sampleRate
        // What the decoder says about the file is as untrusted as the file.
        if let no = AudioFileInfo.refusal(channels: channels, sampleRate: input.sampleRate) { throw AudioFileError.unsupported(Said("error.file.cantRead", "Jämmer can't read %1$@. %2$@", url.lastPathComponent, inner: no)) }
        func tooLarge(_ bytes: Double) -> AudioFileError {
            .unsupported(Said("error.file.tooLarge", "%1$@ is too large to open here: decoded it would take %2$@ GB, and %3$@ GB is what Jämmer may use on this disk.", values: ["\(url.lastPathComponent)", Said.n(bytes / 1_073_741_824, 1), Said.n(Double(limit) / 1_073_741_824, 1)]))
        }
        // By what it says of itself first, so a long file is refused before any of it is written…
        let claimed = Double(max(0, file.length)) * rate / input.sampleRate * Double(channels) * 4
        guard claimed <= Double(limit) else { throw tooLarge(claimed) }
        // Another rate than the document's: the file is decoded at its own rate and converted by the app's one
        // converter (r8brain, registered at SampleRateConversion), the same that exports use. Without it
        // (a build that leaves it out) the system's converter does both, as it did before 2026-11-16.
        let stream = input.sampleRate != rate ? try SampleRateConversion.factory?(input.sampleRate, rate, channels) : nil
        let decodeRate = stream == nil ? rate : input.sampleRate
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: decodeRate,
                                         channels: AVAudioChannelCount(channels), interleaved: true) else {
            throw AudioFileError.unsupported(Said("error.export.unsupported_channel_layout", "Unsupported channel layout in %@.", "\(url.lastPathComponent)"))
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appending(path: "\(url.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.prefix(8)).wav")
        let writer = try WAVWriter(url: dest, options: .init(encoding: .float32, channels: channels, sampleRate: rate))
        // Whatever goes wrong from here, no half-decoded file is left behind.
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: dest) } }
        var written: Int64 = 0
        guard let converter = AVAudioConverter(from: input, to: output) else {
            throw AudioFileError.unsupported(Said("error.export.can_t_convert_1", "Can't convert %1$@ to %2$@ Hz.", "\(url.lastPathComponent)", "\(Int(rate))"))
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        let chunk: AVAudioFrameCount = 32_768
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: chunk) else { throw AudioFileError.unsupported(Said("error.export.out_memory", "Out of memory.")) }
        let outCapacity = AVAudioFrameCount(Double(chunk) * decodeRate / input.sampleRate) + 1_024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: outCapacity) else { throw AudioFileError.unsupported(Said("error.export.out_memory", "Out of memory.")) }
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
                    throw AudioFileError.unsupported(Said("error.export.cut_short_ends_before", "%@ is cut short: it ends before the sound it says it has, so it can't be opened.", "\(url.lastPathComponent)"))
                }
                throw AudioFileError.unsupported(Said("error.export.1_couldn_t_decoded", "%1$@ couldn't be decoded; it is damaged or not what its name says (error %2$@).", "\(url.lastPathComponent)", "\((e as NSError).code)"))
            }
            if outBuf.frameLength > 0, let data = outBuf.floatChannelData {
                // …and by what actually comes out, since the header can say less than there is.
                let block = UnsafeBufferPointer(start: data[0], count: Int(outBuf.frameLength) * channels)
                if let stream {
                    let converted = stream.process(Array(block))
                    written += Int64(converted.count) * 4
                    guard written <= limit else { throw tooLarge(Double(written)) }
                    try writer.write(converted)
                } else {
                    written += Int64(block.count) * 4
                    guard written <= limit else { throw tooLarge(Double(written)) }
                    try writer.write(block)
                }
            }
            progress(min(1, Double(file.framePosition) / total))
            if status == .endOfStream || status == .error { break }
        }
        if let stream { try writer.write(stream.finish()) }
        try writer.finish()
        finished = true
        return (dest, Double(max(0, file.length)) / input.sampleRate)
    }
}
