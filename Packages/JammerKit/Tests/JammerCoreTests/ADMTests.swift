import Foundation
import Testing
import JammerEngine
@testable import JammerCore

@Suite("ADM BWF: a bed named in chna and axml, written and read back")
struct ADMTests {
    static let sr = 48_000.0
    /// Each channel its own tone and level, so a channel in the wrong place shows.
    static func tones(channels n: Int, frames: Int) -> [Float] {
        var x = [Float](repeating: 0, count: frames * n)
        for i in 0..<frames { for c in 0..<n { x[i * n + c] = Float(sin(Double(i) * 0.013 * Double(c + 1))) * 0.05 * Float(c + 1) } }
        return x
    }
    static func write(_ x: [Float], channels: Int, to url: URL, mask: UInt32?, chunks: [(id: String, payload: Data)], encoding: WAVWriter.Encoding = .float32) throws -> SourceRef {
        var o = WAVWriter.Options(encoding: encoding, channels: channels, sampleRate: sr, channelMask: mask)
        o.foreignChunks = chunks
        let w = try WAVWriter(url: url, options: o)
        try w.write(x)
        try w.finish()
        return SourceRef(name: url.lastPathComponent, path: url.path, info: try AudioFileReader.info(at: url))
    }

    @Test("chna names every channel by its loudspeaker (the common definitions' 5.1, 7.1 with rears at ±135° and 7.1.4), axml holds one object of the layout's pack with every track; read back the same; nothing for mono, stereo or Ambisonics")
    func chunks() throws {
        let dir = TempDir()
        for (layout, pack) in [(ChannelLayout.surround51, "AP_00010003"), (.surround71, "AP_0001000f"), (.immersive714, "AP_00010017")] {
            let c = try #require(ADM.chunks(for: layout, title: "Tom & \"Jerry\" <1>"))
            #expect(c.map(\.id) == ["chna", "axml"])
            #expect(c[0].payload.count == 4 + 40 * layout.channels)
            #expect(ADM.speakers(chna: c[0].payload, channels: layout.channels) == layout.speakers, "\(layout.rawValue)")
            let xml = String(decoding: c[1].payload, as: UTF8.self)
            #expect(xml.components(separatedBy: "<audioTrackUIDRef>").count - 1 == layout.channels && xml.contains(pack) && xml.contains("Tom &amp; &quot;Jerry&quot; &lt;1&gt;"))
            let ref = try Self.write(Self.tones(channels: layout.channels, frames: 4_800), channels: layout.channels, to: dir.file("\(layout.channels).wav"), mask: layout.mask, chunks: c)
            #expect(ref.info.channelOrder == layout.speakers && ref.info.chunks.contains { $0.id == "axml" })
            #expect(Project(source: ref).layout == layout)
        }
        // 7.1's sides and rears by the common definitions (read there): sides ±90° are 0a/0b, rears ±135° 1c/1d.
        let seven = String(decoding: ADM.chunks(for: .surround71, title: "")![0].payload, as: UTF8.self)
        #expect(["AT_0001000a_01", "AT_0001000b_01", "AT_0001001c_01", "AT_0001001d_01"].allSatisfy(seven.contains))
        #expect(ADM.chunks(for: .mono, title: "") == nil && ADM.chunks(for: .stereo, title: "") == nil && ADM.chunks(for: .ambix1, title: "") == nil)
    }

