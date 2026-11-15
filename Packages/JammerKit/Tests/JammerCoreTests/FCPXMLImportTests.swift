import Foundation
import Testing
@testable import JammerCore

@Suite("FCPXML import")
struct FCPXMLImportTests {
    typealias Time = FCPXMLImport.Time

    /// A folder with media/<name>.wav files of the given length and rate (a quiet tone).
    func folder(_ files: [(String, Double, Double)]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "jammer-fcpxml-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir.appending(path: "media"), withIntermediateDirectories: true)
        for (name, seconds, rate) in files {
            let n = Int(seconds * rate)
            let x = (0..<n).map { Float(0.1 * sin(2 * .pi * 440 * Double($0) / rate)) }
            try writeWAV(x, to: dir.appending(path: "media/\(name).wav"), channels: 1, sampleRate: rate, encoding: .int24)
        }
        return dir
    }

    @Test("Times are rational: 1001/24000 s frames add up exactly")
    func times() {
        #expect(Time("1001/24000s") == Time(n: 1001, d: 24_000) && Time("0s") == .zero && Time("5s") == Time(n: 5, d: 1) && Time("2.5s") == Time(n: 5, d: 2))
        #expect(Time("12") == nil && Time("x/2s") == nil && Time(nil) == nil && Time("1/0s") == nil)
        // 30 000 frames of 1001/24000 s is exactly 1251.25 s; a double sum would drift.
        var t = Time.zero
        for _ in 0..<30_000 { t = t + Time(n: 1001, d: 24_000) }
        #expect(t == Time(n: 5005, d: 4) && t.frames(at: 48_000) == 60_060_000)
        #expect((Time(n: 7, d: 3) - Time(n: 1, d: 3)) == Time(n: 2, d: 1))
    }

