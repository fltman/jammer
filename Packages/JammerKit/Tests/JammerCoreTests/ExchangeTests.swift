import Compression
import Foundation
import Testing
@testable import JammerCore

@Suite("Timeline exchange: EDL, OTIO, DAWproject")
struct ExchangeTests {
    let sr = 48_000.0

    /// A document of two tracks, every time on a 25 fps frame (so an EDL holds it exactly): a voice in two
    /// pieces with an offset into its file, music from 4 s on, a marker.
    func document(_ dir: TempDir) throws -> Project {
        func wav(_ name: String, seconds: Double, channels: Int) throws -> SourceRef {
            let url = dir.file(name)
            try writeWAV(noise(count: Int(sr * seconds) * channels, seed: 3).map { $0 * 0.1 }, to: url, channels: channels)
            return SourceRef(name: name, path: url.path, info: try AudioFileReader.info(at: url))
        }
        let voice = try wav("voice.wav", seconds: 10, channels: 1), music = try wav("music.wav", seconds: 8, channels: 2)
        var p = Project(sampleRate: sr, channels: 2)
        p.sources = [voice, music]
        p.tracks = [Track(name: "Voice", clips: [Clip(sourceID: voice.id, sourceStart: 48_000, start: 0, length: 96_000),
                                                 Clip(sourceID: voice.id, sourceStart: 192_000, start: 144_000, length: 124_800)]),
                    Track(name: "Music", clips: [Clip(sourceID: music.id, sourceStart: 9_600, start: 192_000, length: 240_000)], gainDB: -6)]
        p.markers = [Marker(position: 96_000, length: 0, name: "Scene 2")]
        p.timecode = TimecodeSettings(rate: .fps25, startFrames: 90_000)
        return p
    }
    /// Where every clip is, as (track, start, sourceStart, length, file name).
    func placement(_ p: Project) -> [[String]] {
        p.tracks.enumerated().flatMap { i, t in t.clips.map { c in [String(i), String(c.start), String(c.sourceStart), String(c.length), ((p.source(c.sourceID)?.name ?? "?") as NSString).deletingPathExtension] } }
            .sorted { $0.lexicographicallyPrecedes($1) }
    }
    func built(_ t: FCPXMLImport.Timeline, _ dir: TempDir) throws -> Project {
        try FCPXMLImport.build(t, mediaFolder: dir.url.appending(path: "media")).project
    }
    func names(_ p: Project) -> [String] { placement(p).map { $0[4] } }

    @Test("CMX 3600: written and read back, every clip on its track, at its place, from its offset, as long; the timecode kept; what an EDL can't hold said")
    func edlRoundTrip() throws {
        let dir = TempDir()
        let p = try document(dir)
        let w = try EDL.write(ExchangeTimeline(p, name: "Scene"))
        #expect(w.text.contains("TITLE: Scene") && w.text.contains("FCM: NON-DROP FRAME") && w.text.contains("001  AX       A     C        00:00:01:00 00:00:03:00 01:00:00:00 01:00:02:00"), "\(w.text.prefix(400))")
        #expect(w.text.contains("* SOURCE FILE: \(dir.file("music.wav").path)") && w.text.contains("A2   "))
        #expect(w.warnings.contains { $0 == "1 track has a level, pan or mute, which a CMX 3600 list can't hold." } && w.warnings.contains { $0.contains("Markers") } && !w.warnings.contains { $0.contains("rounded") }, "\(w.warnings)")
        let back = try built(try EDL.read(w.text, base: dir.url, name: "x"), dir)
        #expect(placement(back).map { Array($0.prefix(4)) } == placement(p).map { Array($0.prefix(4)) }, "\(placement(back))")
        #expect(back.timecode == p.timecode)
    }