    @Test("A file with no mask whose chna puts the sides before the rears (BS.2051's order, as the ITU's own files have it) plays each channel from its own loudspeaker, exactly; without chna it is read in the mask's order, as before")
    func namedOrder() throws {
        let dir = TempDir()
        // L R C LFE Lss Rss Lrs Rrs Ltf Rtf Ltr Rtr: BS.2051's 4+7+0.
        let order: [Speaker] = [.frontLeft, .frontRight, .frontCenter, .lowFrequency, .sideLeft, .sideRight, .backLeft, .backRight,
                                .topFrontLeft, .topFrontRight, .topBackLeft, .topBackRight]
        var chna = Data()
        chna.u16le(12); chna.u16le(12)
        for (k, s) in order.enumerated() {
            chna.u16le(UInt16(k + 1))
            chna.append(Data(String(format: "ATU_%08x", k + 1).utf8))
            chna.append(Data(String(format: "AT_000100%02x_01", ADM.channelFormat(s, in: .immersive714)!).utf8))
            chna.append(Data("AP_00010017".utf8)); chna.append(0)
        }
        let n = 12, frames = 4_800
        let x = Self.tones(channels: n, frames: frames)
        let named = try Self.write(x, channels: n, to: dir.file("named.wav"), mask: nil, chunks: [("chna", chna)])
        #expect(named.info.channelOrder == order)
        let p = Project(source: named)
        #expect(p.layout == .immersive714)
        let out = PlanCompiler.compile(p, pool: SourcePool()).render(from: 0, frames: frames)
        for (k, s) in order.enumerated() {
            let j = ChannelLayout.immersive714.speakers.firstIndex(of: s)!
            #expect((0..<frames).allSatisfy { out[$0 * n + j] == x[$0 * n + k] }, "\(s.short): file channel \(k + 1) to the document's \(j + 1)")
        }
        let plain = try Self.write(x, channels: n, to: dir.file("plain.wav"), mask: nil, chunks: [])
        #expect(plain.info.channelOrder == nil)
        #expect(PlanCompiler.compile(Project(source: plain), pool: SourcePool()).render(from: 0, frames: frames) == x, "no chna: as before")
        // A chna that doesn't name every channel once, or names a loudspeaker outside the layout, is not trusted.
        #expect(ADM.speakers(chna: chna, channels: 8) == nil, "a chna of 12 tracks for a file of 8 channels")
        var broken = chna; broken[4 + 40] = 1   // the second entry says it is track 1 again
        #expect(ADM.speakers(chna: broken, channels: 12) == nil)
    }

    /// The EBU's ADM renderer (`ear-render`, BSD-3-Clause-Clear), installed by Anders's leave outside the
    /// repository and pointed at with JAMMER_EAR=<path to ear-render>. It reads the file's chna and axml against
    /// the common definitions and renders the bed to the same layout: each loudspeaker's channel must come out
    /// as it went in, in BS.2051's order (which puts 7.1's sides before its rears).
    @Test("The EBU's renderer reads Jämmer's ADM BWF and renders each bed to its own layout channel for channel", .enabled(if: ProcessInfo.processInfo.environment["JAMMER_EAR"] != nil))
    func ear() throws {
        let tool = ProcessInfo.processInfo.environment["JAMMER_EAR"]!
        let dir = TempDir()
        for (layout, system) in [(ChannelLayout.surround51, "0+5+0"), (.surround71, "0+7+0"), (.immersive714, "4+7+0")] {
            let n = layout.channels, frames = 9_600
            let x = Self.tones(channels: n, frames: frames)
            let ref = try Self.write(x, channels: n, to: dir.file("in\(n).wav"), mask: layout.mask, chunks: ADM.chunks(for: layout, title: "ear")!, encoding: .int24)
            let out = dir.file("out\(n).wav")
            let r = try run(tool, ["--strict", "-s", system, ref.path, out.path])
            #expect(r.status == 0, "\(system): \(r.output.suffix(600))")
            guard r.status == 0 else { continue }
            let rendered = SourceRef(name: "out", path: out.path, info: try AudioFileReader.info(at: out))
            #expect(rendered.info.channels == n)
            let s = try #require(AudioFileReader.openSource(rendered.info, at: out))
            defer { jm_source_release(s) }
            var y = [Float](repeating: 0, count: Int(rendered.info.frames) * n)
            _ = jm_source_read(s, 0, rendered.info.frames, &y)
            let input = try #require(AudioFileReader.openSource(ref.info, at: URL(fileURLWithPath: ref.path)))
            defer { jm_source_release(input) }
            var xin = [Float](repeating: 0, count: frames * n)
            _ = jm_source_read(input, 0, Int64(frames), &xin)
            // BS.2051's order for these systems: sides (±90°, or 5.1's ±110°) before rears.
            let bs2051: [Speaker] = layout == .surround51 ? layout.speakers
                : [.frontLeft, .frontRight, .frontCenter, .lowFrequency, .sideLeft, .sideRight, .backLeft, .backRight] + (n == 12 ? [.topFrontLeft, .topFrontRight, .topBackLeft, .topBackRight] : [])
            var worst = 0.0
            for (k, sp) in bs2051.enumerated() {
                let j = layout.speakers.firstIndex(of: sp)!
                for i in 0..<min(frames, Int(rendered.info.frames)) { worst = max(worst, Double(abs(y[i * n + k] - xin[i * n + j]))) }
            }
            print("EAR \(system): worst difference \(worst)")
            #expect(worst < 1e-4, "\(system): \(worst)")
        }
    }
}
