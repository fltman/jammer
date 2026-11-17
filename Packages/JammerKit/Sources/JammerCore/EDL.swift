import Foundation

/// The timeline exchange formats Jämmer writes and reads with its own code: CMX 3600 EDL, OpenTimelineIO
/// and DAWproject (docs/LICENSES.md, "File formats implemented from their specifications"). Audio only.
public enum TimelineFormat: String, Sendable, CaseIterable {
    case edl, otio, dawproject
    public var fileExtension: String { rawValue }
    public init?(path: String) {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "edl": self = .edl
        case "otio": self = .otio
        case "dawproject": self = .dawproject
        default: return nil
        }
    }
}

/// A document laid out for a timeline file: each track with its clips, each clip with its file, in seconds.
public struct ExchangeTimeline: Sendable, Equatable {
    public struct Clip: Sendable, Equatable {
        public var name: String
        public var path: String
        public var start: Double, sourceStart: Double, duration: Double
        public var gainDB: Double, fadeIn: Double, fadeOut: Double
        /// The file's own channels, rate and length (seconds), as an exchange format may want them.
        public var channels: Int, sampleRate: Double, fileDuration: Double
    }
    public struct Track: Sendable, Equatable {
        public var name: String
        public var gainDB: Double, pan: Double
        public var muted: Bool
        public var clips: [Clip]
    }
    public struct Marker: Sendable, Equatable {
        public var name: String
        public var start: Double, duration: Double
    }
    public var name: String
    public var sampleRate: Double
    public var channels: Int
    public var tracks: [Track]
    public var markers: [Marker]
    public var timecode: TimecodeSettings?
    public var bpm: Double, meter: (Int, Int)

    public static func == (a: Self, b: Self) -> Bool {
        a.name == b.name && a.sampleRate == b.sampleRate && a.channels == b.channels && a.tracks == b.tracks && a.markers == b.markers
            && a.timecode == b.timecode && a.bpm == b.bpm && a.meter == b.meter
    }

    /// The document as it plays now: each track's clips in time order, their files by path.
    public init(_ project: Project, name: String) {
        self.name = name
        sampleRate = project.sampleRate
        channels = project.channels
        let sr = project.sampleRate
        tracks = project.tracks.map { t in
            Track(name: t.name, gainDB: t.gainDB, pan: t.pan, muted: t.isMuted, clips: t.clips.sorted { $0.start < $1.start }.compactMap { c in
                guard let ref = project.source(c.sourceID) else { return nil }
                return Clip(name: ref.name, path: ref.path, start: Double(c.start) / sr, sourceStart: Double(c.sourceStart) / sr,
                            duration: Double(c.length) / sr, gainDB: c.gainDB, fadeIn: Double(c.fadeIn) / sr, fadeOut: Double(c.fadeOut) / sr,
                            channels: ref.info.channels, sampleRate: ref.info.sampleRate, fileDuration: Double(ref.info.frames) / ref.info.sampleRate)
            })
        }
        markers = project.markers.map { Marker(name: $0.name, start: Double($0.position) / sr, duration: Double($0.length) / sr) }
        timecode = project.timecode
        bpm = project.tempo.changes.first?.bpm ?? 120
        meter = (project.tempo.changes.first?.meter.beats ?? 4, project.tempo.changes.first?.meter.unit ?? 4)
    }
}

/// CMX 3600 EDL, audio only. There is no owner-published specification (docs/LICENSES.md): this writes what
/// Autodesk's, Avid's and Premiere's documentation show and what the OTIO CMX reader reads, and reads the same.
public enum EDL {
    /// The most events a CMX 3600 list holds.
    public static let maxEvents = 999
    /// Audio channels a CMX 3600 list holds (Avid's EDL Manager: "CMX_3600 4").
    public static let maxTracks = 4

    public struct Written: Sendable, Equatable {
        public var text: String
        public var warnings: [String]
    }