    @Test("CMX 3600 as Premiere and Avid write it: reel AX with FROM CLIP NAME, black and video left out, AA on track 1, a dissolve read as a cut, 29.97 drop-frame from FCM")
    func edlVendors() throws {
        let dir = TempDir()
        _ = try document(dir)
        let text = """
        TITLE: Vendor
        FCM: DROP FRAME

        001  BL       AA/V  C        00:00:00:00 00:00:02:00 01:00:00;00 01:00:02;00
        002  AX       V     C        00:00:00:00 00:00:02:00 01:00:02;00 01:00:04;00
        * FROM CLIP NAME: picture.mov
        003  AX       AA    C        00:00:01:00 00:00:03:00 01:00:02;00 01:00:04;00
        * FROM CLIP NAME: music.wav
        004  AX       A2    C        00:00:00:00 00:00:00:00 01:00:04;00 01:00:04;00
        004  AX       A2    D    015 00:00:02:00 00:00:05:00 01:00:04;00 01:00:07;00
        * FROM CLIP NAME: voice.wav
        """
        let t = try EDL.read(text, base: dir.url, name: "x")
        #expect(t.timecode?.rate == .fps2997drop && t.tracks.map(\.lane) == [0, 1])
        #expect(t.tracks[0].clips.map(\.mediaName) == ["music.wav"] && t.tracks[1].clips.last?.mediaName == "voice.wav")
        #expect(Set(t.warnings.map(\.code)) == ["video", "black", "dissolve"])
    }

    @Test("OTIO: written and read back with gain, fades, track level and mute through Jämmer's metadata; times exact at the sample rate; the global start as the timecode")
    func otioRoundTrip() throws {
        let dir = TempDir()
        var p = try document(dir)
        p.tracks[0].clips[0].gainDB = -3
        p.tracks[0].clips[0].fadeIn = 4_800
        p.tracks[1].isMuted = true
        let w = try OTIO.write(ExchangeTimeline(p, name: "Scene"))
        let json = try #require(try JSONSerialization.jsonObject(with: w.data) as? [String: Any])
        #expect(json["OTIO_SCHEMA"] as? String == "Timeline.1")
        let text = String(decoding: w.data, as: UTF8.self)
        #expect(text.contains("\"Clip.2\"") && text.contains("\"Gap.1\"") && text.contains("\"ExternalReference.1\"") && text.contains("\"Marker.2\"") && text.contains("\"kind\" : \"Audio\""))
        let back = try built(try OTIO.read(w.data, base: dir.url, name: "x"), dir)
        #expect(placement(back) == placement(p), "\(placement(back))")
        #expect(back.tracks[0].clips[0].gainDB == -3 && back.tracks[0].clips[0].fadeIn == 4_800 && back.tracks[1].isMuted && back.tracks[1].gainDB == -6)
        #expect(back.timecode == p.timecode && back.markers.contains { $0.name == "Scene 2" && $0.position == 96_000 })
    }

    @Test("OTIO in the older form (Clip.1 with media_reference), a video track, a transition and a missing reference: the audio read, the rest said")
    func otioOlder() throws {
        let dir = TempDir()
        _ = try document(dir)
        func rt(_ v: Double, _ r: Double = 24) -> [String: Any] { ["OTIO_SCHEMA": "RationalTime.1", "value": v, "rate": r] }
        func tr(_ s: Double, _ d: Double) -> [String: Any] { ["OTIO_SCHEMA": "TimeRange.1", "start_time": rt(s), "duration": rt(d)] }
        let doc: [String: Any] = ["OTIO_SCHEMA": "Timeline.1", "name": "Old", "global_start_time": NSNull(), "tracks": [
            "OTIO_SCHEMA": "Stack.1", "children": [
                ["OTIO_SCHEMA": "Track.1", "kind": "Video", "children": [] as [Any]],
                ["OTIO_SCHEMA": "Track.1", "kind": "Audio", "name": "Dialogue", "children": [
                    ["OTIO_SCHEMA": "Gap.1", "source_range": tr(0, 24)],
                    ["OTIO_SCHEMA": "Clip.1", "name": "v", "source_range": tr(12, 48), "media_reference": ["OTIO_SCHEMA": "ExternalReference.1", "target_url": "voice.wav"]],
                    ["OTIO_SCHEMA": "Transition.1", "in_offset": rt(6), "out_offset": rt(6)],
                    ["OTIO_SCHEMA": "Clip.1", "name": "gone", "source_range": tr(0, 24), "media_reference": ["OTIO_SCHEMA": "MissingReference.1"]],
                ] as [Any]],
            ] as [Any]]]
        let t = try OTIO.read(try JSONSerialization.data(withJSONObject: doc), base: dir.url, name: "x")
        #expect(t.tracks.count == 1 && t.tracks[0].name == "Dialogue" && t.tracks[0].clips.count == 1)
        #expect(t.tracks[0].clips[0].start.seconds == 1 && t.tracks[0].clips[0].sourceStart.seconds == 0.5 && t.tracks[0].clips[0].duration.seconds == 2)
        #expect(Set(t.warnings.map(\.code)) == ["video", "transition", "missing_media"])
    }

