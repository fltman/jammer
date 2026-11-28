import Foundation

/// ADM objects (ITU-R BS.2076-3, read at the source: § 5.3–5.6, 5.13, 6, 7, 8 and Annex 2 § 3): a track placed by the
/// surround panner, as an object with its place over time, beside the bed the rest is mixed into (ADM.swift).
///
/// - An object is typeDefinition "Objects" (typeLabel 0003, Table A1-7); its pack, channel, track and stream
///   formats are custom (xxxx from 1000, § 6), one channel each, PCM, with audioTrackFormat and audioStreamFormat as
///   Annex 2's example has them (§ 5.1 lets PCM leave them out, but readers are to tolerate them and older ones
///   expect them).
/// - A place is polar: azimuth −180…180 degrees, positive to the left (anticlockwise seen from above, § 8), the
///   same as Jämmer's panner; elevation −90…90, positive up; distance 1, the sphere (Table A1-17).
/// - Over time: one audioBlockFormat per stretch between automation points, its position the one at its end, the
///   renderer moving there across the block (jumpPosition 0, § 9.3), or held from its start (jumpPosition 1) where
///   the lane holds. One block with no rtime or duration when the place doesn't move (§ 5.4.1).
/// - A stereo track is two objects, its left and right channels at azimuth ± width/2, where the panner puts them.
/// - Times are the sample-based form hh:mm:ss.zzzzzSfffff (§ 5.13), exact at any rate.
public enum ADMObjects {
    public struct Block: Equatable, Sendable {
        /// Seconds from the start of the file; nil with `duration` nil: the whole file.
        public var start: Frame?
        public var duration: Frame?
        public var azimuth: Double
        public var elevation: Double
        public var jump: Bool
        public init(start: Frame?, duration: Frame?, azimuth: Double, elevation: Double, jump: Bool = false) {
            self.start = start; self.duration = duration; self.azimuth = azimuth; self.elevation = elevation; self.jump = jump
        }
    }

    public struct Object: Equatable, Sendable {
        public var name: String
        /// The track it comes from, and which of its channels (nil: a mono track, or a stereo one summed).
        public var track: UUID
        public var channel: Int?
        public var blocks: [Block]
    }

    /// −180…180, the way ADM says an azimuth.
    static func wrapped(_ a: Double) -> Double {
        var x = (a + 180).truncatingRemainder(dividingBy: 360)
        if x < 0 { x += 360 }
        return x - 180 == -180 && a > 0 ? 180 : x - 180
    }

    /// The tracks that are objects: placed by the surround panner in a loudspeaker layout wider than stereo, their
    /// clips mono or stereo. (A track playing a sound field, or one with a wider clip, stays in the bed.)
    public static func tracks(_ project: Project) -> [Track] {
        guard project.channels > 2, !project.layout.isAmbisonic else { return [] }
        return project.tracks.filter { t in
            guard t.position != nil, !project.playsField(t) else { return false }
            let widths = t.clips.compactMap { project.source($0.sourceID)?.info.channels }
            return !widths.isEmpty && widths.allSatisfy { $0 <= 2 }
        }
    }

