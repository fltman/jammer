import Foundation
import JammerEngine
import Testing
@testable import JammerCore

@Suite("Immersive: documents wider than stereo")
struct ImmersiveTests {
    let sr = 48_000.0

    /// A file whose every channel has its own tone, so where each one lands can be read back.
    func file(_ dir: TempDir, _ name: String, channels: Int, mask: UInt32? = nil, frames: Int = 9_600) throws -> SourceRef {
        var x = [Float](repeating: 0, count: frames * channels)
        for i in 0..<frames { for c in 0..<channels { x[i * channels + c] = Float(sin(Double(i) * 0.01 * Double(c + 1))) * 0.1 * Float(c + 1) } }
        let url = dir.file(name)
        let w = try WAVWriter(url: url, options: .init(encoding: .float32, channels: channels, sampleRate: sr, channelMask: mask))
        try w.write(x)
        try w.finish()
        return SourceRef(name: name, path: url.path, info: try AudioFileReader.info(at: url))
    }
    func samples(_ ref: SourceRef) throws -> [Float] {
        let s = try #require(AudioFileReader.openSource(ref.info, at: URL(fileURLWithPath: ref.path)))
        defer { jm_source_release(s) }
        var out = [Float](repeating: 0, count: Int(ref.info.frames) * ref.info.channels)
        _ = jm_source_read(s, 0, ref.info.frames, &out)
        return out
    }
    func channel(_ x: [Float], _ c: Int, of n: Int) -> [Float] { stride(from: c, to: x.count, by: n).map { x[$0] } }