    /// The list: each clip of tracks 1–4 an event (A, A2, A3, A4), reel AX, its name and file in comment lines,
    /// times at the document's timecode rate (25 and 00:00:00:00 when it has none). What the format can't hold
    /// is said in `warnings`: gain and fades, tracks past the fourth, times between two frames (rounded).
    public static func write(_ t: ExchangeTimeline) throws -> Written {
        let settings = t.timecode ?? TimecodeSettings(rate: .fps25)
        let r = settings.rate.perSecond, fps = Double(r.num) / Double(r.den)
        var warnings: [String] = []
        if t.timecode == nil { warnings.append("The document has no timecode, so the list is at 25 frames a second from 00:00:00:00.") }
        struct Event { let track: Int; let clip: ExchangeTimeline.Clip }
        var events: [Event] = []
        for (i, track) in t.tracks.enumerated() {
            guard i < maxTracks else {
                if !track.clips.isEmpty { warnings.append("\(track.name) is track \(i + 1); a CMX 3600 list holds \(maxTracks) audio tracks, so it was left out.") }
                continue
            }
            events += track.clips.map { Event(track: i, clip: $0) }
        }
        events.sort { ($0.clip.start, $0.track) < ($1.clip.start, $1.track) }
        guard events.count <= maxEvents else {
            throw ExportError.unsupported("The document has \(events.count) clips on its first four tracks; a CMX 3600 list holds \(maxEvents).")
        }
        var rounded = 0, levels = 0
        func tc(_ seconds: Double, from start: Int) -> String {
            let exact = seconds * fps
            if abs(exact - exact.rounded()) > 1e-6 { rounded += 1 }
            return Timecode(pictureFrames: start + Int(exact.rounded()), rate: settings.rate).text
        }
        var lines = ["TITLE: \(clean(t.name))", "FCM: \(settings.rate.dropsFrames ? "DROP FRAME" : "NON-DROP FRAME")", ""]
        for (n, e) in events.enumerated() {
            let c = e.clip
            if c.gainDB != 0 || c.fadeIn > 0 || c.fadeOut > 0 { levels += 1 }
            let channel = e.track == 0 ? "A" : "A\(e.track + 1)"
            let srcIn = tc(c.sourceStart, from: 0), srcOut = tc(c.sourceStart + c.duration, from: 0)
            let recIn = tc(c.start, from: settings.startFrames), recOut = tc(c.start + c.duration, from: settings.startFrames)
            let pad = channel.padding(toLength: max(5, channel.count), withPad: " ", startingAt: 0)
            lines.append(String(format: "%03d", n + 1) + "  AX       \(pad) C        \(srcIn) \(srcOut) \(recIn) \(recOut)")
            lines.append("* FROM CLIP NAME: \(clean(c.name))")
            lines.append("* SOURCE FILE: \(c.path)")
            lines.append("")
        }
        if rounded > 0 { warnings.append("\(rounded) times fell between two frames and were rounded to the nearest.") }
        if levels > 0 { warnings.append("\(levels) clips have a gain or fades, which a CMX 3600 list can't hold.") }
        let mixed = t.tracks.prefix(maxTracks).filter { $0.gainDB != 0 || $0.pan != 0 || $0.muted }.count
        if mixed > 0 { warnings.append("\(mixed) tracks have a level, pan or mute, which a CMX 3600 list can't hold.") }
        if !t.markers.isEmpty { warnings.append("Markers aren't written: a CMX 3600 list has none.") }
        return Written(text: lines.joined(separator: "\r\n"), warnings: warnings)
    }