    @Test("A file from another program: lanes become tracks, with trim, level, linear fades, mute and the clip's own sound")
    func plain() throws {
        let dir = try folder([("voice", 10, 48_000), ("music", 20, 48_000), ("old", 5, 44_100), ("film", 6, 48_000)])
        defer { try? FileManager.default.removeItem(at: dir) }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.10">
          <resources>
            <format id="r1" frameDuration="1001/24000s" width="1920" height="1080"/>
            <asset id="a1" name="film.mov" start="0s" duration="6s" hasVideo="1" format="r1" hasAudio="1" audioChannels="1" audioRate="48000"><media-rep kind="original-media" src="media/film.wav"/></asset>
            <asset id="a2" name="voice.wav" start="0s" duration="10s" hasAudio="1" audioRate="48000"><media-rep kind="original-media" src="media/voice.wav"/></asset>
            <asset id="a3" name="music.wav" start="0s" duration="20s" hasAudio="1" audioRate="48000" src="media/music.wav"/>
            <asset id="a4" name="old.wav" start="0s" duration="5s" hasAudio="1" audioRate="44100"><media-rep kind="original-media" src="media/old.wav"/></asset>
            <asset id="a5" name="gone.wav" start="0s" duration="5s" hasAudio="1"><media-rep kind="original-media" src="media/gone.wav"/></asset>
            <asset id="a6" name="still.png" start="0s" duration="0s" hasVideo="1"><media-rep kind="original-media" src="media/still.png"/></asset>
          </resources>
          <library><event name="E"><project name="Harbour">
            <sequence format="r1" duration="480480/24000s" audioLayout="stereo" audioRate="48k">
              <spine>
                <asset-clip ref="a1" offset="0s" name="Opening" start="24024/24000s" duration="96096/24000s">
                  <adjust-volume amount="-3dB"/>
                  <asset-clip ref="a2" lane="-1" offset="48048/24000s" name="Narrator" start="12012/24000s" duration="72072/24000s" audioRole="dialogue">
                    <adjust-volume amount="-6dB"><param name="amount"><fadeIn type="linear" duration="24024/24000s"/><fadeOut type="linear" duration="12012/24000s"/></param></adjust-volume>
                  </asset-clip>
                  <asset-clip ref="a3" lane="-2" offset="24024/24000s" name="Bed" start="0s" duration="240240/24000s" enabled="0" audioRole="music"/>
                </asset-clip>
                <gap offset="96096/24000s" name="Gap" start="3600s" duration="96096/24000s">
                  <asset-clip ref="a4" lane="-1" offset="86448048/24000s" name="Old tape" start="0s" duration="72072/24000s" audioRole="dialogue"/>
                  <asset-clip ref="a2" lane="1" offset="3600s" name="Off" start="0s" duration="24024/24000s" enabled="0" audioRole="effects"/>
                  <asset-clip ref="a2" lane="1" offset="86448048/24000s" name="On" start="0s" duration="24024/24000s" audioRole="effects"/>
                  <asset-clip ref="a5" lane="2" offset="3600s" name="Lost" start="0s" duration="24024/24000s"/>
                </gap>
                <clip offset="192192/24000s" name="Still" start="0s" duration="48048/24000s"><video ref="a6" offset="0s" start="0s" duration="48048/24000s"/></clip>
              </spine>
            </sequence>
          </project></event></library>
        </fcpxml>
        """
        let file = dir.appending(path: "t.fcpxml")
        try Data(xml.utf8).write(to: file)
        let timeline = try FCPXMLImport.read(file)
        #expect(timeline.name == "Harbour" && timeline.sampleRate == 48_000 && timeline.flimmerExportVersion == nil)
        #expect(timeline.tracks.map(\.name) == ["dialogue", "music", "effects", "Lane 2", "Video"])
        // Shots: the pictures, not the plain gap.
        #expect(timeline.shots.map(\.name) == ["Opening", "Still"])
        let r = try FCPXMLImport.build(timeline, mediaFolder: dir.appending(path: "decoded"))
        let p = r.project
        func f(_ frames1001: Int64) -> Frame { frames1001 * 1001 * 2 } // n frames of 1001/24000 s at 48 kHz
        #expect(p.tracks.map(\.name) == ["dialogue", "music", "effects", "Video"])
        // Narrator: parent offset 0, parent start 24 frames, own offset 48 frames → 24 frames on the timeline.
        let narrator = p.tracks[0].clips[0]
        #expect(narrator.start == f(24) && narrator.sourceStart == f(12) && narrator.length == f(72) && narrator.gainDB == -6)
        #expect(narrator.fadeIn == f(24) && narrator.fadeOut == f(12) && narrator.fadeShape == .linear && narrator.origin == nil)
        // Old tape: in a gap whose local time starts at 3600 s; 3602.002 s − 3600 s + the gap's 96 frames.
        let old = p.tracks[0].clips[1]
        #expect(old.start == f(96) + f(48) && old.length == f(72))
        #expect(p.source(old.sourceID)?.info.sampleRate == 48_000, "the 44.1 kHz file plays from a 48 kHz copy")
        // Every clip of the music lane is off: a muted track. One of two off on effects: left out, said so.
        #expect(p.tracks[1].isMuted && p.tracks[1].clips.count == 1 && p.tracks[1].clips[0].start == f(0))
        #expect(!p.tracks[2].isMuted && p.tracks[2].clips.count == 1 && p.tracks[2].clips[0].start == f(96) + f(48))
        // The film's own sound: under the picture, from its in-point, at the clip's level.
        let video = p.tracks[3].clips[0]
        #expect(video.start == 0 && video.sourceStart == f(24) && video.length == f(96) && video.gainDB == -3)
        let codes = r.warnings.map(\.code)
        #expect(codes.contains("resampled") && codes.contains("disabled_clip") && codes.contains("missing_media"), "\(r.warnings)")
        // Shot markers show where the pictures were, and are not chapters.
        #expect(p.markers.map(\.name) == ["Opening", "Still"] && p.markers.allSatisfy { $0.kind == .shot } && p.markers[1].position == f(192) && p.markers[1].length == f(48))
        #expect(p.chapters().isEmpty)
        // In a file (WAV cue points) a shot says what it is; an ordinary marker keeps its name.
        #expect(p.markers[0].cueLabel == "Shot: Opening" && Marker(position: 0, name: "Intro").cueLabel == "Intro")
    }

    @Test("A Flimmer export: exact times and separate levels from the metadata, origins carried, the film's sound when it says so")
    func flimmer() throws {
        let dir = try folder([("a", 10, 48_000), ("b", 12, 48_000), ("v1", 4, 48_000), ("v2", 4, 48_000)])
        defer { try? FileManager.default.removeItem(at: dir) }
        func md(_ pairs: [(String, String)]) -> String {
            "<metadata>" + pairs.map { "<md key=\"com.brattoo.flimmer.\($0.0)\" value=\"\($0.1)\"/>" }.joined() + "</metadata>"
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <fcpxml version="1.11">
          <resources>
            <format id="r1" frameDuration="1/24s"/>
            <asset id="a1" name="a.wav" start="0s" duration="480000/48000s" hasAudio="1"><media-rep kind="original-media" src="media/a.wav"/></asset>
            <asset id="a2" name="b.wav" start="0s" duration="576000/48000s" hasAudio="1"><media-rep kind="original-media" src="media/b.wav"/></asset>
            <asset id="v1" name="quiet.mp4" start="0s" duration="96/24s" hasVideo="1" hasAudio="1"><media-rep kind="original-media" src="media/v1.wav"/></asset>
            <asset id="v2" name="waves.mp4" start="0s" duration="96/24s" hasVideo="1" hasAudio="1"><media-rep kind="original-media" src="media/v2.wav"/></asset>
            <asset id="s" name="still.png" start="0s" duration="0s" hasVideo="1"><media-rep kind="original-media" src="media/still.png"/></asset>
          </resources>
          <library><event name="E"><project name="Film">
            <sequence format="r1" duration="480/24s" audioLayout="stereo" audioRate="48k">
              <spine>
                <clip offset="0s" name="One" start="0s" duration="96/24s">
                  <video ref="s" offset="0s" start="0s" duration="96/24s"/>
                  <asset-clip ref="a1" lane="-1" offset="108/24s" name="a.wav" start="0s" duration="149/24s" audioRole="Dialog">
                    <adjust-volume amount="-6.38dB"/>
                    \(md([("clipId", "C1"), ("trackId", "T1"), ("trackName", "Dialog"), ("trackPosition", "0"), ("trackVolume", "0.8"), ("clipVolume", "0.6"), ("trackMuted", "0"),
                          ("linkedShotId", "S1"), ("clipRelativeOffset", "0.5"), ("timelineOffset", "4.5"), ("startTime", "0"), ("endTime", "6.249"), ("fadeIn", "0"), ("fadeOut", "0")]))
                  </asset-clip>
                  <asset-clip ref="a2" lane="-2" offset="192/24s" name="b.wav" start="36/24s" duration="180/24s" enabled="0" audioRole="Musik">
                    <adjust-volume amount="-96dB"><param name="amount"><fadeIn type="linear" duration="24/24s"/><fadeOut type="linear" duration="48/24s"/></param></adjust-volume>
                    \(md([("clipId", "C2"), ("trackId", "T2"), ("trackName", "Musik"), ("trackPosition", "1"), ("trackVolume", "1"), ("clipVolume", "0"), ("trackMuted", "1"),
                          ("timelineOffset", "8"), ("startTime", "1.5"), ("endTime", "9"), ("fadeIn", "1"), ("fadeOut", "2")]))
                  </asset-clip>
                  <asset-clip ref="a2" lane="-2" offset="408/24s" name="short" start="0s" duration="24/24s" enabled="0" audioRole="Musik">
                    <adjust-volume amount="0dB"><param name="amount"><fadeIn type="linear" duration="8/24s"/><fadeOut type="linear" duration="16/24s"/></param></adjust-volume>
                    \(md([("clipId", "C3"), ("trackId", "T2"), ("trackName", "Musik"), ("trackPosition", "1"), ("trackVolume", "1"), ("clipVolume", "1"), ("trackMuted", "1"),
                          ("timelineOffset", "17"), ("startTime", "0"), ("endTime", "1"), ("fadeIn", "1"), ("fadeOut", "2")]))
                  </asset-clip>
                  \(md([("shotId", "S1")]))
                </clip>
                <asset-clip ref="v1" offset="96/24s" name="Two" start="24/24s" duration="60/24s">\(md([("shotId", "S2"), ("shotClipId", "K2"), ("videoAudio", "0")]))</asset-clip>
                <gap offset="156/24s" name="Empty crates" start="0s" duration="48/24s">\(md([("shotId", "S3")]))</gap>
                <asset-clip ref="v2" offset="204/24s" name="Four" start="12/24s" duration="72/24s">\(md([("shotId", "S4"), ("shotClipId", "K4"), ("videoAudio", "1"), ("videoAudioVolume", "1")]))</asset-clip>
                <gap offset="276/24s" name="Audio" start="0s" duration="204/24s"/>
              </spine>
              \(md([("exportVersion", "1")]))
            </sequence>
          </project></event></library>
        </fcpxml>
        """
        let file = dir.appending(path: "f.fcpxml")
        try Data(xml.utf8).write(to: file)
        let timeline = try FCPXMLImport.read(file)
        #expect(timeline.flimmerExportVersion == "1")
        #expect(timeline.shots.map(\.name) == ["One", "Two", "Empty crates", "Four"], "a gap that stands for a shot counts; the trailing audio gap doesn't")
        let r = try FCPXMLImport.build(timeline, mediaFolder: dir.appending(path: "decoded"))
        let p = r.project
        #expect(p.tracks.map(\.name) == ["Dialog", "Musik", "Video"] && r.warnings.isEmpty, "\(r.warnings)")
        let sr = 48_000.0
        // Dialog: 4.5 s exactly (the FCPXML says 108/24 too, but 6.249 s isn't a whole number of pictures).
        let d = p.tracks[0]
        #expect(abs(d.gainDB - -1.94) < 0.005 && !d.isMuted && d.origin?.trackId == "T1" && d.origin?.app == "flimmer" && d.origin?.exportVersion == "1")
        #expect(d.clips[0].start == Frame(4.5 * sr) && d.clips[0].length == Frame((6.249 * sr).rounded()) && abs(d.clips[0].gainDB - -4.44) < 0.005)
        let o = try #require(d.clips[0].origin)
        #expect(o.clipId == "C1" && o.trackId == "T1" && o.linkedShotId == "S1" && o.exportVersion == "1" && o.videoAudio == nil)
        #expect(o.snapshot?.start == d.clips[0].start && o.snapshot?.length == d.clips[0].length && o.snapshot?.gainDB == d.clips[0].gainDB)
        // Musik: muted as a track; a silent clip is −96 dB, not mute; stored fades when they fit.
        let m = p.tracks[1]
        #expect(m.isMuted && m.gainDB == 0 && m.clips.count == 2)
        #expect(m.clips[0].start == Frame(8 * sr) && m.clips[0].sourceStart == Frame(1.5 * sr) && m.clips[0].length == Frame(7.5 * sr) && m.clips[0].gainDB == -96)
        #expect(m.clips[0].fadeIn == Frame(sr) && m.clips[0].fadeOut == Frame(2 * sr))
        // Stored fades of 1 + 2 s on a 1 s clip: what is rendered is the adapted lengths in the FCPXML fields.
        #expect(m.clips[1].length == Frame(sr) && m.clips[1].fadeIn == Frame(sr / 3) && m.clips[1].fadeOut == Frame(sr * 2 / 3))
        // The film's sound: only where videoAudio is 1, under its picture, from the same in-point.
        let v = p.tracks[2]
        #expect(v.clips.count == 1 && v.clips[0].start == Frame(204.0 / 24 * sr) && v.clips[0].sourceStart == Frame(0.5 * sr) && v.clips[0].length == Frame(3 * sr) && v.clips[0].gainDB == 0)
        #expect(v.clips[0].origin?.clipId == "K4" && v.clips[0].origin?.linkedShotId == "S4" && v.clips[0].origin?.videoAudio == true)
        #expect(p.imported == Project.ImportRecord(app: "flimmer", exportVersion: "1", clipIds: ["C1", "C2", "C3"], length: p.length))

        // The way back, first half: what has changed since it came in.
        let sr48 = Frame(48_000)
        var plan = try FlimmerReturn.plan(p)
        #expect(plan.isEmpty && plan.unchanged == ["C1", "C2", "C3"] && plan.missing.isEmpty && plan.videoChanged.isEmpty && plan.lengthChangedBy == 0)
        // A level change in the middle of C1 splits it in three: one take over the whole clip, in place.
        var e = p
        try e.changeGain(Frame(5 * sr)..<Frame(6 * sr), by: -3)
        plan = try FlimmerReturn.plan(e)
        #expect(plan.takes.count == 1 && plan.takes[0].clipId == "C1" && plan.takes[0].pieces == 3 && plan.takes[0].movedBy == 0 && !plan.takes[0].changedTrack)
        #expect(plan.takes[0].range == d.clips[0].start..<d.clips[0].end && plan.takes[0].linkedShotId == "S1" && plan.unchanged == ["C2", "C3"])
        // Moved half a second later: a take that carries its new position.
        e = p
        e.tracks[1].clips[1].start += sr48 / 2
        plan = try FlimmerReturn.plan(e)
        #expect(plan.takes.map(\.clipId) == ["C3"] && plan.takes[0].movedBy == sr48 / 2 && plan.takes[0].pieces == 1)
        // Removed: listed as missing, nothing else. A clip on another track: said, and still one take.
        e = p
        let moved = e.tracks[1].clips.removeLast()
        e.tracks[0].clips.append(moved)
        e.tracks[1].clips.removeAll()
        plan = try FlimmerReturn.plan(e)
        #expect(plan.missing == ["C2"] && plan.takes.map(\.clipId) == ["C3"] && plan.takes[0].changedTrack && plan.takes[0].movedBy == 0)
        // Sound added here has no origin: a new clip, on the Flimmer track it sits on.
        e = p
        e.tracks[0].clips.append(Clip(sourceID: d.clips[0].sourceID, start: 15 * sr48, length: sr48))
        e.tracks.append(Track(name: "Foley", clips: [Clip(sourceID: d.clips[0].sourceID, start: 0, length: sr48)]))
        plan = try FlimmerReturn.plan(e)
        #expect(plan.new.map(\.trackId) == ["T1", nil] && plan.new[1].trackName == "Foley" && plan.new[0].range == 15 * sr48..<16 * sr48 && plan.takes.isEmpty)
        // Track level and mute are values, not takes; a plugin on the track makes its clips takes.
        e = p
        e.tracks[0].gainDB = -6
        e.tracks[1].isMuted = false
        plan = try FlimmerReturn.plan(e)
        #expect(plan.tracks == [.init(trackId: "T1", name: "Dialog", gainDB: -6, muted: false), .init(trackId: "T2", name: "Musik", gainDB: 0, muted: false)] && plan.takes.isEmpty)
        e = p
        e.tracks[0].inserts = [Insert(plugin: .init(type: 1, subtype: 2, manufacturer: 3), name: "EQ")]
        #expect(try FlimmerReturn.plan(e).takes.map(\.clipId) == ["C1"])
        // The film's own sound changed: reported, not a take. A ripple cut: the length says so.
        e = p
        e.tracks[2].clips[0].gainDB = -3
        plan = try FlimmerReturn.plan(e)
        #expect(plan.videoChanged == ["K4"] && plan.takes.isEmpty)
        e = p
        e.tracks[1].clips.removeAll()
        e.tracks[2].clips.removeAll()
        #expect(try FlimmerReturn.plan(e).lengthChangedBy < 0)
        // A document that didn't come from Flimmer has nowhere to go back to.
        #expect(throws: FlimmerReturn.PlanError.notFromFlimmer) { try FlimmerReturn.plan(Project(sampleRate: 48_000, channels: 2)) }
        // Origins survive edits and saving.
        var q = p
        try q.changeGain(Frame(5 * sr)..<Frame(6 * sr), by: -3)
        #expect(q.tracks[0].clips.count == 3 && q.tracks[0].clips.allSatisfy { $0.origin?.clipId == "C1" })
        let saved = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(q))
        #expect(saved == q && saved.tracks[0].origin?.trackId == "T1" && saved.markers.first?.kind == .shot)
        // A project saved before origins existed still opens.
        let old = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(Project(sampleRate: 48_000, channels: 2, tracks: [Track(name: "t")], markers: [Marker(position: 0, name: "m")])))
        #expect(old.tracks[0].origin == nil && old.markers[0].kind == nil)
    }

    @Test("What can't be imported says why")
    func errors() throws {
        let base = FileManager.default.temporaryDirectory
        #expect(throws: FCPXMLImport.ImportError.self) { try FCPXMLImport.read(Data("not xml".utf8), base: base, name: "x") }
        #expect(throws: FCPXMLImport.ImportError.noSequence) { try FCPXMLImport.read(Data("<fcpxml version=\"1.11\"><resources/></fcpxml>".utf8), base: base, name: "x") }
        let empty = try FCPXMLImport.read(Data("<fcpxml version=\"1.11\"><resources/><library><event><project name=\"P\"><sequence><spine><gap offset=\"0s\" duration=\"5s\"/></spine></sequence></project></event></library></fcpxml>".utf8), base: base, name: "x")
        #expect(throws: FCPXMLImport.ImportError.noAudio) { try FCPXMLImport.build(empty, mediaFolder: base) }
    }
}

