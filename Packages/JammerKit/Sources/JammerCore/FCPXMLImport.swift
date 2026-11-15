import Foundation

/// Reads the sound of a Final Cut Pro XML timeline (FCPXML 1.x): connected audio clips become
/// tracks, one per lane, with position, trim, level, linear fades and mute. Flimmer's exports
/// carry exact times and separate clip and track levels in metadata (`com.brattoo.flimmer.*`),
/// which win when present; other programs' files are read from the FCPXML fields alone.
/// Pictures aren't shown: each spine element becomes a "shot" marker so the film's layout is
/// visible. Times are rational all the way and become frames only at the end.
public enum FCPXMLImport {
    /// An exact time in seconds.
    public struct Time: Sendable, Equatable {
        public var n: Int64, d: Int64
        public static let zero = Time(n: 0, d: 1)
        /// The largest time kept exact; beyond it (only a hostile file gets there) values saturate.
        static let limit = 1e12

        public init(n: Int64, d: Int64) {
            // Int64.min has no positive counterpart; nothing real is that far out.
            let n = max(n, -Int64.max), d = max(d, -Int64.max)
            guard d != 0 else { self.n = 0; self.d = 1; return }
            let g = Time.gcd(abs(n), abs(d))
            self.n = (d < 0 ? -n : n) / max(1, g)
            self.d = abs(d) / max(1, g)
        }
        static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
            var a = a, b = b
            while b != 0 { (a, b) = (b, a % b) }
            return a
        }
        /// "84/24s", "1001/24000s", "5s", "2.5s"; nil when it isn't a time.
        public init?(_ text: String?) {
            guard var t = text?.trimmingCharacters(in: .whitespaces), t.hasSuffix("s") else { return nil }
            t.removeLast()
            let parts = t.split(separator: "/")
            if parts.count == 2, let a = Int64(parts[0]), let b = Int64(parts[1]), b != 0 { self.init(n: a, d: b) }
            else if parts.count == 1, let a = Int64(parts[0]) { self.init(n: a, d: 1) }
            else if parts.count == 1, let v = Double(parts[0]), v.isFinite { self.init(seconds: v) }
            else { return nil }
        }
        /// A decimal number of seconds (metadata), kept exact to the microsecond.
        public init(seconds: Double) {
            guard !seconds.isNaN else { self.init(n: 0, d: 1); return }
            let v = min(Time.limit, max(-Time.limit, seconds))
            self.init(n: Int64((v * 1_000_000).rounded()), d: 1_000_000)
        }
        public var seconds: Double { Double(n) / Double(d) }
        /// Exact while the numbers fit; a sum that would overflow (a file with absurd times) is
        /// worked out in floating point and saturates rather than trapping.
        static func combine(_ a: Time, _ b: Time, sign: Int64) -> Time {
            let (x, o1) = a.n.multipliedReportingOverflow(by: b.d)
            let (y, o2) = b.n.multipliedReportingOverflow(by: a.d)
            let (y2, o3) = y.multipliedReportingOverflow(by: sign)
            let (num, o4) = x.addingReportingOverflow(y2)
            let (den, o5) = a.d.multipliedReportingOverflow(by: b.d)
            if o1 || o2 || o3 || o4 || o5 { return Time(seconds: a.seconds + Double(sign) * b.seconds) }
            return Time(n: num, d: den)
        }
        public static func + (a: Time, b: Time) -> Time { combine(a, b, sign: 1) }
        public static func - (a: Time, b: Time) -> Time { combine(a, b, sign: -1) }
        public func frames(at rate: Double) -> Frame {
            let v = (Double(n) * rate / Double(d)).rounded()
            guard v.isFinite else { return 0 }
            return v >= 9.2e18 ? Frame.max : (v <= -9.2e18 ? Frame.min : Frame(v))
        }
    }

    public struct Warning: Sendable, Equatable {
        public var code: String
        public var message: String
        /// The clip it is about (its name), when there is one.
        public var clip: String?
    }

    public struct ClipItem: Sendable, Equatable {
        public var name: String
        public var media: URL
        public var mediaName: String
        public var start: Time          // on the timeline
        public var sourceStart: Time
        public var duration: Time
        public var gainDB: Double
        public var fadeIn: Time
        public var fadeOut: Time
        public var enabled: Bool
        public var origin: Origin?
    }

    public struct TrackItem: Sendable, Equatable {
        public var lane: Int
        public var name: String
        public var gainDB: Double
        public var muted: Bool
        public var origin: Origin?
        public var clips: [ClipItem]
    }

    public struct Shot: Sendable, Equatable {
        public var name: String
        public var start: Time
        public var duration: Time
    }

    /// What the file says, before any audio is opened.
    public struct Timeline: Sendable, Equatable {
        public var name: String
        public var sampleRate: Double
        public var channels: Int
        public var tracks: [TrackItem]
        public var shots: [Shot]
        /// Flimmer's `exportVersion` when the file is one of its exports.
        public var flimmerExportVersion: String?
        /// From exportVersion 2: the project and story it was exported from (needed for the way back).
        public var flimmerProjectId: String?
        public var flimmerStoryId: String?
        public var warnings: [Warning]
        public var media: [URL] { Array(Set(tracks.flatMap { $0.clips.map(\.media) })).sorted { $0.path < $1.path } }
    }

    public enum ImportError: Error, LocalizedError, Equatable {
        case unreadable(String)
        case noSequence
        /// With the first reason a clip was left out, when there was one.
        case noAudio(String?)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let why): "The file isn't FCPXML that can be read: \(why)"
            case .noSequence: "The file has no sequence (a project timeline) to import."
            case .noAudio(let why): "The timeline has no audio clips that could be opened." + (why.map { " \($0)" } ?? "")
            }
        }
        public var reason: String {
            switch self {
            case .unreadable: "unreadable"
            case .noSequence: "no_sequence"
            case .noAudio: "no_audio"
            }
        }
    }

    // MARK: XML

    final class Node {
        let name: String
        let attributes: [String: String]
        var children: [Node] = []
        init(_ name: String, _ attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }
        subscript(_ key: String) -> String? { attributes[key] }
        func first(_ name: String) -> Node? { children.first { $0.name == name } }
        func all(_ name: String) -> [Node] { children.filter { $0.name == name } }
        /// Depth first, self included.
        func find(_ name: String) -> Node? {
            if self.name == name { return self }
            for c in children { if let n = c.find(name) { return n } }
            return nil
        }
        /// `<metadata><md key value/></metadata>` directly under this element.
        var metadata: [String: String] {
            var d: [String: String] = [:]
            for md in first("metadata")?.all("md") ?? [] { if let k = md["key"], let v = md["value"] { d[k] = v } }
            return d
        }
    }

    /// No timeline file is this large (Flimmer's sample is 15 kB); more is refused unparsed.
    public static let maxBytes = 64 << 20
    static let maxDepth = 256
    static let maxElements = 2_000_000

    final class Builder: NSObject, XMLParserDelegate {
        var root: Node?
        var stack: [Node] = []
        var count = 0
        /// Why parsing was stopped, when it was.
        var refused: String?

        func stop(_ parser: XMLParser, _ why: String) {
            refused = refused ?? why
            parser.abortParsing()
        }
        // A timeline has no business declaring entities: an internal one can expand to gigabytes,
        // an external one names a file or an address to read. Either ends the import.
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { stop(parser, "it declares entities, which a timeline doesn't need and Jämmer doesn't follow.") }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { stop(parser, "it points at other files or addresses (external entities), which Jämmer doesn't follow.") }
        func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?, systemID: String?, notationName: String?) { stop(parser, "it points at other files or addresses (external entities), which Jämmer doesn't follow.") }
        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { stop(parser, "it points at other files or addresses (external entities), which Jämmer doesn't follow."); return nil }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            count += 1
            guard stack.count < FCPXMLImport.maxDepth else { return stop(parser, "its elements are nested deeper than any timeline's.") }
            guard count <= FCPXMLImport.maxElements else { return stop(parser, "it has more elements than any timeline.") }
            let n = Node(name, attributes)
            if let top = stack.last { top.children.append(n) } else { root = n }
            stack.append(n)
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { if !stack.isEmpty { stack.removeLast() } }
    }

    // MARK: Reading

    static let flimmer = "com.brattoo.flimmer."

    /// Reads the first sequence of the file at `url`. Media paths are resolved against the file's folder.
    public static func read(_ url: URL) throws(ImportError) -> Timeline {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maxBytes else { throw .unreadable("it is \(size >> 20) MB, far larger than a timeline file.") }
        guard let data = try? Data(contentsOf: url) else { throw .unreadable("it can't be opened.") }
        return try read(data, base: url.deletingLastPathComponent(), name: url.deletingPathExtension().lastPathComponent)
    }

    public static func read(_ data: Data, base: URL, name fallbackName: String) throws(ImportError) -> Timeline {
        guard data.count <= maxBytes else { throw .unreadable("it is \(data.count >> 20) MB, far larger than a timeline file.") }
        // A timeline has no business declaring entities: an internal one can expand to gigabytes, an
        // external one names a file or an address to read. Looked for before the parser sees the file
        // (declarations sit in the prolog, ahead of the first element), and again by the parser's own hooks.
        let prolog = data.prefix(1 << 20)
        if prolog.range(of: Data("<!ENTITY".utf8)) != nil {
            throw .unreadable("it declares entities, which a timeline doesn't need and Jämmer doesn't follow.")
        }
        let parser = XMLParser(data: data)
        // Never fetch anything a file names (DTDs, entities).
        parser.shouldResolveExternalEntities = false
        let builder = Builder()
        parser.delegate = builder
        let parsed = parser.parse()
        if let refused = builder.refused { throw .unreadable(refused) }
        guard parsed, let root = builder.root, root.name == "fcpxml" else {
            // The parser's own text is an error number; say what it means.
            throw .unreadable(parser.parserError == nil ? "it has no fcpxml element." : "it isn't well-formed XML (line \(parser.lineNumber)).")
        }
        guard let sequence = root.find("sequence"), let spine = sequence.first("spine") else { throw .noSequence }
        let project = root.find("project")

        struct Asset { var name: String; var url: URL?; var hasAudio: Bool; var hasVideo: Bool }
        var assets: [String: Asset] = [:]
        for a in root.first("resources")?.all("asset") ?? [] {
            guard let id = a["id"] else { continue }
            // 1.9 and later: <media-rep src>; earlier: src on the asset.
            let src = a.first("media-rep")?["src"] ?? a["src"]
            var u: URL?
            if let src, !src.isEmpty {
                if src.hasPrefix("file:") { u = URL(string: src) }
                else if src.hasPrefix("/") { u = URL(fileURLWithPath: src) }
                else if !src.contains("://") { u = base.appending(path: src.removingPercentEncoding ?? src) }
            }
            assets[id] = Asset(name: a["name"] ?? u?.lastPathComponent ?? id, url: u?.standardizedFileURL,
                               hasAudio: a["hasAudio"] == "1", hasVideo: a["hasVideo"] == "1")
        }

        let rates: [String: Double] = ["32k": 32_000, "44.1k": 44_100, "48k": 48_000, "88.2k": 88_200, "96k": 96_000, "176.4k": 176_400, "192k": 192_000]
        var warnings: [Warning] = []
        let sampleRate = rates[sequence["audioRate"] ?? "48k"] ?? 48_000
        let exportVersion = sequence.metadata[flimmer + "exportVersion"]
        let isFlimmer = exportVersion != nil

        func db(_ linear: Double) -> Double {
            guard linear.isFinite, linear > 0.000_016 else { return -96 }
            return min(24, (20 * log10(linear) * 100).rounded() / 100)
        }
        func amount(_ node: Node) -> Double {
            guard let a = node.first("adjust-volume")?["amount"],
                  let v = Double(a.replacingOccurrences(of: "dB", with: "").trimmingCharacters(in: .whitespaces)), v.isFinite else { return 0 }
            return min(24, max(-96, v))
        }

        struct Found { var lane: Int; var role: String?; var item: ClipItem; var md: [String: String] }
        var found: [Found] = []
        var shots: [Shot] = []

        func audioClip(_ c: Node, asset: Asset, url: URL, timelineStart: Time, lane: Int) {
            let md = c.metadata
            func time(_ key: String) -> Time? { md[flimmer + key].flatMap(Double.init).map(Time.init(seconds:)) }
            let fadeNode = c.first("adjust-volume")?.all("param").first { $0["name"] == "amount" }
            var fadeIn = Time(fadeNode?.first("fadeIn")?["duration"]) ?? .zero, fadeOut = Time(fadeNode?.first("fadeOut")?["duration"]) ?? .zero
            var start = timelineStart, sourceStart = Time(c["start"]) ?? .zero, duration = Time(c["duration"]) ?? .zero
            var gain = amount(c)
            var origin: Origin?
            if isFlimmer, md[flimmer + "clipId"] != nil {
                // Exact seconds instead of whole picture frames; the clip's own level apart from its track's.
                if let t = time("timelineOffset") { start = t }
                if let a = time("startTime") { sourceStart = a }
                if let a = time("startTime"), let b = time("endTime"), b.seconds > a.seconds { duration = b - a }
                if let v = md[flimmer + "clipVolume"].flatMap(Double.init) { gain = db(v) }
                // The stored fades are exact; when together they are longer than the clip, what is
                // rendered is the adapted lengths the FCPXML fields carry.
                if let i = time("fadeIn"), let o = time("fadeOut"), i.seconds + o.seconds <= duration.seconds + 1e-9 { fadeIn = i; fadeOut = o }
                origin = Origin(app: "flimmer", clipId: md[flimmer + "clipId"], trackId: md[flimmer + "trackId"],
                                linkedShotId: md[flimmer + "linkedShotId"], exportVersion: exportVersion)
                if origin?.linkedShotId != nil { origin?.clipRelativeOffset = md[flimmer + "clipRelativeOffset"].flatMap(Double.init) }
            }
            found.append(Found(lane: lane, role: c["audioRole"] ?? c["role"],
                               item: ClipItem(name: c["name"] ?? asset.name, media: url, mediaName: asset.name, start: start, sourceStart: sourceStart,
                                              duration: duration, gainDB: gain, fadeIn: fadeIn, fadeOut: fadeOut, enabled: c["enabled"] != "0", origin: origin),
                               md: md))
        }

        /// Connected clips of `parent` (and of what is nested in it), placed from the parent's local time.
        func connected(_ parent: Node, parentOffset: Time, parentStart: Time) {
            for c in parent.children where c.name == "asset-clip" && c["lane"] != nil {
                guard let lane = Int(c["lane"] ?? ""), let ref = c["ref"], let asset = assets[ref] else { continue }
                let at = parentOffset + ((Time(c["offset"]) ?? .zero) - parentStart)
                if asset.hasAudio || !asset.hasVideo, let url = asset.url {
                    audioClip(c, asset: asset, url: url, timelineStart: at, lane: lane)
                } else if asset.url == nil {
                    warnings.append(Warning(code: "missing_media", message: "\(asset.name) has no file path in the FCPXML.", clip: c["name"]))
                }
                connected(c, parentOffset: at, parentStart: Time(c["start"]) ?? .zero)
            }
        }

        for e in spine.children {
            guard let duration = Time(e["duration"]) else { continue }
            let offset = Time(e["offset"]) ?? .zero, start = Time(e["start"]) ?? .zero
            let md = e.metadata
            // A shot: a picture, or a gap Flimmer wrote for a shot without one. (A plain gap is only spacing.)
            if e.name != "gap" || md[flimmer + "shotId"] != nil {
                shots.append(Shot(name: e["name"] ?? "", start: offset, duration: duration))
            }
            // The clip's own sound, in the primary storyline.
            if e.name == "asset-clip", let ref = e["ref"], let asset = assets[ref] {
                let own = md[flimmer + "videoAudio"].map { $0 == "1" } ?? asset.hasAudio
                if own, let url = asset.url {
                    var item = ClipItem(name: e["name"] ?? asset.name, media: url, mediaName: asset.name, start: offset, sourceStart: start, duration: duration,
                                        gainDB: amount(e), fadeIn: .zero, fadeOut: .zero, enabled: e["enabled"] != "0", origin: nil)
                    if isFlimmer {
                        item.gainDB = db(md[flimmer + "videoAudioVolume"].flatMap(Double.init) ?? 1)
                        item.origin = Origin(app: "flimmer", clipId: md[flimmer + "shotClipId"], linkedShotId: md[flimmer + "shotId"], exportVersion: exportVersion)
                    }
                    found.append(Found(lane: 0, role: asset.hasVideo ? nil : (e["audioRole"] ?? e["role"]), item: item, md: [:]))
                }
            }
            connected(e, parentOffset: offset, parentStart: start)
        }

        // One track per lane: −1 first, then −2 …, lanes above the spine after those, the spine's own sound last.
        func order(_ lane: Int) -> Int { lane < 0 ? -lane : (lane > 0 ? 1_000 + lane : 100_000) }
        var tracks: [TrackItem] = []
        for lane in Set(found.map(\.lane)).sorted(by: { order($0) < order($1) }) {
            let clips = found.filter { $0.lane == lane }
            let md = clips.first { $0.md[flimmer + "trackId"] != nil }?.md ?? [:]
            var track = TrackItem(lane: lane, name: md[flimmer + "trackName"] ?? clips.compactMap(\.role).first ?? (lane == 0 ? "Video" : "Lane \(lane)"),
                                  gainDB: 0, muted: false, origin: nil, clips: [])
            if lane == 0, clips.contains(where: { $0.role == nil }) { track.name = "Video" }
            if let id = md[flimmer + "trackId"] {
                track.origin = Origin(app: "flimmer", trackId: id, exportVersion: exportVersion)
                let volumes = Set(clips.compactMap { $0.md[flimmer + "trackVolume"].flatMap(Double.init) })
                track.gainDB = db(volumes.first ?? 1)
                if volumes.count > 1 {
                    warnings.append(Warning(code: "track_volume", message: "The clips on \(track.name) give different track volumes; the first is used.", clip: nil))
                }
                track.muted = md[flimmer + "trackMuted"] == "1"
                track.clips = clips.map(\.item)
            } else if clips.allSatisfy({ !$0.item.enabled }) {
                // Without metadata, mute is per clip: every clip off is a muted track.
                track.muted = true
                track.clips = clips.map(\.item)
            } else {
                for c in clips {
                    if c.item.enabled { track.clips.append(c.item) }
                    else { warnings.append(Warning(code: "disabled_clip", message: "\(c.item.name) is switched off in the file and was left out (Jämmer mutes tracks, not clips).", clip: c.item.name)) }
                }
            }
            track.clips.sort { $0.start.seconds < $1.start.seconds }
            tracks.append(track)
        }
        // Flimmer's own order, when it says.
        if isFlimmer {
            func position(_ t: TrackItem) -> Int {
                found.first { $0.lane == t.lane }?.md[flimmer + "trackPosition"].flatMap(Int.init) ?? order(t.lane)
            }
            tracks.sort { position($0) < position($1) }
        }
        let channels = sequence["audioLayout"] == "mono" ? 1 : 2
        if let layout = sequence["audioLayout"], layout != "mono", layout != "stereo" {
            warnings.append(Warning(code: "layout", message: "The timeline is \(layout); it was imported as stereo.", clip: nil))
        }
        return Timeline(name: project?["name"] ?? fallbackName, sampleRate: sampleRate, channels: channels, tracks: tracks, shots: shots,
                        flimmerExportVersion: exportVersion, flimmerProjectId: sequence.metadata[flimmer + "projectId"],
                        flimmerStoryId: sequence.metadata[flimmer + "storyId"], warnings: warnings)
    }

    // MARK: Building the project

    public struct Result: Sendable {
        public var project: Project
        public var name: String
        public var warnings: [Warning]
        public var shots: [Shot]
        public var flimmerExportVersion: String?
        public var clips: Int { project.tracks.reduce(0) { $0 + $1.clips.count } }
    }

    /// Opens the media and lays the clips out. Files at another sample rate than the timeline
    /// are decoded into copies at the timeline's rate in `mediaFolder` (a warning says which).
    public static func build(_ timeline: Timeline, mediaFolder: URL) throws(ImportError) -> Result {
        var warnings = timeline.warnings
        var project = Project(sampleRate: timeline.sampleRate, channels: timeline.channels)
        var sources: [URL: SourceRef] = [:]
        for url in timeline.media {
            guard FileManager.default.fileExists(atPath: url.path) else {
                warnings.append(Warning(code: "missing_media", message: "\(url.lastPathComponent) wasn't found at \(url.path); its clips were left out.", clip: nil))
                continue
            }
            do {
                let r = try AudioImporter.importFile(url, sampleRate: timeline.sampleRate, mediaFolder: mediaFolder)
                var s = r.source
                if let name = timeline.tracks.flatMap(\.clips).first(where: { $0.media == url })?.mediaName {
                    s.name = (name as NSString).deletingPathExtension
                }
                sources[url] = s
                if r.decoded, let original = try? AudioFileReader.info(at: url), original.sampleRate != timeline.sampleRate {
                    warnings.append(Warning(code: "resampled", message: String(format: "%@ is %.0f Hz and the timeline %.0f Hz; it plays from a converted copy.",
                                                                               s.name, original.sampleRate, timeline.sampleRate), clip: nil))
                }
            } catch {
                warnings.append(Warning(code: "unreadable_media", message: "\(url.lastPathComponent) couldn't be read as audio; its clips were left out.", clip: nil))
            }
        }
        let rate = timeline.sampleRate
        for t in timeline.tracks {
            var lanes: [[Clip]] = [[]]
            for c in t.clips {
                guard let source = sources[c.media] else { continue }
                if project.source(source.id) == nil { project.sources.append(source) }
                let sourceStart = max(0, c.sourceStart.frames(at: rate))
                let start = max(0, c.start.frames(at: rate))
                // A day is longer than any film; a clip placed beyond it is a broken or hostile file.
                guard start <= Frame(86_400 * rate) else {
                    warnings.append(Warning(code: "out_of_range", message: "\(c.name) is placed \(Int(Double(start) / rate / 3_600)) hours into the timeline and was left out.", clip: c.name))
                    continue
                }
                // Never past the end of the file (a clip can be a picture frame short of its stored times).
                let length = sourceStart >= source.info.frames ? 0 : min(c.duration.frames(at: rate), source.info.frames - sourceStart)
                guard length > 0 else {
                    warnings.append(Warning(code: "empty_clip", message: "\(c.name) starts at or after the end of its file and was left out.", clip: c.name))
                    continue
                }
                var clip = Clip(sourceID: source.id, sourceStart: sourceStart, start: start, length: length, gainDB: c.gainDB.isFinite ? c.gainDB : 0,
                                fadeIn: min(length, max(0, c.fadeIn.frames(at: rate))), fadeOut: min(length, max(0, c.fadeOut.frames(at: rate))), fadeShape: .linear, origin: c.origin)
                if clip.origin != nil {
                    // How it came in, so the way back can tell what has changed since.
                    var snap = Origin.Snapshot()
                    snap.start = clip.start; snap.sourceStart = clip.sourceStart; snap.length = clip.length
                    snap.gainDB = clip.gainDB; snap.fadeIn = clip.fadeIn; snap.fadeOut = clip.fadeOut; snap.sourceID = clip.sourceID
                    clip.origin?.snapshot = snap
                    if t.lane == 0 { clip.origin?.videoAudio = true }
                }
                // Clips on one track can't overlap here: one that does goes on a track of its own beside it.
                let row = lanes.firstIndex { ($0.last?.end ?? 0) <= clip.start } ?? { lanes.append([]); return lanes.count - 1 }()
                if row > 0, lanes[row].isEmpty {
                    warnings.append(Warning(code: "overlap", message: "Clips on \(t.name) overlap; \(c.name) is on an extra track.", clip: c.name))
                }
                lanes[row].append(clip)
            }
            for (i, clips) in lanes.enumerated() where !clips.isEmpty {
                var track = Track(name: i == 0 ? t.name : "\(t.name) (\(i + 1))", clips: clips, gainDB: t.gainDB, isMuted: t.muted)
                track.origin = t.origin
                if track.origin != nil {
                    var snap = Origin.Snapshot()
                    snap.gainDB = t.gainDB; snap.muted = t.muted
                    track.origin?.snapshot = snap
                }
                project.tracks.append(track)
            }
        }
        guard project.tracks.contains(where: { !$0.clips.isEmpty }) else { throw .noAudio(warnings.first?.message) }
        project.markers = timeline.shots.filter { !$0.name.isEmpty }.compactMap {
            let at = $0.start.frames(at: rate), length = $0.duration.frames(at: rate)
            guard at >= 0, at <= Frame(86_400 * rate) else { return nil }
            return Marker(position: at, length: min(max(0, length), Frame(86_400 * rate)), name: String($0.name.prefix(200)), kind: .shot)
        }
        if let version = timeline.flimmerExportVersion {
            let ids = project.tracks.flatMap { $0.clips.compactMap { $0.origin?.videoAudio == true ? nil : $0.origin?.clipId } }
            project.imported = .init(app: "flimmer", exportVersion: version, clipIds: ids, length: project.length,
                                     projectId: timeline.flimmerProjectId, storyId: timeline.flimmerStoryId)
        }
        return Result(project: project, name: timeline.name, warnings: warnings, shots: timeline.shots, flimmerExportVersion: timeline.flimmerExportVersion)
    }
}