    @Test("DAWproject: a ZIP of project.xml and metadata.xml; written and read back, every clip in place, track level and mute, fades; the files referenced, not copied")
    func dawprojectRoundTrip() throws {
        let dir = TempDir()
        var p = try document(dir)
        p.tracks[0].clips[1].fadeOut = 9_600
        p.tracks[0].isMuted = true
        let w = DAWproject.write(ExchangeTimeline(p, name: "Scene"), appVersion: "1.0")
        let entries = try Zip.entries(w.data)
        #expect(entries.map(\.name) == ["project.xml", "metadata.xml"])
        let xml = String(decoding: try Zip.read(entries[0], in: w.data, limit: 1 << 20), as: UTF8.self)
        #expect(xml.contains("<Project version=\"1.0\">") && xml.contains("timeUnit=\"seconds\"") && xml.contains("external=\"true\"") && xml.contains("role=\"master\""))
        let back = try built(try DAWproject.read(w.data, base: dir.url, name: "x", unpackTo: dir.url.appending(path: "unpacked")), dir)
        #expect(placement(back) == placement(p), "\(placement(back))")
        #expect(back.tracks[0].isMuted && back.tracks[1].gainDB == -6 && back.tracks[0].clips[1].fadeOut == 9_600)
    }

    @Test("DAWproject as another program writes it: times in beats, the audio inside the project and deflated, a warped clip left out")
    func dawprojectBeats() throws {
        let dir = TempDir()
        _ = try document(dir)
        let audio = try Data(contentsOf: dir.file("voice.wav"))
        // Deflated with Apple's Compression (raw DEFLATE, as a ZIP stores it).
        var packed = [UInt8](repeating: 0, count: audio.count + 1_024)
        let n = audio.withUnsafeBytes { compression_encode_buffer(&packed, packed.count, $0.bindMemory(to: UInt8.self).baseAddress!, audio.count, nil, COMPRESSION_ZLIB) }
        #expect(n > 0)
        let project = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Project version="1.0"><Application name="Other" version="9"/>
        <Transport><Tempo unit="bpm" value="120"/><TimeSignature numerator="4" denominator="4"/></Transport>
        <Structure><Track id="t1" name="Vox" contentType="audio"><Channel id="c1" role="regular"><Volume unit="linear" value="0.5"/></Channel></Track></Structure>
        <Arrangement><Lanes timeUnit="beats"><Lanes track="t1"><Clips>
          <Clip time="4" duration="4" playStart="1" contentTimeUnit="seconds"><Audio channels="1" sampleRate="48000" duration="10"><File path="audio/voice.wav"/></Audio></Clip>
          <Clip time="12" duration="4"><Warps contentTimeUnit="seconds"><Audio channels="1" sampleRate="48000" duration="10"><File path="audio/voice.wav"/></Audio><Warp time="0" contentTime="0"/></Warps></Clip>
        </Clips></Lanes></Lanes></Arrangement></Project>
        """
        // A ZIP with project.xml stored and the audio deflated (method 8), written here by hand.
        var zip = Zip.write([("project.xml", Data(project.utf8))])
        zip = try deflatedZip(project: Data(project.utf8), audioName: "audio/voice.wav", audio: audio, packed: Data(packed.prefix(n)))
        let t = try DAWproject.read(zip, base: dir.url, name: "x", unpackTo: dir.url.appending(path: "unpacked"))
        #expect(t.tracks.count == 1 && t.tracks[0].name == "Vox" && abs(t.tracks[0].gainDB + 6.0206) < 1e-3)
        let c = try #require(t.tracks[0].clips.first)
        #expect(c.start.seconds == 2 && c.duration.seconds == 2 && c.sourceStart.seconds == 1, "beats at 120 bpm: 4 beats is 2 s")
        #expect(try Data(contentsOf: c.media) == audio, "unpacked, byte for byte")
        #expect(t.warnings.map(\.code) == ["warped"])
    }

    func deflatedZip(project: Data, audioName: String, audio: Data, packed: Data) throws -> Data {
        var out = Data(), central = Data()
        func u16(_ v: Int, _ d: inout Data) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
        func u32(_ v: Int, _ d: inout Data) { u16(v & 0xFFFF, &d); u16((v >> 16) & 0xFFFF, &d) }
        for (name, raw, stored, method) in [("project.xml", project, project, 0), (audioName, audio, packed, 8)] {
            let n = Data(name.utf8), off = out.count, crc = Int(Zip.crc32(raw))
            u32(0x0403_4b50, &out); u16(20, &out); u16(0, &out); u16(method, &out); u16(0, &out); u16(0, &out)
            u32(crc, &out); u32(stored.count, &out); u32(raw.count, &out); u16(n.count, &out); u16(0, &out); out.append(n); out.append(stored)
            u32(0x0201_4b50, &central); u16(20, &central); u16(20, &central); u16(0, &central); u16(method, &central); u16(0, &central); u16(0, &central)
            u32(crc, &central); u32(stored.count, &central); u32(raw.count, &central); u16(n.count, &central); u16(0, &central); u16(0, &central); u16(0, &central); u16(0, &central); u32(0, &central); u32(off, &central)
            central.append(n)
        }
        let at = out.count
        out.append(central)
        u32(0x0605_4b50, &out); u16(0, &out); u16(0, &out); u16(2, &out); u16(2, &out); u32(central.count, &out); u32(at, &out); u16(0, &out)
        return out
    }

    @Test("Hostile files are refused in words: not JSON, not an OTIO timeline, not a ZIP, a damaged entry, an EDL without audio, XML with entities")
    func hostile() throws {
        let dir = TempDir()
        #expect(throws: FCPXMLImport.ImportError.self) { try OTIO.read(Data("not json".utf8), base: dir.url, name: "x") }
        #expect(throws: FCPXMLImport.ImportError.self) { try OTIO.read(Data("{\"OTIO_SCHEMA\": \"Clip.2\"}".utf8), base: dir.url, name: "x") }
        #expect(throws: FCPXMLImport.ImportError.self) { try DAWproject.read(Data("PK nothing".utf8), base: dir.url, name: "x", unpackTo: dir.url) }
        var z = Zip.write([("project.xml", Data("<Project/>".utf8))])
        z[40] ^= 0xFF
        #expect(throws: FCPXMLImport.ImportError.self) { try DAWproject.read(z, base: dir.url, name: "x", unpackTo: dir.url) }
        #expect(throws: FCPXMLImport.ImportError.self) { try EDL.read("TITLE: x\n001  AX  V  C  00:00:00:00 00:00:01:00 01:00:00:00 01:00:01:00\n", base: dir.url, name: "x") }
        let evil = Zip.write([("project.xml", Data("<?xml version=\"1.0\"?><!DOCTYPE p [<!ENTITY a \"aaaa\">]><Project>&a;</Project>".utf8))])
        #expect(throws: FCPXMLImport.ImportError.self) { try DAWproject.read(evil, base: dir.url, name: "x", unpackTo: dir.url) }
    }
}
