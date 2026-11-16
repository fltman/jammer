import Compression
import Foundation

/// A project file is shared between people and opened with a double-click, so what is in it is
/// as untrusted as an audio file from the net. This is where a project read from disk (the
/// package, its history, saved window state) is checked before anything acts on it: absurd
/// sizes are refused, values that can't be are repaired or dropped, and nothing in it gets to
/// say which bytes of which file are read (`SourcePool` checks every file against its own header).
public enum ProjectSafety {
    public struct Limits: Sendable {
        public var tracks = 1_024
        public var clips = 500_000
        public var sources = 50_000
        public var markers = 100_000
        /// project.json, and each decompressed history state.
        public var bytes = 256 << 20
        public init() {}
    }

    /// The longest timeline: ten days at the project's rate. Positions beyond it are a broken file.
    static func horizon(_ rate: Double) -> Frame { Frame(10 * 86_400 * rate) }

    /// Refuses a project that can't be one, repairs what can be repaired in place, and returns
    /// what was changed, in words (empty when nothing was).
    @discardableResult
    public static func check(_ p: inout Project, limits: Limits = Limits()) throws -> [String] {
        if let no = AudioFileInfo.refusal(channels: p.channels, sampleRate: p.sampleRate) {
            throw AudioFileError.unreadable("The project can't be opened. \(no.replacingOccurrences(of: "The file says", with: "It says"))")
        }
        func tooMany(_ n: Int, _ what: String, _ most: Int) -> AudioFileError {
            .unreadable("The project can't be opened: it has \(n) \(what), and Jämmer takes at most \(most).")
        }
        guard p.tracks.count <= limits.tracks else { throw tooMany(p.tracks.count, "tracks", limits.tracks) }
        let clips = p.tracks.reduce(0) { $0 + $1.clips.count }
        guard clips <= limits.clips else { throw tooMany(clips, "clips", limits.clips) }
        guard p.sources.count <= limits.sources else { throw tooMany(p.sources.count, "audio files", limits.sources) }
        guard p.markers.count <= limits.markers else { throw tooMany(p.markers.count, "markers", limits.markers) }

        var notes: [String] = []
        // Sources whose description of their own audio makes no sense can't be played.
        let before = p.sources.count
        p.sources.removeAll { s in
            AudioFileInfo.refusal(channels: s.info.channels, sampleRate: s.info.sampleRate) != nil || s.info.frames < 0 || s.info.dataOffset < 0
        }
        if p.sources.count < before { notes.append("\(before - p.sources.count) audio file\(before - p.sources.count == 1 ? "" : "s") in the project had an impossible description and \(before - p.sources.count == 1 ? "was" : "were") left out.") }
        let frames = Dictionary(p.sources.map { ($0.id, $0.info.frames) }, uniquingKeysWith: { a, _ in a })
        let horizon = horizon(p.sampleRate)
        var dropped = 0
        for t in p.tracks.indices {
            if !p.tracks[t].gainDB.isFinite { p.tracks[t].gainDB = 0 }
            p.tracks[t].gainDB = min(60, max(-200, p.tracks[t].gainDB))
            p.tracks[t].name = String(p.tracks[t].name.prefix(500))
            var kept: [Clip] = []
            for var c in p.tracks[t].clips {
                // A clip has to lie inside its file and inside the timeline.
                guard let have = frames[c.sourceID], c.start >= 0, c.start <= horizon, c.sourceStart >= 0, c.sourceStart < have, c.length > 0 else { dropped += 1; continue }
                c.length = min(c.length, have - c.sourceStart, horizon)
                c.gainDB = c.gainDB.isFinite ? min(60, max(-200, c.gainDB)) : 0
                c.fadeIn = min(c.length, max(0, c.fadeIn))
                c.fadeOut = min(c.length, max(0, c.fadeOut))
                kept.append(c)
            }
            p.tracks[t].clips = kept
            // What the track played before a ducking is used again by the next one: it has to pass the
            // same checks, and be what this track still plays, or it is forgotten.
            if let o = p.tracks[t].ducked {
                let sound = o.clips.count <= 10_000 && o.clips.allSatisfy { c in
                    guard let have = frames[c.sourceID] else { return false }
                    return c.start >= 0 && c.start <= horizon && c.sourceStart >= 0 && c.sourceStart < have && c.length > 0
                        && c.length <= have - c.sourceStart && c.gainDB.isFinite && abs(c.gainDB) <= 200
                        && c.fadeIn >= 0 && c.fadeIn <= c.length && c.fadeOut >= 0 && c.fadeOut <= c.length
                }
                if !sound || kept != [o.bounce] { p.tracks[t].ducked = nil }
            }
        }
        if dropped > 0 { notes.append("\(dropped) clip\(dropped == 1 ? "" : "s") pointed outside \(dropped == 1 ? "its" : "their") audio or the timeline and \(dropped == 1 ? "was" : "were") left out.") }
        let markers = p.markers.count
        p.markers.removeAll { $0.position < 0 || $0.position > horizon || $0.length < 0 }
        for m in p.markers.indices {
            p.markers[m].length = min(p.markers[m].length, horizon)
            p.markers[m].name = String(p.markers[m].name.prefix(500))
        }
        if p.markers.count < markers { notes.append("\(markers - p.markers.count) marker\(markers - p.markers.count == 1 ? "" : "s") outside the timeline \(markers - p.markers.count == 1 ? "was" : "were") left out.") }
        return notes
    }

    /// LZFSE data expanded, but never past `limit` bytes: a few kilobytes can be made to expand
    /// to gigabytes. Throws when the limit is reached or the data isn't LZFSE.
    public static func decompress(_ data: Data, limit: Int) throws -> Data {
        guard !data.isEmpty else { return Data() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZFSE) == COMPRESSION_STATUS_OK else {
            throw AudioFileError.unreadable("The project's history can't be read.")
        }
        defer { compression_stream_destroy(stream) }
        let chunk = 1 << 16
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        var out = Data()
        try data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            stream.pointee.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!
            stream.pointee.src_size = src.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = chunk
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                out.append(buffer, count: chunk - stream.pointee.dst_size)
                guard out.count <= limit else { throw AudioFileError.unreadable("The project's history is larger than any real history and wasn't read.") }
                if status == COMPRESSION_STATUS_END { break }
                guard status == COMPRESSION_STATUS_OK else { throw AudioFileError.unreadable("The project's history is damaged.") }
            }
        }
        return out
    }
}