    /// The objects of `project` over `range` (frames of the document; blocks start from its lower bound).
    public static func objects(_ project: Project, range: Range<Frame>) -> [Object] {
        var out: [Object] = []
        for t in tracks(project) {
            guard let place = t.position else { continue }
            let az = project.lane(strip: t.id, param: .azimuth).flatMap { $0.enabled && !$0.points.isEmpty ? $0 : nil }
            let el = project.lane(strip: t.id, param: .elevation).flatMap { $0.enabled && !$0.points.isEmpty ? $0 : nil }
            let stereo = t.clips.contains { (project.source($0.sourceID)?.info.channels ?? 1) == 2 }
            let offsets: [(Int?, Double)] = stereo ? [(0, place.width / 2), (1, -place.width / 2)] : [(nil, 0)]
            func at(_ f: Frame) -> (Double, Double) {
                (az?.value(at: f) ?? place.azimuth, min(90, max(-90, el?.value(at: f) ?? place.elevation)))
            }
            var blocks: [Block] = []
            let marks = Set(([az, el].compactMap { $0 }.flatMap { $0.points.map(\.frame) }).filter { $0 > range.lowerBound && $0 < range.upperBound })
            if marks.isEmpty {
                let (a, e) = at(range.lowerBound)
                blocks = [Block(start: nil, duration: nil, azimuth: a, elevation: e)]
            } else {
                let held = az?.shape == .hold || el?.shape == .hold
                let edges = [range.lowerBound] + marks.sorted() + [range.upperBound]
                for (a, b) in zip(edges, edges.dropFirst()) where b > a {
                    // Linear: where it is at the block's end, reached across it; held: its value from the start.
                    let (x, y) = held ? at(a) : at(b)
                    blocks.append(Block(start: a - range.lowerBound, duration: b - a, azimuth: x, elevation: y, jump: held))
                }
            }
            for (channel, offset) in offsets {
                let name = stereo ? "\(t.name) \(channel == 0 ? "L" : "R")" : t.name
                out.append(Object(name: name, track: t.id, channel: channel,
                                  blocks: blocks.map { var b = $0; b.azimuth = wrapped(b.azimuth + offset); return b }))
            }
        }
        return out
    }

    /// A time in the sample-based form hh:mm:ss.zzzzzSfffff (§ 5.13): whole seconds and the frames left over.
    static func time(_ frames: Frame, rate: Double) -> String {
        let r = Int64(rate.rounded()), s = frames / r, rest = frames % r
        let digits = String(r).count
        return String(format: "%02lld:%02lld:%02lld.", s / 3_600, s / 60 % 60, s % 60) + String(format: "%0\(digits)lld", rest) + "S\(r)"
    }