    /// A name on one line (an EDL is read line by line).
    static func clean(_ s: String) -> String { s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ") }

    /// Reads a list as a timeline to build a document from. `rate`: the frame rate the times are at (an EDL
    /// doesn't say; FCM says only drop-frame or not). Default 25, or 29.97 drop-frame when FCM says DROP FRAME.
    /// Each audio event becomes a clip on its track (A and the first of AA/B: 1, A2: 2, A3: 3, A4: 4); its file
    /// is the SOURCE FILE, FROM FILE or FROM CLIP comment's path, else a file named as the FROM CLIP NAME or the
    /// reel beside the list. Black and video-only events are left out; a dissolve is read as a cut.
    public static func read(_ text: String, base: URL, name: String, rate given: Timecode.Rate? = nil) throws(FCPXMLImport.ImportError) -> FCPXMLImport.Timeline {
        let rows = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        guard rows.count < 200_000 else { throw .unreadable("it is far longer than an edit decision list.") }
        var title = name, drop = false
        for row in rows.prefix(20) {
            if row.hasPrefix("TITLE:") { title = row.dropFirst(6).trimmingCharacters(in: .whitespaces) }
            if row.hasPrefix("FCM:") { drop = row.uppercased().contains("DROP FRAME") && !row.uppercased().contains("NON-DROP") }
        }
        let rate = given ?? (drop ? .fps2997drop : .fps25)
        let r = rate.perSecond, fps = Double(r.num) / Double(r.den)
        struct Event { var track: Int; var reel: String; var srcIn: Int; var srcOut: Int; var recIn: Int; var recOut: Int; var name: String?; var path: String?; var dissolve: Bool }
        var events: [Event] = [], warnings: [FCPXMLImport.Warning] = []
        var video = 0, black = 0, dissolves = 0, past = 0
        let tcPattern = #"(\d{2}[:;]\d{2}[:;]\d{2}[:;.]\d{2})"#
        let eventLine = try! NSRegularExpression(pattern: #"^\s*(\d{1,6})\s+(\S+)\s+(\S+)\s+(C|D|W\d*|K\s*\w?)\s+(?:\d{1,3}\s+)?"# + tcPattern + #"\s+"# + tcPattern + #"\s+"# + tcPattern + #"\s+"# + tcPattern)
        func frames(_ s: String) -> Int? { Timecode(s, rate: rate)?.pictureFrames }
        for row in rows {
            let ns = row as NSString
            if let m = eventLine.firstMatch(in: row, range: NSRange(location: 0, length: ns.length)) {
                let g = { (i: Int) in ns.substring(with: m.range(at: i)) }
                let reel = g(2), channel = g(3).uppercased(), edit = g(4).uppercased()
                guard let si = frames(g(5)), let so = frames(g(6)), let ri = frames(g(7)), let ro = frames(g(8)) else {
                    warnings.append(.init(code: "bad_timecode", message: "Event \(g(1)) has a time that isn't a timecode at \(rate.rawValue); it was left out.", clip: nil))
                    continue
                }
                if reel == "BL" || reel == "BLACK" { black += 1; continue }
                let track: Int?
                switch channel {
                case "A", "AA", "B", "AA/V", "A/V": track = 0
                case "A2", "A2/V": track = 1
                case "V": track = nil
                default:
                    if channel.hasPrefix("A"), let k = Int(channel.dropFirst()), (1...99).contains(k) { track = k - 1 } else { track = nil }
                }
                guard let track else { video += 1; continue }
                if edit.hasPrefix("D") { dissolves += 1 }
                // A dissolve's second line names the same event: the incoming clip from its record in.
                events.append(Event(track: track, reel: reel, srcIn: si, srcOut: so, recIn: ri, recOut: ro, name: nil, path: nil, dissolve: edit.hasPrefix("D")))
                continue
            }
            guard var last = events.last, row.hasPrefix("*") else { continue }
            let body = row.dropFirst().trimmingCharacters(in: .whitespaces)
            for key in ["SOURCE FILE:", "FROM FILE:", "FROM CLIP:"] where body.uppercased().hasPrefix(key) {
                let v = body.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
                if last.path == nil, !v.isEmpty { last.path = v }
            }
            if body.uppercased().hasPrefix("FROM CLIP NAME:") { last.name = body.dropFirst("FROM CLIP NAME:".count).trimmingCharacters(in: .whitespaces) }
            events[events.count - 1] = last
        }
        guard !events.isEmpty else { throw .noAudio("The list has no audio events\(video > 0 ? " (\(video) video events were left out)" : "").") }
        let zero = events.map(\.recIn).min()!
        var byTrack: [Int: [FCPXMLImport.ClipItem]] = [:]
        for e in events {
            guard e.track < 64 else { past += 1; continue }
            let file: URL = {
                if let p = e.path { return p.hasPrefix("/") ? URL(fileURLWithPath: p) : base.appending(path: p) }
                return base.appending(path: e.name ?? e.reel)
            }()
            let seconds = { (f: Int) in FCPXMLImport.Time(seconds: Double(f) / fps) }
            byTrack[e.track, default: []].append(.init(name: e.name ?? file.lastPathComponent, media: file.standardizedFileURL, mediaName: file.lastPathComponent,
                                                       start: seconds(e.recIn - zero), sourceStart: seconds(e.srcIn), duration: seconds(max(0, e.recOut - e.recIn)),
                                                       gainDB: 0, fadeIn: .zero, fadeOut: .zero, enabled: true, origin: nil))
        }
        if video > 0 { warnings.append(.init(code: "video", message: "\(video) video events were left out: Jämmer reads the audio.", clip: nil)) }
        if black > 0 { warnings.append(.init(code: "black", message: "\(black) black events were left out (they are silence).", clip: nil)) }
        if dissolves > 0 { warnings.append(.init(code: "dissolve", message: "\(dissolves) dissolves were read as cuts.", clip: nil)) }
        if past > 0 { warnings.append(.init(code: "tracks", message: "\(past) events on audio channels past 64 were left out.", clip: nil)) }
        let tracks = byTrack.keys.sorted().map { k in
            FCPXMLImport.TrackItem(lane: k, name: "A\(k + 1)", gainDB: 0, muted: false, origin: nil, clips: byTrack[k]!.sorted { $0.start.seconds < $1.start.seconds })
        }
        var timeline = FCPXMLImport.Timeline(name: title.isEmpty ? name : title, sampleRate: 48_000, channels: 2, tracks: tracks, shots: [],
                                             flimmerExportVersion: nil, flimmerProjectId: nil, flimmerStoryId: nil, warnings: warnings)
        timeline.timecode = TimecodeSettings(rate: rate, startFrames: zero)
        return timeline
    }
}
