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
        // More buses than Jämmer makes is a file that Jämmer didn't make: refused, not cut down in silence.
        guard p.buses.count <= Mixer.maxBuses else { throw tooMany(p.buses.count, "buses", Mixer.maxBuses) }

        var notes: [String] = []
        // The mixer: buses with two of the same id, routes to buses that aren't there, loops, and values
        // that are not levels or pans. What can be put right is put right and said; a loop is cut where it closes.
        do {
            var seen = Set<UUID>(), unique: [Bus] = []
            for b in p.buses where seen.insert(b.id).inserted { unique.append(b) }
            if unique.count < p.buses.count { notes.append("\(p.buses.count - unique.count) bus\(p.buses.count - unique.count == 1 ? "" : "es") had the same id as another and \(p.buses.count - unique.count == 1 ? "was" : "were") left out.") }
            p.buses = unique
            var fixed = 0, lost = 0
            func level(_ v: Double) -> Double { v.isFinite ? min(Mixer.gainRange.upperBound, max(Mixer.gainRange.lowerBound, v)) : 0 }
            func pan(_ v: Double) -> Double { v.isFinite && p.channels == 2 ? min(1, max(-1, v)) : 0 }
            for i in p.buses.indices {
                let b = p.buses[i]
                p.buses[i].gainDB = level(b.gainDB)
                p.buses[i].pan = pan(b.pan)
                p.buses[i].name = String(b.name.prefix(200))
                if p.buses[i].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { p.buses[i].name = "Bus \(i + 1)" }
                if p.buses[i].gainDB != b.gainDB || p.buses[i].pan != b.pan { fixed += 1 }
                if let o = b.output, !seen.contains(o) || o == b.id { p.buses[i].output = nil; lost += 1 }
            }
            // Sends: to a bus that is there, one per bus, a level that is a level, sixteen at most on a strip.
            func tidy(_ sends: [Send], own: UUID?) -> [Send] {
                var to = Set<UUID>(), out: [Send] = []
                for var s in sends where seen.contains(s.to) && s.to != own && to.insert(s.to).inserted && out.count < Mixer.maxSends {
                    s.gainDB = level(s.gainDB)
                    out.append(s)
                }
                return out
            }
            for i in p.buses.indices {
                let kept = tidy(p.buses[i].sends, own: p.buses[i].id)
                lost += p.buses[i].sends.count - kept.count
                p.buses[i].sends = kept
            }
            for i in p.buses.indices {
                if let o = p.buses[i].output, p.loops(bus: p.buses[i].id, into: o) {
                    p.buses[i].output = nil
                    lost += 1
                }
                // A send that leads back to its own bus is taken away, one at a time, so the rest stay.
                for s in p.buses[i].sends where p.loops(bus: p.buses[i].id, into: s.to) {
                    p.buses[i].sends.removeAll { $0.to == s.to }
                    lost += 1
                }
            }
            for t in p.tracks.indices {
                let kept = tidy(p.tracks[t].sends, own: nil)
                lost += p.tracks[t].sends.count - kept.count
                p.tracks[t].sends = kept
            }
            for t in p.tracks.indices {
                let old = p.tracks[t].pan
                p.tracks[t].pan = pan(old)
                if p.tracks[t].pan != old { fixed += 1 }
                if let o = p.tracks[t].output, !seen.contains(o) { p.tracks[t].output = nil; lost += 1 }
            }
            // Plugins: sixty-four on a strip is more than anyone puts there; a file with more is cut to that and says so.
            // VCAs: twins dropped, levels brought into range, members of a VCA that isn't there released.
            var known = Set<UUID>(), groups: [VCA] = []
            for v in p.vcas.prefix(Mixer.maxVCAs) where known.insert(v.id).inserted { groups.append(v) }
            if groups.count < p.vcas.count { notes.append("\(p.vcas.count - groups.count) VCA\(p.vcas.count - groups.count == 1 ? "" : "s") in the project had the same id as another, or came after the \(Mixer.maxVCAs) a document can have, and \(p.vcas.count - groups.count == 1 ? "was" : "were") left out.") }
            p.vcas = groups
            for i in p.vcas.indices {
                let v = p.vcas[i]
                p.vcas[i].gainDB = level(v.gainDB)
                if p.vcas[i].gainDB != v.gainDB { fixed += 1 }
                p.vcas[i].name = String(v.name.prefix(200))
                if p.vcas[i].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { p.vcas[i].name = "VCA \(i + 1)" }
            }
            var strays = 0
            for t in p.tracks.indices { if let v = p.tracks[t].vca, !known.contains(v) { p.tracks[t].vca = nil; strays += 1 } }
            for b in p.buses.indices { if let v = p.buses[b].vca, !known.contains(v) { p.buses[b].vca = nil; strays += 1 } }
            if strays > 0 { notes.append("\(strays) strip\(strays == 1 ? "" : "s") belonged to a VCA that isn't in the project and \(strays == 1 ? "plays" : "play") at \(strays == 1 ? "its" : "their") own level.") }
            // Keys: one that names a strip that isn't there, or the strip it sits on, or a plugin on the master,
            // is taken away; then any that close a loop, one at a time, until none does.
            let strips = Set(p.tracks.map(\.id)).union(seen)
            var keysGone = 0
            for t in p.tracks.indices { for i in p.tracks[t].inserts.indices { if let k = p.tracks[t].inserts[i].key, !strips.contains(k) || k == p.tracks[t].id { p.tracks[t].inserts[i].key = nil; keysGone += 1 } } }
            for b in p.buses.indices { for i in p.buses[b].inserts.indices { if let k = p.buses[b].inserts[i].key, !strips.contains(k) || k == p.buses[b].id { p.buses[b].inserts[i].key = nil; keysGone += 1 } } }
            for i in p.master.inserts.indices where p.master.inserts[i].key != nil { p.master.inserts[i].key = nil; keysGone += 1 }
            loops: while p.hasKeyLoop {
                for t in p.tracks.indices.reversed() { for i in p.tracks[t].inserts.indices.reversed() where p.tracks[t].inserts[i].key != nil {
                    let k = p.tracks[t].inserts[i].key!
                    if p.reaches(from: p.tracks[t].id, to: k) { p.tracks[t].inserts[i].key = nil; keysGone += 1; continue loops }
                } }
                for b in p.buses.indices.reversed() { for i in p.buses[b].inserts.indices.reversed() where p.buses[b].inserts[i].key != nil {
                    let k = p.buses[b].inserts[i].key!
                    if p.reaches(from: p.buses[b].id, to: k) { p.buses[b].inserts[i].key = nil; keysGone += 1; continue loops }
                } }
                break
            }
            if keysGone > 0 { notes.append("\(keysGone) plugin\(keysGone == 1 ? "" : "s") listened to a track or bus that isn't there, or to one that it feeds; \(keysGone == 1 ? "it plays" : "they play") without that key.") }
            // Frozen strips: a freeze whose file isn't among the sources, or that isn't of what the strip is
            // now (a file edited by hand), is taken away, so the strip plays live rather than something stale.
            var thawed = 0
            let sourceIDs = Set(p.sources.map(\.id))
            for t in p.tracks.indices { if let f = p.tracks[t].frozen, !sourceIDs.contains(f.sourceID) || f.length <= 0 || p.content(of: p.tracks[t].id) != f.madeFrom { p.tracks[t].frozen = nil; thawed += 1 } }
            for b in p.buses.indices { if let f = p.buses[b].frozen, !sourceIDs.contains(f.sourceID) || f.length <= 0 || p.content(of: p.buses[b].id) != f.madeFrom { p.buses[b].frozen = nil; thawed += 1 } }
            if thawed > 0 { notes.append("\(thawed) frozen track\(thawed == 1 ? "" : "s") or bus\(thawed == 1 ? "" : "es") didn't match \(thawed == 1 ? "its" : "their") frozen file and \(thawed == 1 ? "plays" : "play") live instead.") }
            var cut = 0
            for t in p.tracks.indices where p.tracks[t].inserts.count > 64 { cut += p.tracks[t].inserts.count - 64; p.tracks[t].inserts = Array(p.tracks[t].inserts.prefix(64)) }
            for b in p.buses.indices where p.buses[b].inserts.count > 64 { cut += p.buses[b].inserts.count - 64; p.buses[b].inserts = Array(p.buses[b].inserts.prefix(64)) }
            if p.master.inserts.count > 64 { cut += p.master.inserts.count - 64; p.master.inserts = Array(p.master.inserts.prefix(64)) }
            // The master: a level that is one, and a limiter whose values the limiter itself accepts, or none.
            if !p.master.gainDB.isFinite || !Mixer.gainRange.contains(p.master.gainDB) {
                p.master.gainDB = p.master.gainDB.isFinite ? min(max(p.master.gainDB, Mixer.gainRange.lowerBound), Mixer.gainRange.upperBound) : 0
                fixed += 1
            }
            if let l = p.master.limiter, (try? l.settings.validate()) == nil {
                p.master.limiter = nil
                notes.append("The limiter on the master had values no limiter can have and was left off. Put it back in the mixer before exporting.")
            }
            if cut > 0 { notes.append("\(cut) plugin\(cut == 1 ? "" : "s") beyond the 64 a track or bus can have \(cut == 1 ? "was" : "were") left out.") }
            if lost > 0 { notes.append("\(lost) route\(lost == 1 ? "" : "s") or send\(lost == 1 ? "" : "s") in the mixer led to a bus that isn't there, or round in a circle; a route now goes to the output and a send is gone.") }
            if fixed > 0 { notes.append("\(fixed) level\(fixed == 1 ? "" : "s") or pan\(fixed == 1 ? "" : "s") in the mixer \(fixed == 1 ? "was" : "were") outside what is possible and \(fixed == 1 ? "was" : "were") put inside.") }
        }
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
