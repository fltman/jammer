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
    public static func check(_ p: inout Project, limits: Limits = Limits()) throws -> [Said] {
        if let no = AudioFileInfo.refusal(channels: p.channels, sampleRate: p.sampleRate) {
            throw AudioFileError.unreadable(Said("error.project.refused", "The project can't be opened. %@", inner: no))
        }
        func tooMany(_ said: Said) -> AudioFileError { .unreadable(said) }
        guard p.tracks.count <= limits.tracks else {
            throw tooMany(Said("error.project.tooManyTracks", "The project can't be opened: it has %1$@ tracks, and Jämmer takes at most %2$@.", "\(p.tracks.count)", "\(limits.tracks)"))
        }
        let clips = p.tracks.reduce(0) { $0 + $1.clips.count }
        guard clips <= limits.clips else {
            throw tooMany(Said("error.project.tooManyClips", "The project can't be opened: it has %1$@ clips, and Jämmer takes at most %2$@.", "\(clips)", "\(limits.clips)"))
        }
        guard p.sources.count <= limits.sources else {
            throw tooMany(Said("error.project.tooManyFiles", "The project can't be opened: it has %1$@ audio files, and Jämmer takes at most %2$@.", "\(p.sources.count)", "\(limits.sources)"))
        }
        guard p.markers.count <= limits.markers else {
            throw tooMany(Said("error.project.tooManyMarkers", "The project can't be opened: it has %1$@ markers, and Jämmer takes at most %2$@.", "\(p.markers.count)", "\(limits.markers)"))
        }
        // More buses than Jämmer makes is a file that Jämmer didn't make: refused, not cut down in silence.
        guard p.buses.count <= Mixer.maxBuses else {
            throw tooMany(Said("error.project.tooManyBuses", "The project can't be opened: it has %1$@ buses, and Jämmer takes at most %2$@.", "\(p.buses.count)", "\(Mixer.maxBuses)"))
        }

        var notes: [Said] = []
        // Automation: before the mixer is looked at, because what a frozen strip was made from includes the
        // lanes of what feeds it. A lane on a strip that isn't there, of a sort this build doesn't play, a
        // twin of another lane, or with nothing usable in it, is left out; values that aren't levels are
        // brought into range; points out of order are sorted, two at one frame become one, points outside
        // the timeline's horizon go, and a lane with more points than Jämmer writes is cut to that. Said.
        if !p.automation.isEmpty {
            let groups = Set(p.vcas.map(\.id))
            let strips = Set(p.tracks.map(\.id)).union(p.buses.map(\.id)).union([Master.id]).union(groups)
            var kept: [AutomationLane] = [], left = 0, mended = 0
            var seenLanes = Set<String>()
            let horizon = Self.horizon(p.sampleRate)
            for lane in p.automation.prefix(4_096) {
                // A send's lane needs its send; the master has a level only; a VCA group a level and a mute.
                guard strips.contains(lane.strip),
                      lane.param == .send ? (lane.to.map { p.hasSend(from: lane.strip, to: $0) } == true) : lane.to == nil,
                      lane.param == .gain || lane.strip != Master.id, lane.param != .pan || p.channels == 2,
                      !groups.contains(lane.strip) || lane.param == .gain || lane.param == .mute,
                      seenLanes.insert("\(lane.strip)|\(lane.param.rawValue)|\(lane.to?.uuidString ?? "")").inserted else { left += 1; continue }
                var l = lane
                // A mute holds, a level and a pan go in straight lines: a file that says otherwise is put right.
                l.shape = lane.param == .mute ? .hold : .linear
                let allowed = Automation.range(of: lane.param)
                var at = Set<Frame>()
                l.points = lane.points.prefix(Automation.maxPoints * 4)
                    .filter { $0.value.isFinite && $0.frame >= 0 && $0.frame <= horizon }
                    .sorted { $0.frame < $1.frame }
                    .filter { at.insert($0.frame).inserted }
                    .prefix(Automation.maxPoints)
                    .map { AutomationPoint(frame: $0.frame, value: lane.param == .mute ? ($0.value >= 0.5 ? 1 : 0) : min(allowed.upperBound, max(allowed.lowerBound, $0.value))) }
                if l.points.isEmpty { left += 1; continue }
                if l.points != lane.points || l.shape != lane.shape { mended += 1 }
                kept.append(l)
            }
            left += max(0, p.automation.count - 4_096)
            p.automation = kept
            if left > 0 { notes.append(counted(left, Said("project.repaired.lanesLeftOut.one", "1 automation lane in the project was for a track or bus that isn't there, of a kind this Jämmer doesn't play, or had no usable points, and was left out: that level is the fader's."), Said("project.repaired.lanesLeftOut.other", "%@ automation lanes in the project were for a track or bus that isn't there, of a kind this Jämmer doesn't play, or had no usable points, and were left out: those levels are the fader's.", "\(left)"))) }
            if mended > 0 { notes.append(counted(mended, Said("project.repaired.lanesMended.one", "1 automation lane had points that were out of order, doubled, outside the timeline or not levels; it was put right. Listen before you export."), Said("project.repaired.lanesMended.other", "%@ automation lanes had points that were out of order, doubled, outside the timeline or not levels; they were put right. Listen before you export.", "\(mended)"))) }
        }
        // The mixer: buses with two of the same id, routes to buses that aren't there, loops, and values
        // that are not levels or pans. What can be put right is put right and said; a loop is cut where it closes.
        do {
            var seen = Set<UUID>(), unique: [Bus] = []
            for b in p.buses where seen.insert(b.id).inserted { unique.append(b) }
            if unique.count < p.buses.count { notes.append(counted((p.buses.count - unique.count), Said("project.repaired.buses.one", "1 bus had the same id as another and was left out."), Said("project.repaired.buses.other", "%@ buses had the same id as another and were left out.", "\((p.buses.count - unique.count))"))) }
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
            if groups.count < p.vcas.count { notes.append(counted(p.vcas.count - groups.count, Said("project.repaired.vcas.one", "1 VCA in the project had the same id as another, or came after the %@ a document can have, and was left out.", "\(Mixer.maxVCAs)"), Said("project.repaired.vcas.other", "%1$@ VCAs in the project had the same id as another, or came after the %2$@ a document can have, and were left out.", "\(p.vcas.count - groups.count)", "\(Mixer.maxVCAs)"))) }
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
            if strays > 0 { notes.append(counted(strays, Said("project.repaired.strays.one", "1 strip belonged to a VCA that isn't in the project and plays at its own level."), Said("project.repaired.strays.other", "%@ strips belonged to a VCA that isn't in the project and play at their own level.", "\(strays)"))) }
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
            if keysGone > 0 { notes.append(counted(keysGone, Said("project.repaired.keys.one", "1 plugin listened to a track or bus that isn't there, or to one that it feeds; it plays without that key."), Said("project.repaired.keys.other", "%@ plugins listened to a track or bus that isn't there, or to one that it feeds; they play without that key.", "\(keysGone)"))) }
            // Frozen strips: a freeze whose file isn't among the sources, or that isn't of what the strip is
            // now (a file edited by hand), is taken away, so the strip plays live rather than something stale.
            var thawed = 0
            let sourceIDs = Set(p.sources.map(\.id))
            for t in p.tracks.indices { if let f = p.tracks[t].frozen, !sourceIDs.contains(f.sourceID) || f.length <= 0 || p.content(of: p.tracks[t].id) != f.madeFrom { p.tracks[t].frozen = nil; thawed += 1 } }
            for b in p.buses.indices { if let f = p.buses[b].frozen, !sourceIDs.contains(f.sourceID) || f.length <= 0 || p.content(of: p.buses[b].id) != f.madeFrom { p.buses[b].frozen = nil; thawed += 1 } }
            if thawed > 0 { notes.append(counted(thawed, Said("project.repaired.thawed.one", "1 frozen track or bus didn't match its frozen file and plays live instead."), Said("project.repaired.thawed.other", "%@ frozen tracks or buses didn't match their frozen files and play live instead.", "\(thawed)"))) }
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
                notes.append(Said("project.repaired.limiter_master_had_values", "The limiter on the master had values no limiter can have and was left off. Put it back in the mixer before exporting."))
            }
            if cut > 0 { notes.append(counted(cut, Said("project.repaired.pluginsCut.one", "1 plugin beyond the 64 a track or bus can have was left out."), Said("project.repaired.pluginsCut.other", "%@ plugins beyond the 64 a track or bus can have were left out.", "\(cut)"))) }
            if lost > 0 { notes.append(counted(lost, Said("project.repaired.routes.one", "1 route or send in the mixer led to a bus that isn't there, or round in a circle; a route now goes to the output and a send is gone."), Said("project.repaired.routes.other", "%@ routes or sends in the mixer led to a bus that isn't there, or round in a circle; a route now goes to the output and a send is gone.", "\(lost)"))) }
            if fixed > 0 { notes.append(counted(fixed, Said("project.repaired.levels.one", "1 level or pan in the mixer was outside what is possible and was put inside."), Said("project.repaired.levels.other", "%@ levels or pans in the mixer were outside what is possible and were put inside.", "\(fixed)"))) }
        }
        // Sources whose description of their own audio makes no sense can't be played.
        let before = p.sources.count
        p.sources.removeAll { s in
            AudioFileInfo.refusal(channels: s.info.channels, sampleRate: s.info.sampleRate) != nil || s.info.frames < 0 || s.info.dataOffset < 0
        }
        if p.sources.count < before { notes.append(counted((before - p.sources.count), Said("project.repaired.files.one", "1 audio file in the project had an impossible description and was left out."), Said("project.repaired.files.other", "%@ audio files in the project had an impossible description and were left out.", "\((before - p.sources.count))"))) }
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
        if dropped > 0 { notes.append(counted(dropped, Said("project.repaired.clips.one", "1 clip pointed outside its audio or the timeline and was left out."), Said("project.repaired.clips.other", "%@ clips pointed outside their audio or the timeline and were left out.", "\(dropped)"))) }
        let markers = p.markers.count
        p.markers.removeAll { $0.position < 0 || $0.position > horizon || $0.length < 0 }
        for m in p.markers.indices {
            p.markers[m].length = min(p.markers[m].length, horizon)
            p.markers[m].name = String(p.markers[m].name.prefix(500))
        }
        if p.markers.count < markers { notes.append(counted((markers - p.markers.count), Said("project.repaired.markers.one", "1 marker outside the timeline was left out."), Said("project.repaired.markers.other", "%@ markers outside the timeline were left out.", "\((markers - p.markers.count))"))) }
        return notes
    }

    /// LZFSE data expanded, but never past `limit` bytes: a few kilobytes can be made to expand
    /// to gigabytes. Throws when the limit is reached or the data isn't LZFSE.
    public static func decompress(_ data: Data, limit: Int) throws -> Data {
        guard !data.isEmpty else { return Data() }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZFSE) == COMPRESSION_STATUS_OK else {
            throw AudioFileError.unreadable(Said("error.file.project_s_history_can", "The project's history can't be read."))
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
                guard out.count <= limit else { throw AudioFileError.unreadable(Said("error.file.project_s_history_larger", "The project's history is larger than any real history and wasn't read.")) }
                if status == COMPRESSION_STATUS_END { break }
                guard status == COMPRESSION_STATUS_OK else { throw AudioFileError.unreadable(Said("error.file.project_s_history_damaged", "The project's history is damaged.")) }
            }
        }
        return out
    }
}
