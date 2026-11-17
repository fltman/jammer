import Foundation

/// OpenTimelineIO's JSON file format (.otio), audio only, with Jämmer's own code (docs/LICENSES.md). Written
/// with the schema versions OTIO 0.15 to 0.18 write (Timeline.1, Stack.1, Track.1, Clip.2, Gap.1,
/// ExternalReference.1, MissingReference.1, RationalTime.1, TimeRange.1, Marker.2). Clip.1 is read too.
public enum OTIO {
    static func rt(_ seconds: Double, _ rate: Double) -> [String: Any] {
        ["OTIO_SCHEMA": "RationalTime.1", "rate": rate, "value": (seconds * rate).rounded()]
    }
    static func range(_ start: Double, _ duration: Double, _ rate: Double) -> [String: Any] {
        ["OTIO_SCHEMA": "TimeRange.1", "start_time": rt(start, rate), "duration": rt(duration, rate)]
    }

    public struct Written: Sendable, Equatable {
        public var data: Data
        public var warnings: [String]
    }

    /// Each track an audio Track of Clips and Gaps (a track is a sequence: the time between two clips is a Gap),
    /// each clip's file an ExternalReference; times at the document's sample rate, so they are exact. Markers
    /// on the Stack. A clip's gain and fades, and a track's level, pan and mute, go in the metadata under
    /// "jammer" (OTIO has none of them), so Jämmer reads them back.
    public static func write(_ t: ExchangeTimeline) throws -> Written {
        let sr = t.sampleRate
        var warnings: [String] = []
        var overlaps = 0
        let tracks: [[String: Any]] = t.tracks.map { track in
            var children: [[String: Any]] = []
            var at = 0.0
            for c in track.clips {
                guard c.start >= at - 1e-9 else { overlaps += 1; continue }
                if c.start - at > 1e-9 {
                    children.append(["OTIO_SCHEMA": "Gap.1", "name": "", "metadata": [:] as [String: Any], "enabled": true,
                                     "source_range": range(0, c.start - at, sr), "effects": [] as [Any], "markers": [] as [Any]])
                }
                let ref: [String: Any] = ["OTIO_SCHEMA": "ExternalReference.1", "name": c.name, "metadata": [:] as [String: Any],
                                          "target_url": URL(fileURLWithPath: c.path).absoluteString,
                                          "available_range": range(0, c.fileDuration, c.sampleRate)]
                children.append(["OTIO_SCHEMA": "Clip.2", "name": c.name, "enabled": true, "effects": [] as [Any], "markers": [] as [Any],
                                 "source_range": range(c.sourceStart, c.duration, sr),
                                 "media_references": ["DEFAULT_MEDIA": ref], "active_media_reference_key": "DEFAULT_MEDIA",
                                 "metadata": ["jammer": ["gainDB": c.gainDB, "fadeIn": c.fadeIn, "fadeOut": c.fadeOut]]])
                at = c.start + c.duration
            }
            return ["OTIO_SCHEMA": "Track.1", "name": track.name, "kind": "Audio", "enabled": true, "children": children,
                    "effects": [] as [Any], "markers": [] as [Any], "source_range": NSNull(),
                    "metadata": ["jammer": ["gainDB": track.gainDB, "pan": track.pan, "muted": track.muted]]]
        }
        if overlaps > 0 { warnings.append("\(overlaps) clips that lay over the clip before them on their track were left out (an OTIO track is a sequence).") }
        let markers: [[String: Any]] = t.markers.map {
            ["OTIO_SCHEMA": "Marker.2", "name": $0.name, "color": "GREEN", "comment": "", "metadata": [:] as [String: Any],
             "marked_range": range($0.start, $0.duration, sr)]
        }
        let stack: [String: Any] = ["OTIO_SCHEMA": "Stack.1", "name": "tracks", "children": tracks, "markers": markers, "effects": [] as [Any],
                                    "enabled": true, "source_range": NSNull(), "metadata": [:] as [String: Any]]
        var timeline: [String: Any] = ["OTIO_SCHEMA": "Timeline.1", "name": t.name, "tracks": stack,
                                       "metadata": ["jammer": ["sampleRate": sr, "channels": t.channels]]]
        if let tc = t.timecode {
            let r = tc.rate.perSecond, fps = Double(r.num) / Double(r.den)
            timeline["global_start_time"] = ["OTIO_SCHEMA": "RationalTime.1", "rate": fps, "value": Double(tc.startFrames)]
        } else {
            timeline["global_start_time"] = NSNull()
        }
        let data = try JSONSerialization.data(withJSONObject: timeline, options: [.prettyPrinted, .sortedKeys])
        return Written(data: data, warnings: warnings)
    }

