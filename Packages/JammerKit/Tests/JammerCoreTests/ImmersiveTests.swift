import AVFoundation
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

    @Test("A 5.1 file opens as a 5.1 document and plays channel for channel, exactly; saved as format 4 and read back; a document of 5 channels (no layout) is refused")
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
        object["channels"] = 5
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

    @Test("APAC: a 5.1 and a 7.1.4 document written as APAC in MP4 and decoded again by Apple's decoder keep their channel count and their layout, and each channel's tone is loudest in its own channel")
    func apac() throws {
        for layout in [ChannelLayout.surround51, .immersive714] {
            let dir = TempDir()
            let n = layout.channels, frames = 48_000 * 3
            // A different tone in each channel but the LFE (low and quiet there).
            var x = [Float](repeating: 0, count: frames * n)
            for i in 0..<frames { for c in 0..<n {
                let f = layout.speakers[c] == .lowFrequency ? 60.0 : 300.0 + 170.0 * Double(c)
                x[i * n + c] = Float(0.2 * sin(2 * .pi * f * Double(i) / 48_000))
            } }
            let src = dir.file("src.wav")
            let w = try WAVWriter(url: src, options: .init(encoding: .float32, channels: n, sampleRate: 48_000, channelMask: layout.mask))
            try w.write(x)
            try w.finish()
            let p = Project(source: SourceRef(name: "src", path: src.path, info: try AudioFileReader.info(at: src)))
            #expect(p.layout == layout)
            let out = dir.file("out.mp4")
            try APACWriter.export(PlanCompiler.compile(p, pool: SourcePool()), range: 0..<p.length, to: out)
            let file = try AVAudioFile(forReading: out)
            #expect(Int(file.processingFormat.channelCount) == n, "\(layout.rawValue): \(file.processingFormat.channelCount) channels")
            #expect(file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatAPAC)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let got = Int(buffer.frameLength)
            #expect(got > frames / 2)
            // Each channel holds its own tone: correlate every decoded channel with every source tone.
            for c in 0..<n where layout.speakers[c] != .lowFrequency {
                let data = buffer.floatChannelData![c]
                var best = -1, bestE = 0.0
                for k in 0..<n where layout.speakers[k] != .lowFrequency {
                    let f = 300.0 + 170.0 * Double(k)
                    var re = 0.0, im = 0.0
                    for i in stride(from: 4_800, to: min(got, frames) - 4_800, by: 1) {
                        let v = Double(data[i]); let a = 2 * .pi * f * Double(i) / 48_000
                        re += v * cos(a); im += v * sin(a)
                    }
                    let e = re * re + im * im
                    if e > bestE { bestE = e; best = k }
                }
                #expect(best == c, "\(layout.rawValue): channel \(c) (\(layout.speakers[c].short)) holds the tone of channel \(best)")
            }
        }
    }

    @Test("The waveform shows a clip where it is heard: in 5.1 a voice in C only, a placed voice at Ls only, a 5.1 file in its six rows; in stereo as before")
    func waveformWhereHeard() throws {
        let dir = TempDir()
        var p = Project(source: try file(dir, "six.wav", channels: 6))
        let voice = try file(dir, "voice.wav", channels: 1)
        p.sources.append(voice)
        p.tracks.append(Track(name: "Voice", clips: [Clip(sourceID: voice.id, start: 0, length: 9_600)]))
        func rows(_ track: Int) -> [Bool] {
            Waveform.columns(p, track: track, start: 0, framesPerColumn: 960, count: 10, peaks: [:], pool: SourcePool()).map { $0.contains { $0 != .empty && $0.max > 0.001 } }
        }
        #expect(rows(1) == [false, false, true, false, false, false], "a voice in C")
        #expect(rows(0).filter { $0 }.count == 6, "the 5.1 file in its six rows")
        try p.setTrackPosition(p.tracks[1].id, azimuth: 110)
        #expect(rows(1) == [false, false, false, false, true, false], "placed at Ls")
        var s = p
        s.channels = 2
        s.tracks[1].position = nil
        let stereo = Waveform.columns(s, track: 1, start: 0, framesPerColumn: 960, count: 10, peaks: [:], pool: SourcePool())
        #expect(stereo.count == 2 && stereo.allSatisfy { $0.contains { $0 != .empty } }, "mono in both rows of a stereo document, as before")
    }

    /// A 5.1 document with one mono voice (a steady tone, so every sample's ideal gain is known) on a track.
    func movingDoc(_ dir: TempDir, seconds: Double = 2) throws -> (Project, [Float]) {
        let n = Int(48_000 * seconds)
        let tone = (0..<n).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / 48_000)) }
        let url = dir.file("tone.wav")
        try writeWAV(tone, to: url, channels: 1)
        let ref = SourceRef(name: "tone", path: url.path, info: try AudioFileReader.info(at: url))
        var p = Project(source: try file(dir, "six.wav", channels: 6, frames: n))
        p.sources.append(ref)
        p.tracks = [Track(name: "Voice", clips: [Clip(sourceID: ref.id, start: 0, length: Frame(n))])]
        return (p, tone)
    }

    @Test("A place that moves: a fixed place through the engine's panner is the fixed matrix's sound; 30° to 110° over two seconds starts on L alone and ends on Ls alone; a render from the middle is the whole's; against the ideal path (every sample at its own place) the 512-frame grid stays within its tolerance")
    func movingPlace() throws {
        let dir = TempDir()
        var (p, tone) = try movingDoc(dir)
        let id = p.tracks[0].id, n = tone.count
        try p.setTrackPosition(id, azimuth: 70)
        let fixed = PlanCompiler.compile(p, pool: SourcePool()).render(from: 0, frames: n)
        // The same fixed place as a lane of one point: through the engine's own panner.
        try p.setAutomation(strip: id, param: .azimuth, points: [AutomationPoint(frame: 0, value: 70)])
        let oneLane = PlanCompiler.compile(p, pool: SourcePool()).render(from: 0, frames: n)
        var worst: Float = 0
        for i in 0..<fixed.count { worst = max(worst, abs(fixed[i] - oneLane[i])) }
        #expect(worst < 1e-5, "the engine's panner against the app's: \(worst)")
        // Moving: 30° (L) at the start to 110° (Ls) at the end.
        try p.setAutomation(strip: id, param: .azimuth, points: [AutomationPoint(frame: 0, value: 30), AutomationPoint(frame: Frame(n), value: 110)])
        let plan = PlanCompiler.compile(p, pool: SourcePool())
        let moving = plan.render(from: 0, frames: n)
        #expect(abs(moving[0 * 6 + 0] - tone[0]) < 1e-6 && moving[4] == 0, "starts on L")
        let last = n - 1
        #expect(abs(moving[last * 6 + 4] - tone[last]) < 2e-3 && abs(moving[last * 6 + 0]) < 2e-3, "ends on Ls")
        // From the middle: the same samples.
        let at = 48_000 + 300
        let part = plan.render(from: Frame(at), frames: 20_000)
        #expect(part == Array(moving[(at * 6)..<((at + 20_000) * 6)]), "a render from the middle is the whole's")
        // Against the ideal path.
        // Along the straight stretch (more than one grid step from a point): within 2·10⁻⁵ of the level. In the
        // 512 frames around a point that isn't on the grid (here the lane's end) the glide cuts the corner:
        // within 2·10⁻³ of the level (−54 dB).
        var straight: Float = 0, corner: Float = 0
        for i in stride(from: 0, to: n, by: 7) {
            let az = 30 + 80 * Double(i) / Double(n)
            let g = Panner.gains(azimuth: az, elevation: 0, in: .surround51)
            for c in 0..<6 {
                let d = abs(moving[i * 6 + c] - g[c] * tone[i]) / 0.5
                if i >= 1_024, i < n - 1_024 { straight = max(straight, d) } else { corner = max(corner, d) }
            }
        }
        print("moving place, 80° in 2 s, against the ideal path, relative to the level: \(straight) along the line, \(corner) at its end")
        #expect(straight < 2e-5 && corner < 2e-3, "\(straight), \(corner)")
    }

    @Test("A bus turned: a voice on L through a bus turned 80° to the left plays from Ls (110°) only; the LFE goes through as it is; a turn by lane glides; refused in stereo and in Ambisonics")
    func busTurn() throws {
        let dir = TempDir()
        var (p, tone) = try movingDoc(dir)
        let n = tone.count
        try p.addBus(name: "Group", output: nil)
        let bus = p.buses[0].id
        try p.setTrackRoute(p.tracks[0].id, output: .some(bus))
        try p.setTrackPosition(p.tracks[0].id, azimuth: 30)       // on L
        try p.setBusTurn(bus, azimuth: 80)                        // L (30°) turned to 110°: Ls
        let out = PlanCompiler.compile(p, pool: SourcePool()).render(from: 0, frames: n)
        var onLs: Float = 0, elsewhere: Float = 0
        for i in 0..<n { for c in 0..<6 { if c == 4 { onLs = max(onLs, abs(out[i * 6 + c] - tone[i])) } else { elsewhere = max(elsewhere, abs(out[i * 6 + c])) } } }
        #expect(onLs < 1e-5 && elsewhere < 1e-5, "\(onLs), \(elsewhere)")
        // By lane: 0° to 80°, starting on L and ending on Ls.
        try p.setAutomation(strip: bus, param: .azimuth, points: [AutomationPoint(frame: 0, value: 0), AutomationPoint(frame: Frame(n), value: 80)])
        let moving = PlanCompiler.compile(p, pool: SourcePool()).render(from: 0, frames: n)
        #expect(abs(moving[0] - tone[0]) < 1e-5 && abs(moving[(n - 1) * 6 + 4] - tone[n - 1]) < 2e-3)
        #expect(throws: Automation.Failure.self) { try p.setAutomation(strip: bus, param: .elevation, points: [AutomationPoint(frame: 0, value: 10)]) }
        var s = p
        s.channels = 2
        #expect(throws: Mixer.Failure.self) { try s.setBusTurn(bus, azimuth: 10) }
        s.channels = 4
        #expect(throws: Mixer.Failure.self) { try s.setBusTurn(bus, azimuth: 10) }
    }
}
