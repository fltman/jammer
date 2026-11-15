import AudioToolbox
import Foundation

/// An audio file a sibling app (Flimmer) handed Jämmer to edit (SIBLINGS.md §6): the
/// document plays from a copy, and Save Back writes the mix into this same file, in its
/// format, sample rate and bit depth, in place (same inode, so the other app's file watch
/// sees it). Autosave never touches it.
public struct LinkedFile: Sendable, Equatable {
    public enum Format: String, Sendable { case wav, aiff, flac }

    public var url: URL
    public var format: Format
    /// 16, 24 or 32 (32 only as float WAV).
    public var bitDepth: Int
    public var isFloat: Bool
    public var sampleRate: Double
    public var channels: Int
    /// The app that asked, for display ("Flimmer").
    public var requester: String

    public var fileName: String { url.lastPathComponent }

    /// Nil for files Jämmer can't write back exactly (other formats or bit depths, more
    /// than two channels); those open as ordinary new projects.
    public init?(url: URL, requester: String) {
        self.url = url
        self.requester = requester
        switch url.pathExtension.lowercased() {
        case "wav", "wave", "bwf":
            guard let info = try? AudioFileReader.info(at: url), [.wav, .rf64, .bw64].contains(info.container) else { return nil }
            switch info.sampleFormat {
            case .int16: bitDepth = 16; isFloat = false
            case .int24: bitDepth = 24; isFloat = false
            case .float32: bitDepth = 32; isFloat = true
            default: return nil
            }
            format = .wav
            sampleRate = info.sampleRate
            channels = info.channels
        case "aif", "aiff":
            guard let info = try? AudioFileReader.info(at: url), info.container == .aiff else { return nil }
            switch info.sampleFormat {
            case .int16: bitDepth = 16
            case .int24: bitDepth = 24
            default: return nil
            }
            isFloat = false
            format = .aiff
            sampleRate = info.sampleRate
            channels = info.channels
        case "flac":
            guard let d = Self.dataFormat(url), d.mFormatID == kAudioFormatFLAC else { return nil }
            switch d.mFormatFlags {
            case kAppleLosslessFormatFlag_16BitSourceData: bitDepth = 16
            case kAppleLosslessFormatFlag_24BitSourceData: bitDepth = 24
            default: return nil
            }
            isFloat = false
            format = .flac
            sampleRate = d.mSampleRate
            channels = Int(d.mChannelsPerFrame)
        default:
            return nil
        }
        guard (1...2).contains(channels) else { return nil }
    }

    static func dataFormat(_ url: URL) -> AudioStreamBasicDescription? {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return nil }
        defer { AudioFileClose(file) }
        var d = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        return AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &d) == noErr ? d : nil
    }

    /// Renders `range` of `plan` in the file's format into a scratch file of our own,
    /// then replaces the linked file's contents with it, in place, under file coordination.
    /// WAV keeps the original's Broadcast Wave and iXML data and its foreign chunks, and
    /// gets the document's markers as cue points.
    public func write(_ plan: RenderPlan, range: Range<Frame>, markers: [FileMarker], scratch: URL) throws {
        guard plan.channels == channels, plan.sampleRate == sampleRate else {
            throw ExportError.unsupported("The document no longer matches \(fileName) (\(channels) channel\(channels == 1 ? "" : "s") at \(Int(sampleRate)) Hz).")
        }
        let tmp = scratch.appending(path: "\(UUID().uuidString).\(url.pathExtension)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        switch format {
        case .wav:
            let original = try AudioFileReader.info(at: url)
            var options = WAVWriter.Options(encoding: bitDepth == 16 ? .int16 : (bitDepth == 24 ? .int24 : .float32),
                                            channels: channels, sampleRate: sampleRate)
            options.bext = original.bext
            options.ixml = original.ixml
            options.markers = markers
            options.foreignChunks = try Self.foreignChunks(of: url, info: original)
            let w = try WAVWriter(url: tmp, options: options)
            try plan.render(range) { try w.write($0) }
            try w.finish()
        case .aiff, .flac:
            try EncodedWriter.export(plan, range: range, to: tmp,
                                     options: EncodedExportOptions(format: format == .aiff ? .aiff : .flac, bitDepth: bitDepth))
        }
        try Self.replaceContents(of: url, with: tmp)
    }

    /// WAV chunks Jämmer doesn't write itself (it regenerates fmt, data, bext, iXML, cue
    /// and the adtl labels), so they survive the round trip.
    static func foreignChunks(of url: URL, info: AudioFileInfo) throws -> [(id: String, payload: Data)] {
        let ours: Set<String> = ["fmt ", "data", "bext", "iXML", "cue ", "ds64", "JUNK", "fact", "FLLR", "PAD ", "junk"]
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var out: [(String, Data)] = []
        for c in info.chunks where !ours.contains(c.id) && c.size < 64 << 20 {
            try h.seek(toOffset: UInt64(c.offset))
            let payload = try h.read(upToCount: Int(c.size)) ?? Data()
            // LIST chunks holding marker labels are regenerated; LIST INFO (title, artist…) stays.
            if c.id == "LIST", payload.prefix(4) == Data("adtl".utf8) { continue }
            out.append((c.id, payload))
        }
        return out
    }

    /// Copies `source`'s bytes over `target`'s, keeping the target file (and its inode).
    static func replaceContents(of target: URL, with source: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: target, options: [], error: &coordinationError) { url in
            do {
                let input = try FileHandle(forReadingFrom: source)
                defer { try? input.close() }
                let output = try FileHandle(forWritingTo: url)
                defer { try? output.close() }
                try output.truncate(atOffset: 0)
                while let chunk = try input.read(upToCount: 8 << 20), !chunk.isEmpty { try output.write(contentsOf: chunk) }
                try output.synchronize()
            } catch {
                writeError = error
            }
        }
        if let e = coordinationError ?? writeError { throw e }
    }
}