    /// Reads an .otio file's audio tracks as a timeline to build a document from. A clip's file is its active
    /// ExternalReference's target_url (file:// or a path, relative to the .otio file's folder). Video tracks,
    /// transitions, nested stacks and clips without a file are left out, each said in a warning.
    public static func read(_ data: Data, base: URL, name: String) throws(FCPXMLImport.ImportError) -> FCPXMLImport.Timeline {
        guard data.count < 256 << 20 else { throw .unreadable("it is larger than an OTIO timeline is.") }
        // OTIO allows NaN and ±Infinity, which JSON doesn't: read with them made harmless.
        var text = String(decoding: data, as: UTF8.self)
        for word in ["-Infinity", "Infinity", "-Inf", "Inf", "NaN"] { text = text.replacingOccurrences(of: ": \(word)", with: ": null").replacingOccurrences(of: ":\(word)", with: ":null") }
        guard let root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { throw .unreadable("it isn't JSON.") }
        guard (root["OTIO_SCHEMA"] as? String)?.hasPrefix("Timeline.") == true, let stack = root["tracks"] as? [String: Any] else {
            throw .unreadable("its top object isn't an OTIO Timeline.")
        }
        func seconds(_ v: Any?) -> Double? {
            guard let d = v as? [String: Any], let value = d["value"] as? Double, let rate = d["rate"] as? Double, rate > 0, value.isFinite else { return nil }
            return value / rate
        }
        func span(_ v: Any?) -> (start: Double, duration: Double)? {
            guard let d = v as? [String: Any], let s = seconds(d["start_time"]), let du = seconds(d["duration"]) else { return nil }
            return (s, du)
        }
        func jammer(_ o: [String: Any]) -> [String: Any] { ((o["metadata"] as? [String: Any])?["jammer"] as? [String: Any]) ?? [:] }
        var warnings: [FCPXMLImport.Warning] = []
        var video = 0, transitions = 0, nested = 0, missing = 0
        var tracks: [FCPXMLImport.TrackItem] = []
        for (i, t) in ((stack["children"] as? [[String: Any]]) ?? []).enumerated() {
            guard (t["OTIO_SCHEMA"] as? String)?.hasPrefix("Track.") == true else { nested += 1; continue }
            guard (t["kind"] as? String) == "Audio" else { video += 1; continue }
            var at = 0.0, clips: [FCPXMLImport.ClipItem] = []
            for c in (t["children"] as? [[String: Any]]) ?? [] {
                let schema = (c["OTIO_SCHEMA"] as? String) ?? ""
                if schema.hasPrefix("Transition.") { transitions += 1; continue }    // a transition overlaps; it takes no time of its own
                guard let r = span(c["source_range"]) else { nested += 1; continue }
                defer { at += r.duration }
                if schema.hasPrefix("Gap.") { continue }
                guard schema.hasPrefix("Clip.") else { nested += 1; continue }
                let refs = c["media_references"] as? [String: Any]
                let ref = (refs?[(c["active_media_reference_key"] as? String) ?? "DEFAULT_MEDIA"] ?? c["media_reference"]) as? [String: Any]
                guard let target = ref?["target_url"] as? String, !target.isEmpty else { missing += 1; continue }
                let url: URL = target.hasPrefix("file:") ? (URL(string: target) ?? base.appending(path: target)) : target.hasPrefix("/") ? URL(fileURLWithPath: target) : base.appending(path: target)
                let md = jammer(c)
                let enabled = (c["enabled"] as? Bool) ?? true
                clips.append(.init(name: (c["name"] as? String) ?? url.lastPathComponent, media: url.standardizedFileURL, mediaName: url.lastPathComponent,
                                   start: .init(seconds: at), sourceStart: .init(seconds: r.start), duration: .init(seconds: r.duration),
                                   gainDB: (md["gainDB"] as? Double) ?? 0, fadeIn: .init(seconds: (md["fadeIn"] as? Double) ?? 0),
                                   fadeOut: .init(seconds: (md["fadeOut"] as? Double) ?? 0), enabled: enabled, origin: nil))
            }
            let md = jammer(t)
            tracks.append(.init(lane: i, name: (t["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "A\(tracks.count + 1)",
                                gainDB: (md["gainDB"] as? Double) ?? 0, muted: (md["muted"] as? Bool) ?? ((t["enabled"] as? Bool) == false), origin: nil, clips: clips))
        }
        guard tracks.contains(where: { !$0.clips.isEmpty }) else { throw .noAudio("The timeline has no audio clips with a file\(video > 0 ? " (\(video) video tracks were left out)" : "").") }
        if video > 0 { warnings.append(.init(code: "video", message: "\(video) video tracks were left out: Jämmer reads the audio.", clip: nil)) }
        if transitions > 0 { warnings.append(.init(code: "transition", message: "\(transitions) transitions were read as cuts.", clip: nil)) }
        if nested > 0 { warnings.append(.init(code: "nested", message: "\(nested) nested stacks or unknown items were left out.", clip: nil)) }
        if missing > 0 { warnings.append(.init(code: "missing_media", message: "\(missing) clips have no file (a missing reference) and were left out.", clip: nil)) }
        let shots: [FCPXMLImport.Shot] = ((stack["markers"] as? [[String: Any]]) ?? []).compactMap { m in
            guard let r = span(m["marked_range"] ?? m["range"]) else { return nil }
            return .init(name: (m["name"] as? String) ?? "", start: .init(seconds: r.start), duration: .init(seconds: r.duration))
        }
        let md = jammer(root)
        var timeline = FCPXMLImport.Timeline(name: (root["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name,
                                             sampleRate: (md["sampleRate"] as? Double) ?? 48_000, channels: (md["channels"] as? Int).map { min(2, max(1, $0)) } ?? 2,
                                             tracks: tracks, shots: shots, flimmerExportVersion: nil, flimmerProjectId: nil, flimmerStoryId: nil, warnings: warnings)
        // The global start as a timecode, when it is at a picture rate this app counts.
        if let g = root["global_start_time"] as? [String: Any], let value = g["value"] as? Double, let rate = g["rate"] as? Double {
            let known: [(Double, Timecode.Rate)] = [(24_000.0 / 1_001, .fps23976), (24, .fps24), (25, .fps25), (30_000.0 / 1_001, .fps2997), (30, .fps30),
                                                    (50, .fps50), (60_000.0 / 1_001, .fps5994), (60, .fps60)]
            if let r = known.first(where: { abs($0.0 - rate) < 1e-3 })?.1, value >= 0, value < 24 * 3_600 * 60 {
                timeline.timecode = TimecodeSettings(rate: r, startFrames: Int(value.rounded()))
            }
        }
        return timeline
    }
}
