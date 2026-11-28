import Foundation
import Testing
@testable import JammerCore
import JammerEngine

/// ADM objects as ITU-R BS.2076-3 lays them out (§ 5.3–5.6, 5.13, 6, 7, 8, Annex 2 § 3): placed tracks as objects
/// with their place over time, the XML's structure, and read back.
@Suite("ADM objects: placed tracks, their place over time, the XML, and read back")
struct ADMObjectsTests {
    static let rate = 48_000.0

    /// A 5.1 document of ten seconds: a mono voice placed at 30° left, a stereo pair placed at the centre, and one
    /// track left to the bed.
    func document() -> Project {
        func ref(_ name: String, channels: Int) -> SourceRef {
            SourceRef(name: name, path: "/dev/null", info: AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: channels,
                                                                       sampleRate: Self.rate, channelMask: nil, dataOffset: 0, frames: 480_000, chunks: [],
                                                                       bext: nil, ixml: nil, markers: []))
        }
        var p = Project(source: ref("voice", channels: 1))
        p.channels = 6
        _ = p.addTrack(source: ref("pair", channels: 2), name: "Pair")
        _ = p.addTrack(source: ref("bed", channels: 6), name: "Bed")
        p.tracks[0].name = "Voice & \"you\""
        p.tracks[0].position = SurroundPosition(azimuth: 30, elevation: 10)
        p.tracks[1].position = SurroundPosition(azimuth: 0, elevation: 0, width: 60)
        return p
    }

    @Test("Which tracks are objects: placed, mono or stereo, in a loudspeaker layout; a stereo track is two, at ± half its width")
    func which() {
        let p = document()
        let o = ADMObjects.objects(p, range: 0..<p.length)
        #expect(o.map(\.name) == ["Voice & \"you\"", "Pair L", "Pair R"])
        #expect(o[0].blocks == [ADMObjects.Block(start: nil, duration: nil, azimuth: 30, elevation: 10)], "a place that doesn't move is one block")
        #expect(o[1].blocks[0].azimuth == 30 && o[2].blocks[0].azimuth == -30, "the pair's left at +30 (left is positive), its right at −30")
        var stereo = p
        stereo.channels = 2
        #expect(ADMObjects.objects(stereo, range: 0..<stereo.length).isEmpty, "stereo has no bed, so no objects")
    }

    @Test("A place over time: a block per stretch between points, at its end's place; a held lane jumps at the block's start")
    func overTime() {
        var p = document()
        let id = p.tracks[0].id
        p.automation = [AutomationLane(strip: id, param: .azimuth, points: [.init(frame: 48_000, value: 30), .init(frame: 144_000, value: -30)])]
        var o = ADMObjects.objects(p, range: 0..<p.length)[0]
        #expect(o.blocks.map(\.start) == [0, 48_000, 144_000] && o.blocks.map(\.duration) == [48_000, 96_000, 336_000])
        #expect(o.blocks.map(\.azimuth) == [30, -30, -30], "each block's place is where it is at its end")
        #expect(o.blocks.allSatisfy { !$0.jump && $0.elevation == 10 })
        p.automation[0].shape = .hold
        o = ADMObjects.objects(p, range: 0..<p.length)[0]
        #expect(o.blocks.map(\.azimuth) == [30, 30, -30] && o.blocks.allSatisfy(\.jump), "held: the value from the block's start, jumped to")
        // From a range that starts at 1 s: block times are the file's, from 0.
        let later = ADMObjects.objects(p, range: 48_000..<p.length)[0]
        #expect(later.blocks.first?.start == 0)
        #expect(ADMObjects.wrapped(190) == -170 && ADMObjects.wrapped(-190) == 170 && ADMObjects.wrapped(180) == 180 && ADMObjects.wrapped(-30) == -30)
    }

    @Test("The XML has BS.2076-3's structure: the bed and an object each, custom IDs from 1001, Objects (0003), polar places, exact times")
    func structure() throws {
        var p = document()
        p.automation = [AutomationLane(strip: p.tracks[0].id, param: .azimuth, points: [.init(frame: 48_000, value: 30), .init(frame: 144_000, value: -30)])]
        let objects = ADMObjects.objects(p, range: 0..<p.length)
        let chunks = try #require(ADMObjects.chunks(bed: .surround51, objects: objects, title: "Scene", rate: Self.rate))
        let axml = try #require(chunks.first { $0.id == "axml" }?.payload), chna = try #require(chunks.first { $0.id == "chna" }?.payload)
        let doc = try XMLDocument(data: axml)
        func count(_ x: String) throws -> Int { try doc.nodes(forXPath: x).count }
        #expect(try count("//*[local-name()='audioObject']") == 4, "the bed and three objects")
        #expect(try count("//*[local-name()='audioContent']/*[local-name()='audioObjectIDRef']") == 4)
        #expect(try count("//*[local-name()='audioChannelFormat'][@typeLabel='0003'][@typeDefinition='Objects']") == 3)
        #expect(try count("//*[local-name()='audioPackFormat'][@audioPackFormatID='AP_00031001']") == 1, "custom IDs start at 1001 (§ 6)")
        #expect(try count("//*[local-name()='audioBlockFormat'][@audioBlockFormatID='AB_00031001_00000001'][@rtime='00:00:00.00000S48000'][@duration='00:00:01.00000S48000']") == 1)
        #expect(try count("//*[local-name()='audioBlockFormat'][@audioBlockFormatID='AB_00031001_00000003'][@rtime='00:00:03.00000S48000']") == 1)
        #expect(try count("//*[local-name()='position'][@coordinate='azimuth']") == 5)
        #expect(try count("//*[local-name()='audioTrackUID']") == 9, "six bed tracks and three objects")
        let names = try doc.nodes(forXPath: "//*[local-name()='audioObject']/@audioObjectName").compactMap(\.stringValue)
        #expect(names.contains("Voice & \"you\""), "the name escaped, read back whole: \(names)")
        // chna (§ 7): one entry a track; an object's track and pack refs.
        let b = [UInt8](chna)
        #expect(Int(b[0]) | Int(b[1]) << 8 == 9)
        let seventh = 4 + 40 * 6
        #expect(String(decoding: b[seventh + 14..<seventh + 28], as: UTF8.self) == "AT_00031001_01")
        #expect(String(decoding: b[seventh + 28..<seventh + 39], as: UTF8.self) == "AP_00031001")
        #expect(ADMObjects.chunks(bed: .stereo, objects: objects, title: "x", rate: Self.rate) == nil && ADMObjects.chunks(bed: .surround51, objects: [], title: "x", rate: Self.rate) == nil)
    }

    @Test("Read back: each object's name, its track in the file and its blocks as written")
    func readBack() throws {
        var p = document()
        p.automation = [AutomationLane(strip: p.tracks[0].id, param: .azimuth, points: [.init(frame: 48_000, value: 30), .init(frame: 144_000, value: -30)])]
        let objects = ADMObjects.objects(p, range: 0..<p.length)
        let chunks = try #require(ADMObjects.chunks(bed: .surround51, objects: objects, title: "Scene", rate: Self.rate))
        let read = ADMObjects.read(axml: chunks[1].payload, chna: chunks[0].payload, rate: Self.rate)
        #expect(read.map(\.name) == objects.map(\.name))
        #expect(read.map(\.track) == [7, 8, 9], "after the bed's six")
        for (r, o) in zip(read, objects) {
            #expect(r.blocks.count == o.blocks.count)
            for (x, y) in zip(r.blocks, o.blocks) {
                #expect(x.start == y.start && x.duration == y.duration && abs(x.azimuth - y.azimuth) < 1e-3 && abs(x.elevation - y.elevation) < 1e-3)
            }
        }
        #expect(ADMObjects.frames("00:00:01.50000", rate: 48_000) == 72_000 && ADMObjects.frames("00:01:00.24000S48000", rate: 48_000) == 2_904_000)
        #expect(ADMObjects.read(axml: Data("not xml".utf8), rate: 48_000).isEmpty)
    }

    /// A 5.1 document whose sources are in memory: a voice (440 Hz) placed at 30° left, and a hum (100 Hz) left to the bed.
    func rendered() throws -> (Project, SourcePool) {
        let n = 48_000
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 1, sampleRate: Self.rate,
                                 channelMask: nil, dataOffset: 0, frames: Int64(n), chunks: [], bext: nil, ixml: nil, markers: [])
        let pool = SourcePool()
        let voice = SourceRef(name: "voice", path: "/dev/null", info: info), hum = SourceRef(name: "hum", path: "/dev/null", info: info)
        pool.register(voice.id, memory: (0..<n).map { Float(0.1 * sin(2 * .pi * 440 * Double($0) / Self.rate)) }, channels: 1)
        pool.register(hum.id, memory: (0..<n).map { Float(0.1 * sin(2 * .pi * 100 * Double($0) / Self.rate)) }, channels: 1)
        var p = Project(source: voice)
        p.channels = 6
        _ = p.addTrack(source: hum, name: "Hum")
        p.tracks[0].position = SurroundPosition(azimuth: 30)
        return (p, pool)
    }

    @Test("The file's sound: the object is the voice after its fader, the bed is everything else, and a send still reaches the bed")
    func sound() throws {
        let (p, pool) = try rendered()
        let frames = Int(p.length)
        let object = try #require(ADMObjects.objectProject(p, track: p.tracks[0].id))
        #expect(object.channels == 1)
        let voice = PlanCompiler.compile(object, pool: pool).render(from: 0, frames: frames)
        let source = pool.read(p.sources[0], from: 0, count: frames)
        #expect(zip(voice, source).allSatisfy { abs($0 - $1) < 1e-6 }, "the object is the voice itself, not panned")
        // The bed: the hum alone, as the document without the voice would be.
        let bed = PlanCompiler.compile(ADMObjects.bedProject(p), pool: pool).render(from: 0, frames: frames)
        var humOnly = p
        humOnly.tracks.remove(at: 0)
        let expected = PlanCompiler.compile(humOnly, pool: pool).render(from: 0, frames: frames)
        #expect(bed.count == expected.count && zip(bed, expected).allSatisfy { abs($0 - $1) < 1e-6 }, "the voice's direct sound isn't in the bed")
        // With a send to a bus, its share is in the bed.
        var sent = p
        let bus = try sent.addBus(name: "Room")
        sent.tracks[0].sends = [Send(to: bus.id, gainDB: -6)]
        let bedSent = PlanCompiler.compile(ADMObjects.bedProject(sent), pool: pool).render(from: 0, frames: frames)
        let extra = zip(bedSent, expected).map { abs($0 - $1) }.max() ?? 0
        #expect(extra > 0.01, "the send's share of the voice reaches the bed (\(extra))")
        // Interleaved: six bed channels, then the object.
        let file = ADMObjects.interleave(bed: bed, bedChannels: 6, objects: [voice], objectChannels: [1])
        #expect(file.count == frames * 7)
        #expect((0..<frames).allSatisfy { f in file[f * 7 + 6] == voice[f] && file[f * 7 + 2] == bed[f * 6 + 2] })
    }

    @Test("Written as the export writes it and read back by Jämmer: seven channels, the objects as written, the voice in its own channel")
    func fileRoundTrip() throws {
        var (p, pool) = try rendered()
        p.automation = [AutomationLane(strip: p.tracks[0].id, param: .azimuth, points: [.init(frame: 12_000, value: 30), .init(frame: 36_000, value: 110)])]
        let range: Range<Frame> = 0..<p.length, frames = Int(p.length)
        let objects = ADMObjects.objects(p, range: range)
        let dir = FileManager.default.temporaryDirectory.appending(path: "jammer-adm-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "objects.wav")
        var options = WAVWriter.Options(encoding: .float32, channels: 7, sampleRate: Self.rate, channelMask: p.layout.mask)
        options.foreignChunks = try #require(ADMObjects.chunks(bed: .surround51, objects: objects, title: "Scene", rate: Self.rate))
        let w = try WAVWriter(url: url, options: options)
        let voice = PlanCompiler.compile(try #require(ADMObjects.objectProject(p, track: p.tracks[0].id)), pool: pool).render(from: 0, frames: frames)
        try w.write(ADMObjects.interleave(bed: PlanCompiler.compile(ADMObjects.bedProject(p), pool: pool).render(from: 0, frames: frames), bedChannels: 6,
                                          objects: [voice], objectChannels: [1]))
        try w.finish()

        let info = try AudioFileReader.info(at: url)
        #expect(info.channels == 7 && info.frames == Int64(frames))
        let read = try AudioFileReader.admObjects(at: url)
        #expect(read.count == 1 && read[0].name == "voice" && read[0].track == 7)
        #expect(read[0].blocks.map(\.start) == objects[0].blocks.map(\.start) && read[0].blocks.map(\.azimuth) == [30, 110, 110])
        // The seventh channel is the voice, as rendered.
        let src = AudioFileReader.openSource(info, at: url)
        defer { if let src { jm_source_release(src) } }
        var all = [Float](repeating: 0, count: frames * 7)
        _ = jm_source_read(try #require(src), 0, Int64(frames), &all)
        #expect((0..<frames).allSatisfy { abs(all[$0 * 7 + 6] - voice[$0]) < 1e-6 })
    }
}
