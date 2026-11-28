import Foundation
import Testing
@testable import JammerCore

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
}
