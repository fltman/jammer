import Foundation

/// DAWproject 1.0 (Bitwig's open format, MIT; docs/LICENSES.md), audio only, with Jämmer's own code: a ZIP
/// holding project.xml and metadata.xml as the format's Project.xsd and MetaData.xsd describe them.
public enum DAWproject {
    public static let version = "1.0"

    public struct Written: Sendable, Equatable {
        public var data: Data
        public var warnings: [Said]
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "\n", with: "&#10;")
    }
    static func num(_ v: Double) -> String { v.isFinite ? String(format: "%.9g", v) : (v > 0 ? "inf" : "-inf") }

    /// Each track a Track with its Channel (volume as linear gain, pan 0–1, mute) going to the master Channel;
    /// the arrangement in seconds, each clip's Audio pointing at its file by its absolute path (external, so
    /// the project stays small and the audio isn't copied). A clip's own gain has no place in the format.
    public static func write(_ t: ExchangeTimeline, appVersion: String) -> Written {
        var warnings: [Said] = []
        var n = 0
        func id() -> String { n += 1; return "id\(n)" }
        var x: [String] = ["<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>",
                           "<Project version=\"\(version)\">",
                           "  <Application name=\"Jämmer\" version=\"\(escape(appVersion))\"/>",
                           "  <Transport>",
                           "    <Tempo id=\"\(id())\" max=\"999\" min=\"10\" unit=\"bpm\" value=\"\(num(t.bpm))\"/>",
                           "    <TimeSignature id=\"\(id())\" numerator=\"\(t.meter.0)\" denominator=\"\(t.meter.1)\"/>",
                           "  </Transport>",
                           "  <Structure>"]
        let master = "master"
        var trackIDs: [String] = []
        for track in t.tracks {
            let tid = id(), cid = id()
            trackIDs.append(tid)
            x.append("    <Track id=\"\(tid)\" name=\"\(escape(track.name))\" contentType=\"audio\" loaded=\"true\">")
            x.append("      <Channel id=\"\(cid)\" role=\"regular\" audioChannels=\"\(t.channels)\" destination=\"\(master)\" solo=\"false\">")
            x.append("        <Mute id=\"\(id())\" value=\"\(track.muted)\"/>")
            x.append("        <Pan id=\"\(id())\" max=\"1\" min=\"0\" unit=\"normalized\" value=\"\(num((track.pan + 1) / 2))\"/>")
            x.append("        <Volume id=\"\(id())\" max=\"2\" min=\"0\" unit=\"linear\" value=\"\(num(pow(10, track.gainDB / 20)))\"/>")
            x.append("      </Channel>")
            x.append("    </Track>")
        }
        x.append("    <Channel id=\"\(master)\" name=\"Master\" role=\"master\" audioChannels=\"\(t.channels)\" solo=\"false\">")
        x.append("      <Volume id=\"\(id())\" max=\"2\" min=\"0\" unit=\"linear\" value=\"1\"/>")
        x.append("    </Channel>")
        x.append("  </Structure>")
        x.append("  <Arrangement id=\"\(id())\">")
        x.append("    <Lanes id=\"\(id())\" timeUnit=\"seconds\">")
        var gains = 0
        for (track, tid) in zip(t.tracks, trackIDs) {
            x.append("      <Lanes id=\"\(id())\" track=\"\(tid)\">")
            x.append("        <Clips id=\"\(id())\">")
            for c in track.clips {
                if c.gainDB != 0 { gains += 1 }
                x.append("          <Clip name=\"\(escape(c.name))\" time=\"\(num(c.start))\" duration=\"\(num(c.duration))\" playStart=\"\(num(c.sourceStart))\" contentTimeUnit=\"seconds\" fadeTimeUnit=\"seconds\" fadeInTime=\"\(num(c.fadeIn))\" fadeOutTime=\"\(num(c.fadeOut))\">")
                x.append("            <Audio id=\"\(id())\" timeUnit=\"seconds\" channels=\"\(c.channels)\" sampleRate=\"\(Int(c.sampleRate.rounded()))\" duration=\"\(num(c.fileDuration))\">")
                x.append("              <File path=\"\(escape(c.path))\" external=\"true\"/>")
                x.append("            </Audio>")
                x.append("          </Clip>")
            }
            x.append("        </Clips>")
            x.append("      </Lanes>")
        }
        x.append("    </Lanes>")
        if !t.markers.isEmpty {
            x.append("    <Markers id=\"\(id())\" timeUnit=\"seconds\">")
            for m in t.markers { x.append("      <Marker name=\"\(escape(m.name))\" time=\"\(num(m.start))\"/>") }
            x.append("    </Markers>")
        }
        x.append("  </Arrangement>")
        x.append("</Project>")
        if gains > 0 { warnings.append(counted(gains, Said("note.dawproject.1_clip_has_gain.one", "1 clip has a gain of its own, which DAWproject has no place for."), Said("note.dawproject.1_clip_has_gain.other", "%@ clips have a gain of their own, which DAWproject has no place for.", "\(gains)"))) }
        if t.markers.contains(where: { $0.duration > 0 }) { warnings.append(Said("note.dawproject.regions_written_markers_their", "Regions are written as markers at their start: a DAWproject marker has no length.")) }
        let meta = ["<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>", "<MetaData>", "  <Title>\(escape(t.name))</Title>", "  <Comment>Made with Jämmer</Comment>", "</MetaData>"]
        let data = Zip.write([("project.xml", Data(x.joined(separator: "\n").utf8)), ("metadata.xml", Data(meta.joined(separator: "\n").utf8))])
        return Written(data: data, warnings: warnings)
    }

    /// Reads a .dawproject as a timeline to build a document from. Times in seconds or beats (beats at the
    /// project's tempo, the first one; tempo changes aren't followed). An Audio's file is outside the project
    /// (external, by its path, relative to the project's folder when it isn't absolute) or inside it, then
    /// unpacked into `unpackTo`. Warped audio, nested clips, notes and video are left out, each said.
    public static func read(_ data: Data, base: URL, name: String, unpackTo: URL) throws(FCPXMLImport.ImportError) -> FCPXMLImport.Timeline {
        guard data.count < 4 << 30 else { throw .unreadable(Said("error.import.larger_than_j_mmer", "it is larger than Jämmer reads.")) }
        let entries: [Zip.Entry]
        let projectXML: Data
        do {
            entries = try Zip.entries(data)
            guard let p = entries.first(where: { $0.name == "project.xml" }) else { throw Zip.Failure.notZip(Said("error.zip.has_project_xml", "it has no project.xml.")) }
            projectXML = try Zip.read(p, in: data, limit: FCPXMLImport.maxBytes)
        } catch let Zip.Failure.notZip(why) { throw .unreadable(why) } catch { throw .unreadable(Said("error.import.isn_t_dawproject_file", "it isn't a DAWproject file.")) }
        let root = try FCPXMLImport.parseXML(projectXML, rootName: "Project")
        var warnings: [FCPXMLImport.Warning] = []
        let bpm = Double(root.first("Transport")?.first("Tempo")?["value"] ?? "") ?? 120
        // Every element by its id, for the tracks the lanes name.
        var byID: [String: FCPXMLImport.Node] = [:]
        func index(_ n: FCPXMLImport.Node) { if let i = n["id"] { byID[i] = n }; n.children.forEach(index) }
        index(root)
        var tracks: [String: FCPXMLImport.TrackItem] = [:], order: [String] = []
        var warped = 0, nested = 0, notes = 0, inside = 0
        func seconds(_ v: String?, _ unit: String) -> Double? {
            guard let v, let d = Double(v), d.isFinite else { return nil }
            return unit == "beats" ? d * 60 / bpm : d
        }
        func walk(_ n: FCPXMLImport.Node, unit inherited: String, track: String?) throws(FCPXMLImport.ImportError) {
            let unit = n["timeUnit"] ?? inherited
            let track = n["track"] ?? track
            for c in n.children {
                switch c.name {
                case "Lanes", "Clips": try walk(c, unit: unit, track: track)
                case "Notes": notes += 1
                case "Clip":
                    guard let track, let start = seconds(c["time"], unit) else { continue }
                    let content = c["contentTimeUnit"] ?? unit
                    if c.first("Warps") != nil { warped += 1; continue }
                    guard let audio = c.first("Audio"), let file = audio.first("File"), let path = file["path"], !path.isEmpty else {
                        if c.first("Clips") != nil || c.first("Lanes") != nil { nested += 1 } else if c.first("Notes") != nil { notes += 1 }
                        continue
                    }
                    let playStart = seconds(c["playStart"], content) ?? 0
                    let duration = seconds(c["duration"], unit) ?? ((seconds(c["playStop"], content) ?? 0) - playStart)
                    guard duration > 0 else { continue }
                    let url: URL
                    if file["external"] == "true" {
                        url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appending(path: path)
                    } else {
                        // Inside the project: unpacked once, by a name that can't leave the folder.
                        guard let e = entries.first(where: { $0.name == path }) else { warnings.append(.init(code: "missing_media", message: Said("import.note.isn_t_project", "%@ isn't in the project.", "\(path)"), clip: c["name"])); continue }
                        let safe = path.split(separator: "/").last.map(String.init)?.replacingOccurrences(of: "..", with: "_") ?? "audio"
                        url = unpackTo.appending(path: "\(inside)-\(safe)")
                        if !FileManager.default.fileExists(atPath: url.path) {
                            do {
                                try FileManager.default.createDirectory(at: unpackTo, withIntermediateDirectories: true)
                                try Zip.read(e, in: data, limit: 4 << 30).write(to: url)
                            } catch { warnings.append(.init(code: "missing_media", message: Said("import.note.couldn_t_unpacked", "%@ couldn't be unpacked.", "\(path)"), clip: c["name"])); continue }
                        }
                        inside += 1
                    }
                    let fadeUnit = c["fadeTimeUnit"] ?? unit
                    let item = FCPXMLImport.ClipItem(name: c["name"] ?? url.lastPathComponent, media: url.standardizedFileURL, mediaName: url.lastPathComponent,
                                                     start: .init(seconds: start), sourceStart: .init(seconds: playStart), duration: .init(seconds: duration),
                                                     gainDB: 0, fadeIn: .init(seconds: seconds(c["fadeInTime"], fadeUnit) ?? 0),
                                                     fadeOut: .init(seconds: seconds(c["fadeOutTime"], fadeUnit) ?? 0), enabled: c["enable"] != "false", origin: nil)
                    if tracks[track] == nil {
                        let tn = byID[track]
                        let channel = tn?.first("Channel")
                        let volume = Double(channel?.first("Volume")?["value"] ?? "") ?? 1
                        let linear = channel?.first("Volume")?["unit"] != "decibel"
                        tracks[track] = .init(lane: order.count, name: tn?["name"] ?? "Track \(order.count + 1)",
                                              gainDB: linear ? (volume > 0 ? (20 * log10(volume) * 1e6).rounded() / 1e6 : -96) : volume,   // 0.501187 is −6 dB, not −5.99999999
                                              muted: channel?.first("Mute")?["value"] == "true", origin: nil, clips: [])
                        order.append(track)
                    }
                    tracks[track]!.clips.append(item)
                default: continue
                }
            }
        }
        guard let arrangement = root.first("Arrangement") else { throw .noSequence }
        try walk(arrangement, unit: arrangement["timeUnit"] ?? "beats", track: nil)
        guard !order.isEmpty else { throw .noAudio(Said("error.import.project_has_audio_clips", "The project has no audio clips in its arrangement.")) }
        if warped > 0 { warnings.append(.init(code: "warped", message: counted(warped, Said("note.dawproject.1_warped_time_stretched.one", "1 warped (time-stretched) clip was left out: Jämmer doesn't stretch audio to a tempo."), Said("note.dawproject.1_warped_time_stretched.other", "%@ warped (time-stretched) clips were left out: Jämmer doesn't stretch audio to a tempo.", "\(warped)")), clip: nil)) }
        if nested > 0 { warnings.append(.init(code: "nested", message: counted(nested, Said("note.dawproject.1_clip_holding_other.one", "1 clip holding other clips was left out."), Said("note.dawproject.1_clip_holding_other.other", "%@ clips holding other clips were left out.", "\(nested)")), clip: nil)) }
        if notes > 0 { warnings.append(.init(code: "notes", message: counted(notes, Said("note.dawproject.1_note_clip_was.one", "1 note clip was left out: Jämmer has no instruments."), Said("note.dawproject.1_note_clip_was.other", "%@ note clips were left out: Jämmer has no instruments.", "\(notes)")), clip: nil)) }
        let markers = root.first("Arrangement")?.first("Markers")
        let shots: [FCPXMLImport.Shot] = (markers?.all("Marker") ?? []).compactMap { m in
            seconds(m["time"], markers?["timeUnit"] ?? arrangement["timeUnit"] ?? "beats").map { .init(name: m["name"] ?? "", start: .init(seconds: $0), duration: .zero) }
        }
        return FCPXMLImport.Timeline(name: name, sampleRate: 48_000, channels: 2, tracks: order.map { tracks[$0]! }, shots: shots,
                                     flimmerExportVersion: nil, flimmerProjectId: nil, flimmerStoryId: nil, warnings: warnings)
    }
}