    @Test("Layouts: their loudspeakers in WAV order, their masks, and a file's layout from its mask or its count")
    func layouts() {
        #expect(ChannelLayout.surround51.speakers.map(\.short) == ["L", "R", "C", "LFE", "Lss", "Rss"] && ChannelLayout.surround51.mask == 0x60F)
        #expect(ChannelLayout.surround71.mask == 0x63F && ChannelLayout.immersive714.mask == 0x2D63F && ChannelLayout.immersive714.channels == 12)
        #expect(ChannelLayout.stereo.mask == nil && ChannelLayout.mono.mask == nil)
        // The mask's bits in rising order are the channels' order.
        for l in ChannelLayout.allCases { #expect(l.speakers.map(\.rawValue) == l.speakers.map(\.rawValue).sorted(), "\(l.rawValue)") }
        #expect(ChannelLayout.of(channels: 6, mask: 0x3F) == .surround51 && ChannelLayout.of(channels: 6, mask: 0x60F) == .surround51)
        #expect(ChannelLayout.of(channels: 6, mask: nil) == .surround51 && ChannelLayout.of(channels: 12, mask: 0x2D63F) == .immersive714)
        #expect(ChannelLayout.of(channels: 4, mask: 0x33) == nil && ChannelLayout.of(channels: 6, mask: 0x3F3) == nil && ChannelLayout.of(channels: 2, mask: 0x3) == .stereo)
    }

    @Test("A 5.1 file opens as a 5.1 document and plays channel for channel, exactly; saved as format 4 and read back; a document of 4 channels is refused")
    func fivePointOne() throws {
        let dir = TempDir()
        let src = try file(dir, "six.wav", channels: 6, mask: 0x3F)
        let p = Project(source: src)
        #expect(p.channels == 6 && p.layout == .surround51)
        let pool = SourcePool()
        let out = PlanCompiler.compile(p, pool: pool).render(from: 0, frames: 9_600)
        let original = try samples(src)
        #expect(out == original, "a 5.1 file in a 5.1 document nulls")
        let data = try JSONEncoder().encode(p)
        #expect((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["formatVersion"] as? Int == 4)
        #expect(try JSONDecoder().decode(Project.self, from: data) == p)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["channels"] = 4
        #expect(throws: (any Error).self) { try JSONDecoder().decode(Project.self, from: try JSONSerialization.data(withJSONObject: object)) }
        // A stereo document is saved as before.
        let stereo = Project(source: try file(dir, "two.wav", channels: 2))
        #expect((try JSONSerialization.jsonObject(with: try JSONEncoder().encode(stereo)) as? [String: Any])?["formatVersion"] as? Int == 1)
    }

    @Test("Into a 5.1 document a mono voice goes to the centre only and a stereo pair to L and R, sample for sample; stereo and mono documents are as they were")
    func intoSurround() throws {
        let dir = TempDir()
        var p = Project(source: try file(dir, "six.wav", channels: 6))
        let voice = try file(dir, "voice.wav", channels: 1), music = try file(dir, "music.wav", channels: 2)
        p.sources += [voice, music]
        p.tracks = [Track(name: "Voice", clips: [Clip(sourceID: voice.id, start: 0, length: 9_600)]),
                    Track(name: "Music", clips: [Clip(sourceID: music.id, start: 0, length: 9_600)])]
        let out = PlanCompiler.compile(p, pool: SourcePool()).render(from: 0, frames: 9_600)
        let v = try samples(voice), m = try samples(music)
        #expect(channel(out, 0, of: 6) == channel(m, 0, of: 2) && channel(out, 1, of: 6) == channel(m, 1, of: 2))
        #expect(channel(out, 2, of: 6) == v)
        #expect([3, 4, 5].allSatisfy { channel(out, $0, of: 6).allSatisfy { $0 == 0 } }, "nothing in the LFE or the surrounds")
        // The same sources in a stereo document: mono in both channels, stereo as it is (the old way).
        var s = p
        s.channels = 2
        let st = PlanCompiler.compile(s, pool: SourcePool()).render(from: 0, frames: 9_600)
        for i in 0..<9_600 {
            #expect(st[i * 2] == v[i] + m[i * 2] && st[i * 2 + 1] == v[i] + m[i * 2 + 1])
            if st[i * 2] != v[i] + m[i * 2] { break }
        }
    }

    @Test("Pan in a 5.1 document is refused with words that say so (not that the document is mono), and pan automation too")
    func panInSurround() throws {
        let dir = TempDir()
        var p = Project(source: try file(dir, "six.wav", channels: 6))
        let track = p.tracks[0].id
        #expect(throws: Mixer.Failure.wide("5.1")) { try p.setTrackRoute(track, pan: 0.5) }
        #expect(Mixer.Failure.wide("5.1").errorDescription?.contains("this one is 5.1") == true)
        #expect(throws: Automation.Failure.wide("5.1")) { try p.setAutomation(strip: track, param: .pan, points: [AutomationPoint(frame: 0, value: 0.3)]) }
        // Centre pan is not a pan, and passes.
        #expect(throws: Never.self) { try p.setTrackRoute(track, pan: 0) }
    }

    static func tones(channels: Int, seconds: Double = 20, dbfs: [Int: Double]) -> [Float] {
        let n = Int(48_000 * seconds)
        var x = [Float](repeating: 0, count: n * channels)
        for (c, db) in dbfs {
            let a = pow(10, db / 20)
            for i in 0..<n { x[i * channels + c] = Float(a * sin(2 * Double.pi * 1_000 * Double(i) / 48_000)) }
        }
        return x
    }
    static func integrated(_ x: [Float], channels: Int) -> Double {
        var m = LoudnessMeter(sampleRate: 48_000, channels: channels)
        m.process(x)
        return m.result.integrated ?? -99
    }

    @Test("EBU Tech 3341 case 6, made here from its definition: a 5.0 sine at 1 kHz, −28 dBFS in L and R, −24 in C, −30 in Ls and Rs, measures −23.0 ±0.1 LUFS (the LFE silent)")
    func ebuCase6() {
        let x = Self.tones(channels: 6, dbfs: [0: -28, 1: -28, 2: -24, 4: -30, 5: -30])
        let i = Self.integrated(x, channels: 6)
        #expect(abs(i + 23) <= 0.1, "\(i)")
    }

    @Test("BS.1770-5's weights by place: a tone in a side channel reads 1.49 dB louder than in a front one, a rear or a height channel the same as a front one, the LFE not at all; in 5.1, 7.1 and 7.1.4")
    func weightsByPlace() {
        for layout in [ChannelLayout.surround51, .surround71, .immersive714] {
            let n = layout.channels
            let front = Self.integrated(Self.tones(channels: n, seconds: 4, dbfs: [0: -20]), channels: n)
            for (c, speaker) in layout.speakers.enumerated() {
                let x = Self.tones(channels: n, seconds: 4, dbfs: [c: -20])
                var m = LoudnessMeter(sampleRate: 48_000, channels: n)
                m.process(x)
                let i = m.result.integrated
                switch speaker {
                case .lowFrequency: #expect(i == nil, "\(layout.rawValue): the LFE is not measured")
                case .sideLeft, .sideRight: #expect(abs((i ?? -99) - front - 10 * log10(1.41)) < 0.01, "\(layout.rawValue) \(speaker.short): \(i ?? -99) against \(front)")
                default: #expect(abs((i ?? -99) - front) < 0.01, "\(layout.rawValue) \(speaker.short): \(i ?? -99) against \(front)")
                }
            }
        }
    }

    @Test("A 5.1 programme agrees with ffmpeg's ebur128 (which weights 5.1 as BS.1770-5 does)", .enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg")))
    func ffmpegFivePointOne() throws {
        let dir = TempDir()
        let n = 48_000 * 12
        let white = noise(count: n * 6, seed: 9)
        var x = [Float](repeating: 0, count: n * 6)
        for i in 0..<n {
            let env = Float(0.1 + 0.2 * (0.5 + 0.5 * sin(Double(i) / 48_000 * 2 * .pi / 5)))
            for c in 0..<6 { x[i * 6 + c] = white[i * 6 + c] * env * [0.8, 0.7, 1.0, 0.9, 0.5, 0.6][c] }
        }
        let url = dir.file("six.wav")
        let w = try WAVWriter(url: url, options: .init(encoding: .float32, channels: 6, sampleRate: 48_000, channelMask: 0x60F))
        try w.write(x)
        try w.finish()
        let ours = Self.integrated(x, channels: 6)
        let ff = try run("/opt/homebrew/bin/ffmpeg", ["-nostats", "-hide_banner", "-i", url.path, "-af", "ebur128", "-f", "null", "-"])
        let summary = try #require(ff.output.range(of: "Summary:"))
        let tail = ff.output[summary.upperBound...]
        let r = try #require(tail.range(of: "I:"))
        let theirs = try #require(Double(tail[r.upperBound...].trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? ""))
        #expect(abs(ours - theirs) <= 0.15, "ours \(ours), ffmpeg \(theirs)")
    }

    @Test("Fold-downs: 5.1 into stereo by BS.775 (C and the surrounds at 0.7071, no LFE) and into mono; 7.1 into 5.1 by IAMF mode 2; 7.1.4 into stereo through every step; a narrower source into a wider document stays on its loudspeakers")
    func foldDowns() {
        let k: Float = 0.7071
        func g(_ s: ChannelLayout, _ d: ChannelLayout, _ a: Speaker, _ b: Speaker) -> Float {
            ChannelLayout.gains(from: s, to: d)[s.speakers.firstIndex(of: a)! * d.channels + d.speakers.firstIndex(of: b)!]
        }
        #expect(g(.surround51, .stereo, .frontLeft, .frontLeft) == 1 && g(.surround51, .stereo, .frontCenter, .frontLeft) == k && g(.surround51, .stereo, .frontCenter, .frontRight) == k)
        #expect(g(.surround51, .stereo, .sideLeft, .frontLeft) == k && g(.surround51, .stereo, .sideLeft, .frontRight) == 0 && g(.surround51, .stereo, .lowFrequency, .frontLeft) == 0)
        #expect(g(.surround51, .mono, .frontLeft, .frontCenter) == k && g(.surround51, .mono, .frontCenter, .frontCenter) == 1 && g(.surround51, .mono, .sideRight, .frontCenter) == 0.5)
        #expect(g(.surround71, .surround51, .backLeft, .sideLeft) == k && g(.surround71, .surround51, .sideLeft, .sideLeft) == k && g(.surround71, .surround51, .lowFrequency, .lowFrequency) == 1)
        // Through every step: a top rear goes 7.1.4 → 7.1 rear (0.7071) → 5.1 surround (0.707) → stereo left (0.7071).
        #expect(abs(g(.immersive714, .stereo, .topBackLeft, .frontLeft) - k * k * k) < 1e-6 && g(.immersive714, .stereo, .topBackLeft, .frontRight) == 0)
        #expect(abs(g(.immersive714, .stereo, .topFrontRight, .frontRight) - k) < 1e-6 && g(.immersive714, .stereo, .lowFrequency, .frontLeft) == 0)
        // Narrower into wider: on their own loudspeakers.
        #expect(g(.surround51, .immersive714, .sideLeft, .sideLeft) == 1 && g(.stereo, .surround71, .frontRight, .frontRight) == 1)
        #expect(ChannelLayout.gains(from: .mono, to: .stereo) == [1, 1])
    }

    @Test("A 5.1 file in a stereo document is heard folded down: L′ = L + 0.7071 C + 0.7071 Ls, within float rounding")
    func fiveOneInStereo() throws {
        let dir = TempDir()
        let six = try file(dir, "six.wav", channels: 6), two = try file(dir, "two.wav", channels: 2)
        var p = Project(source: two)
        p.sources.append(six)
        p.tracks = [Track(name: "Six", clips: [Clip(sourceID: six.id, start: 0, length: 9_600)])]
        let out = PlanCompiler.compile(p, pool: SourcePool()).render(from: 0, frames: 9_600)
        let x = try samples(six)
        var worst: Float = 0
        for i in 0..<9_600 {
            let f = Array(x[(i * 6)..<(i * 6 + 6)])
            worst = max(worst, abs(out[i * 2] - (f[0] + 0.7071 * f[2] + 0.7071 * f[4])), abs(out[i * 2 + 1] - (f[1] + 0.7071 * f[2] + 0.7071 * f[5])))
        }
        #expect(worst < 1e-6, "\(worst)")
    }

    @Test("The panner: on a loudspeaker's own direction only that loudspeaker; between two, both at constant power; the LFE never; heights by elevation; a default place gives the old routing exactly")
    func panner() {
        let five = ChannelLayout.surround51
        func power(_ g: [Float]) -> Float { g.reduce(0) { $0 + $1 * $1 } }
        #expect(Panner.gains(azimuth: 0, elevation: 0, in: five) == [0, 0, 1, 0, 0, 0])
        #expect(Panner.gains(azimuth: 30, elevation: 0, in: five) == [1, 0, 0, 0, 0, 0])
        #expect(Panner.gains(azimuth: 110, elevation: 0, in: five) == [0, 0, 0, 0, 1, 0])
        #expect(Panner.gains(azimuth: -110, elevation: 0, in: five) == [0, 0, 0, 0, 0, 1])
        // Halfway between L (30°) and Ls (110°): both, equal, at constant power; nothing elsewhere.
        let mid = Panner.gains(azimuth: 70, elevation: 0, in: five)
        #expect(abs(mid[0] - mid[4]) < 1e-5 && abs(power(mid) - 1) < 1e-5 && mid[1] == 0 && mid[2] == 0 && mid[3] == 0 && mid[5] == 0)
        // Behind, between the surrounds; and every direction keeps constant power and leaves the LFE alone.
        let back = Panner.gains(azimuth: 180, elevation: 0, in: five)
        #expect(abs(back[4] - back[5]) < 1e-5 && back[4] > 0)
        for a in stride(from: -180.0, through: 180, by: 7.5) {
            for layout in [ChannelLayout.surround51, .surround71, .immersive714] {
                let g = Panner.gains(azimuth: a, elevation: 0, in: layout)
                #expect(abs(power(g) - 1) < 1e-4 && g[3] == 0, "\(layout.rawValue) at \(a)")
            }
        }
        // Heights: at 30° up only the height layer, halfway between both, above 30° it stays.
        let top = ChannelLayout.immersive714
        #expect(Panner.gains(azimuth: 45, elevation: 30, in: top) == Panner.gains(azimuth: 45, elevation: 70, in: top))
        let up = Panner.gains(azimuth: 45, elevation: 30, in: top)
        #expect(up[8] == 1 && up.enumerated().allSatisfy { $0.offset == 8 || $0.element == 0 })
        let half = Panner.gains(azimuth: 135, elevation: 15, in: top)
        #expect(abs(half[4] - half[10]) < 1e-5 && abs(power(half) - 1) < 1e-5)
        // The default place: a mono source in C, a stereo source in L and R, exactly as the old routing.
        #expect(Panner.matrix(SurroundPosition(), sourceChannels: 1, in: five) == ChannelLayout.gains(from: .mono, to: five))
        #expect(Panner.matrix(SurroundPosition(), sourceChannels: 2, in: five) == ChannelLayout.gains(from: .stereo, to: five))
    }

    @Test("A track placed at the left surround plays its voice there and nowhere else; refused in a stereo document; out of range refused; placed: false takes it back; saved and read back")
    func placedTrack() throws {
        let dir = TempDir()
        var p = Project(source: try file(dir, "six.wav", channels: 6))
        let voice = try file(dir, "voice.wav", channels: 1)
        p.sources.append(voice)
        p.tracks = [Track(name: "Voice", clips: [Clip(sourceID: voice.id, start: 0, length: 9_600)])]
        let id = p.tracks[0].id
        try p.setTrackPosition(id, azimuth: 110)
        let out = PlanCompiler.compile(p, pool: SourcePool()).render(from: 0, frames: 9_600)
        let v = try samples(voice)
        #expect(channel(out, 4, of: 6) == v && [0, 1, 2, 3, 5].allSatisfy { channel(out, $0, of: 6).allSatisfy { $0 == 0 } })
        #expect(try JSONDecoder().decode(Project.self, from: try JSONEncoder().encode(p)).tracks[0].position == SurroundPosition(azimuth: 110))
        #expect(throws: Mixer.Failure.self) { try p.setTrackPosition(id, elevation: 120) }
        try p.setTrackPosition(id, placed: false)
        #expect(p.tracks[0].position == nil)
        var s = p
        s.channels = 2
        #expect(throws: Mixer.Failure.narrow("stereo")) { try s.setTrackPosition(id, azimuth: 30) }
    }
}