/// Flimmer's own sample export against its project.json (JAMMER_FLIMMER_SAMPLE: the folder
/// with Morgon_i_hamnen.fcpxml, project.json and media/; not in this repository).
@Suite("FCPXML import of Flimmer's sample", .enabled(if: ProcessInfo.processInfo.environment["JAMMER_FLIMMER_SAMPLE"] != nil))
struct FlimmerSampleTests {
    @Test("Every clip's position, trim, fades, level and mute match project.json")
    func sample() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JAMMER_FLIMMER_SAMPLE"]!)
        let scratch = FileManager.default.temporaryDirectory.appending(path: "jammer-flimmer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let timeline = try FCPXMLImport.read(dir.appending(path: "Morgon_i_hamnen.fcpxml"))
        let r = try FCPXMLImport.build(timeline, mediaFolder: scratch)
        let p = r.project
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appending(path: "project.json"))) as! [String: Any]
        let tracks = (json["timelineTracks"] as! [[String: Any]]).sorted { ($0["position"] as! Int) < ($1["position"] as! Int) }
        let clips = json["audioClips"] as! [[String: Any]]
        print("FLIMMER tracks:", p.tracks.map { "\($0.name) \($0.gainDB) dB\($0.isMuted ? " muted" : "") ×\($0.clips.count)" }, "warnings:", r.warnings.map(\.message))
        func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
        func db(_ v: Double) -> Double { v <= 0 ? -96 : 20 * log10(v) }
        var checked = 0
        for (i, t) in tracks.enumerated() {
            let mine = try #require(p.tracks.first { $0.origin?.trackId == t["id"] as? String }, "track \(t["name"] ?? "")")
            #expect(p.tracks.firstIndex(of: mine) == i && mine.name == t["name"] as? String)
            #expect(abs(mine.gainDB - db(num(t["volume"]))) < 0.006 && mine.isMuted == (t["muted"] as? Bool ?? false))
            for c in clips where c["trackId"] as? String == t["id"] as? String {
                let clip = try #require(mine.clips.first { $0.origin?.clipId == c["id"] as? String }, "clip \(c["id"] ?? "")")
                let sr = p.sampleRate
                let source = try #require(p.source(clip.sourceID))
                #expect(clip.start == Frame((num(c["timelineOffset"]) * sr).rounded()), "position of \(source.name)")
                #expect(clip.sourceStart == Frame((num(c["startTime"]) * sr).rounded()), "in-point of \(source.name)")
                let want = min(Frame(((num(c["endTime"]) - num(c["startTime"])) * sr).rounded()), source.info.frames - clip.sourceStart)
                #expect(clip.length == want, "length of \(source.name): \(clip.length) for \(want)")
                #expect(clip.fadeIn == Frame((num(c["fadeIn"]) * sr).rounded()) && clip.fadeOut == Frame((num(c["fadeOut"]) * sr).rounded()), "fades of \(source.name)")
                #expect(abs(clip.gainDB - db(num(c["volume"]))) < 0.006 && clip.fadeShape == .linear, "level of \(source.name)")
                #expect(clip.origin?.linkedShotId == c["linkedShotId"] as? String)
                checked += 1
            }
        }
        #expect(checked == clips.count && checked == 5)
        // The film's own sound: only the clip that says videoAudio = 1.
        let video = try #require(p.tracks.last)
        #expect(video.name == "Video" && video.clips.count == 1 && p.tracks.count == tracks.count + 1)
        #expect(video.clips[0].start == Frame(408.0 / 24 * p.sampleRate) && video.clips[0].gainDB == 0)
        #expect(p.markers.count == 7 && p.markers.allSatisfy { $0.kind == .shot })
    }
}