    static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The `chna` and `axml` chunks for a file whose first channels are `layout`'s bed (the common definitions, as
    /// ADM.chunks writes them) and whose next channels are `objects`, one each, in order. nil without objects or
    /// for a layout with no bed (mono, stereo, Ambisonics).
    public static func chunks(bed layout: ChannelLayout, objects: [Object], title: String, rate: Double) -> [(id: String, payload: Data)]? {
        guard !objects.isEmpty, objects.count <= 0xEFF, let pack = ADM.packFormat(layout) else { return nil }
        let bedFormats = layout.speakers.compactMap { ADM.channelFormat($0, in: layout) }
        guard bedFormats.count == layout.channels else { return nil }
        let bedTracks = bedFormats.map { String(format: "AT_000100%02x_01", $0) }
        let n = bedTracks.count + objects.count
        let uids = (1...n).map { String(format: "ATU_%08x", $0) }
        let hex = objects.indices.map { String(format: "%04x", 0x1001 + $0) }

        var chna = Data()
        chna.u16le(UInt16(n)); chna.u16le(UInt16(n))
        for k in 0..<n {
            let (track, packRef) = k < bedTracks.count ? (bedTracks[k], pack) : ("AT_0003\(hex[k - bedTracks.count])_01", "AP_0003\(hex[k - bedTracks.count])")
            chna.u16le(UInt16(k + 1))
            chna.append(Data(uids[k].utf8)); chna.append(Data(track.utf8)); chna.append(Data(packRef.utf8)); chna.append(0)
        }

        let name = escaped(title.isEmpty ? "Jammer" : String(title.prefix(200)))
        var x = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ebuCoreMain xmlns="urn:ebu:metadata-schema:ebuCore_2016" xmlns:dc="http://purl.org/dc/elements/1.1/" schema="EBU_CORE_20161025.xsd" xml:lang="en">
          <coreMetadata>
            <format>
              <audioFormatExtended version="ITU-R_BS.2076-3">
                <audioProgramme audioProgrammeID="APR_1001" audioProgrammeName="\(name)">
                  <audioContentIDRef>ACO_1001</audioContentIDRef>
                </audioProgramme>
                <audioContent audioContentID="ACO_1001" audioContentName="\(name)">

        """
        x += "          <audioObjectIDRef>AO_1001</audioObjectIDRef>\n"
        for k in objects.indices { x += "          <audioObjectIDRef>AO_\(String(format: "%04x", 0x1002 + k))</audioObjectIDRef>\n" }
        x += "        </audioContent>\n"
        x += "        <audioObject audioObjectID=\"AO_1001\" audioObjectName=\"Bed \(layout.rawValue)\">\n"
        x += "          <audioPackFormatIDRef>\(pack)</audioPackFormatIDRef>\n"
        for uid in uids.prefix(bedTracks.count) { x += "          <audioTrackUIDRef>\(uid)</audioTrackUIDRef>\n" }
        x += "        </audioObject>\n"
        for (k, o) in objects.enumerated() {
            x += "        <audioObject audioObjectID=\"AO_\(String(format: "%04x", 0x1002 + k))\" audioObjectName=\"\(escaped(String(o.name.prefix(200))))\">\n"
            x += "          <audioPackFormatIDRef>AP_0003\(hex[k])</audioPackFormatIDRef>\n"
            x += "          <audioTrackUIDRef>\(uids[bedTracks.count + k])</audioTrackUIDRef>\n"
            x += "        </audioObject>\n"
        }
        for (k, o) in objects.enumerated() {
            let id = "0003\(hex[k])", label = escaped(String(o.name.prefix(200)))
            x += "        <audioPackFormat audioPackFormatID=\"AP_\(id)\" audioPackFormatName=\"\(label)\" typeLabel=\"0003\" typeDefinition=\"Objects\">\n"
            x += "          <audioChannelFormatIDRef>AC_\(id)</audioChannelFormatIDRef>\n"
            x += "        </audioPackFormat>\n"
            x += "        <audioChannelFormat audioChannelFormatID=\"AC_\(id)\" audioChannelFormatName=\"\(label)\" typeLabel=\"0003\" typeDefinition=\"Objects\">\n"
            for (i, b) in o.blocks.enumerated() {
                var times = ""
                if let s = b.start, let d = b.duration { times = " rtime=\"\(time(s, rate: rate))\" duration=\"\(time(d, rate: rate))\"" }
                x += "          <audioBlockFormat audioBlockFormatID=\"AB_\(id)_\(String(format: "%08x", i + 1))\"\(times)>\n"
                x += "            <position coordinate=\"azimuth\">\(String(format: "%.4f", b.azimuth))</position>\n"
                x += "            <position coordinate=\"elevation\">\(String(format: "%.4f", b.elevation))</position>\n"
                x += "            <position coordinate=\"distance\">1.0</position>\n"
                if b.jump { x += "            <jumpPosition>1</jumpPosition>\n" }
                x += "          </audioBlockFormat>\n"
            }
            x += "        </audioChannelFormat>\n"
            x += "        <audioStreamFormat audioStreamFormatID=\"AS_\(id)\" audioStreamFormatName=\"PCM_\(label)\" formatLabel=\"0001\" formatDefinition=\"PCM\">\n"
            x += "          <audioChannelFormatIDRef>AC_\(id)</audioChannelFormatIDRef>\n"
            x += "          <audioTrackFormatIDRef>AT_\(id)_01</audioTrackFormatIDRef>\n"
            x += "        </audioStreamFormat>\n"
            x += "        <audioTrackFormat audioTrackFormatID=\"AT_\(id)_01\" audioTrackFormatName=\"PCM_\(label)\" formatLabel=\"0001\" formatDefinition=\"PCM\">\n"
            x += "          <audioStreamFormatIDRef>AS_\(id)</audioStreamFormatIDRef>\n"
            x += "        </audioTrackFormat>\n"
        }
        for k in 0..<n {
            let (track, packRef) = k < bedTracks.count ? (bedTracks[k], pack) : ("AT_0003\(hex[k - bedTracks.count])_01", "AP_0003\(hex[k - bedTracks.count])")
            x += "        <audioTrackUID UID=\"\(uids[k])\">\n"
            x += "          <audioTrackFormatIDRef>\(track)</audioTrackFormatIDRef>\n"
            x += "          <audioPackFormatIDRef>\(packRef)</audioPackFormatIDRef>\n"
            x += "        </audioTrackUID>\n"
        }
        x += "      </audioFormatExtended>\n    </format>\n  </coreMetadata>\n</ebuCoreMain>\n"
        return [("chna", chna), ("axml", Data(x.utf8))]
    }

    // MARK: The sound of a file with objects

    /// The document the bed is rendered from: every object track's own sound kept out of it, routed to a muted bus,
    /// so its sends to buses (a reverb) are still in the bed while its direct sound is its object's. Where no bus can
    /// be added (the most a document has), those tracks are muted, sends and all.
    public static func bedProject(_ project: Project) -> Project {
        let ids = Set(tracks(project).map(\.id))
        guard !ids.isEmpty else { return project }
        var p = project
        if let sink = try? p.addBus(name: "ADM objects"), let b = p.buses.firstIndex(where: { $0.id == sink.id }) {
            p.buses[b].isMuted = true
            for i in p.tracks.indices where ids.contains(p.tracks[i].id) { p.tracks[i].output = sink.id }
        } else {
            for i in p.tracks.indices where ids.contains(p.tracks[i].id) { p.tracks[i].isMuted = true }
        }
        return p
    }

    /// The document one object track is rendered from: the track alone, after its clips, plugins and fader (with
    /// its VCA group's level), before the panner, in mono, or as its two channels for a stereo track (its objects'
    /// order); the master's level applies, not its limiter, which is the bed's.
    public static func objectProject(_ project: Project, track id: UUID) -> Project? {
        guard let t = project.tracks.first(where: { $0.id == id }) else { return nil }
        var p = project
        let stereo = t.clips.contains { (project.source($0.sourceID)?.info.channels ?? 1) == 2 }
        var only = t
        only.position = nil
        only.pan = 0
        only.sends = []
        only.output = nil
        only.isMuted = false
        p.tracks = [only]
        p.buses = []
        p.channels = stereo ? 2 : 1
        p.master.limiter = nil
        p.master.inserts = []
        let kept = Set([id] + (t.vca.map { [$0] } ?? []))
        p.automation = p.automation.filter { kept.contains($0.strip) && ![.azimuth, .elevation, .pan, .send].contains($0.param) }
        return p
    }

    /// One block of the file: the bed's channels, then each object track's channels in turn (mono one, stereo two),
    /// frame by frame. Each input has the same number of frames.
    public static func interleave(bed: [Float], bedChannels: Int, objects: [[Float]], objectChannels: [Int]) -> [Float] {
        let frames = bed.count / max(1, bedChannels)
        let width = bedChannels + objectChannels.reduce(0, +)
        var out = [Float](repeating: 0, count: frames * width)
        for f in 0..<frames {
            var at = f * width
            for c in 0..<bedChannels { out[at + c] = bed[f * bedChannels + c] }
            at += bedChannels
            for (k, o) in objects.enumerated() {
                let n = objectChannels[k]
                for c in 0..<n where f * n + c < o.count { out[at + c] = o[f * n + c] }
                at += n
            }
        }
        return out
    }

    // MARK: Read back

    /// An object as a file describes it: its name, the file's track (1-based, from chna) and its blocks (times in
    /// frames at the file's rate).
    public struct Read: Equatable, Sendable {
        public var name: String
        public var track: Int?
        public var blocks: [Block]
    }

    /// The objects in an `axml` payload (typeDefinition Objects), each with its track from `chna` when given.
    /// What isn't polar Objects is left out. At most 4 096 objects and 100 000 blocks are read.
    public static func read(axml: Data, chna: Data? = nil, rate: Double) -> [Read] {
        let parser = Reader(rate: rate)
        let xml = XMLParser(data: axml)
        xml.delegate = parser
        xml.shouldResolveExternalEntities = false
        guard xml.parse() else { return [] }
        // chna: track index by its UID; the object names its UIDs.
        var trackOfUID: [String: Int] = [:]
        if let chna, chna.count >= 4 {
            let b = [UInt8](chna)
            let count = min(Int(b[0]) | Int(b[1]) << 8, (b.count - 4) / 40)
            for e in 0..<count {
                let at = 4 + 40 * e
                trackOfUID[String(decoding: b[at + 2..<at + 14], as: UTF8.self)] = Int(b[at]) | Int(b[at + 1]) << 8
            }
        }
        var out: [Read] = []
        for o in parser.objects {
            for pack in o.packs {
                guard let channels = parser.packChannels[pack] else { continue }
                for ch in channels {
                    guard let blocks = parser.channelBlocks[ch] else { continue }
                    out.append(Read(name: o.name, track: o.uids.first.flatMap { trackOfUID[$0] }, blocks: blocks))
                }
            }
        }
        return Array(out.prefix(4_096))
    }

    /// Parses times in either form of § 5.13 into frames at `rate`.
    static func frames(_ s: String, rate: Double) -> Frame? {
        if let sIndex = s.lastIndex(of: "S"), s.contains(":") {
            let parts = s[..<sIndex].split(separator: ":"), denom = Double(s[s.index(after: sIndex)...]) ?? 0
            guard parts.count == 3, denom > 0, let h = Double(parts[0]), let m = Double(parts[1]) else { return nil }
            let secParts = parts[2].split(separator: ".")
            guard let whole = Double(secParts[0]) else { return nil }
            let num = secParts.count > 1 ? Double(secParts[1]) ?? 0 : 0
            return Frame(((h * 3_600 + m * 60 + whole + num / denom) * rate).rounded())
        }
        let parts = s.split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
        return Frame(((h * 3_600 + m * 60 + sec) * rate).rounded())
    }

    final class Reader: NSObject, XMLParserDelegate {
        struct Obj { var name: String; var packs: [String] = []; var uids: [String] = [] }
        let rate: Double
        var objects: [Obj] = []
        var packChannels: [String: [String]] = [:]
        var channelBlocks: [String: [Block]] = [:]
        private var blockCount = 0
        private var currentObject: Obj?
        private var currentPack: String?
        private var currentChannel: String?
        private var block: Block?
        private var coordinate: String?
        private var text = ""
        init(rate: Double) { self.rate = rate }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            text = ""
            switch name {
            case "audioObject": if objects.count < 4_096 { currentObject = Obj(name: a["audioObjectName"] ?? "") }
            case "audioPackFormat": currentPack = (a["typeDefinition"] == "Objects" || a["typeLabel"] == "0003") ? a["audioPackFormatID"] : nil
            case "audioChannelFormat": currentChannel = (a["typeDefinition"] == "Objects" || a["typeLabel"] == "0003") ? a["audioChannelFormatID"] : nil
            case "audioBlockFormat" where currentChannel != nil && blockCount < 100_000:
                block = Block(start: a["rtime"].flatMap { ADMObjects.frames($0, rate: rate) }, duration: a["duration"].flatMap { ADMObjects.frames($0, rate: rate) },
                              azimuth: 0, elevation: 0)
            case "position": coordinate = a["coordinate"]
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if text.count < 4_096 { text += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "audioObject": if let o = currentObject { objects.append(o) }; currentObject = nil
            case "audioPackFormatIDRef": currentObject?.packs.append(value)
            case "audioTrackUIDRef": currentObject?.uids.append(value)
            case "audioChannelFormatIDRef": if let p = currentPack { packChannels[p, default: []].append(value) }
            case "audioPackFormat": currentPack = nil
            case "audioChannelFormat": currentChannel = nil
            case "position":
                if let d = Double(value) {
                    if coordinate == "azimuth" { block?.azimuth = d } else if coordinate == "elevation" { block?.elevation = d }
                }
            case "jumpPosition": block?.jump = value == "1"
            case "audioBlockFormat":
                if let b = block, let ch = currentChannel { channelBlocks[ch, default: []].append(b); blockCount += 1 }
                block = nil
            default: break
            }
        }
    }
}
