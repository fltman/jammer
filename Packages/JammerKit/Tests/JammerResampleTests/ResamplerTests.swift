import Foundation
import Testing
import JammerAgent
import JammerCore
@testable import JammerResample

/// The converter against what it should do to signals whose answer is known. A sine stays a sine of the
/// same frequency and level; a tone above the new rate's half must be gone, not folded back; nothing moves.
@Suite("Sample rate conversion", .serialized)
struct ResamplerTests {
    static func sine(_ hz: Double, rate: Double, seconds: Double, amp: Double = 0.5) -> [Float] {
        (0..<Int(rate * seconds)).map { Float(amp * sin(2 * .pi * hz * Double($0) / rate)) }
    }
    /// Amplitude of `hz` in `x` (least squares on sine and cosine) and the level of everything else, dB re the tone.
    static func tone(_ x: ArraySlice<Float>, hz: Double, rate: Double) -> (amp: Double, residualDB: Double) {
        var ss = 0.0, cc = 0.0, sc = 0.0, xs = 0.0, xc = 0.0
        for (i, v) in x.enumerated() {
            let p = 2 * .pi * hz * Double(i) / rate, s = sin(p), c = cos(p)
            ss += s * s; cc += c * c; sc += s * c; xs += Double(v) * s; xc += Double(v) * c
        }
        let det = ss * cc - sc * sc, a = (xs * cc - xc * sc) / det, b = (xc * ss - xs * sc) / det
        var res = 0.0, sig = 0.0
        for (i, v) in x.enumerated() {
            let p = 2 * .pi * hz * Double(i) / rate, fit = a * sin(p) + b * cos(p)
            res += (Double(v) - fit) * (Double(v) - fit); sig += fit * fit
        }
        return ((a * a + b * b).squareRoot(), 10 * log10(max(res, 1e-300) / sig))
    }
    static func rmsDB(_ x: ArraySlice<Float>) -> Double { 10 * log10(max(x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count), 1e-300)) }
    /// The middle of a result, away from the ends where the filter runs in and out.
    static func middle(_ x: [Float], rate: Double) -> ArraySlice<Float> { x[Int(rate * 0.25)..<(x.count - Int(rate * 0.25))] }

    @Test("A tone stays the same tone: level within 0.01 dB, everything else more than 110 dB under it",
          arguments: [(48_000.0, 44_100.0), (44_100.0, 48_000.0), (48_000.0, 96_000.0), (96_000.0, 44_100.0), (44_100.0, 16_000.0), (48_000.0, 22_050.0)])
    func purity(rates: (Double, Double)) throws {
        let (from, to) = rates
        for hz in [100.0, 997, 5_000] where hz < to * 0.45 {
            let y = try Resampler.convert(Self.sine(hz, rate: from, seconds: 2), channels: 1, from: from, to: to)
            #expect(y.count == Int((2 * to).rounded()))
            let t = Self.tone(Self.middle(y, rate: to), hz: hz, rate: to)
            #expect(abs(20 * log10(t.amp / 0.5)) < 0.01 && t.residualDB < -110, "\(Int(from))→\(Int(to)) \(hz) Hz: \(20 * log10(t.amp / 0.5)) dB, residual \(t.residualDB) dB")
        }
    }

    @Test("48 → 44.1 kHz: flat to 20 kHz within 0.05 dB; a tone at 23 kHz, over the new half rate, is more than 100 dB down and not folded back")
    func band() throws {
        for hz in [20.0, 1_000, 10_000, 18_000, 20_000] {
            let y = try Resampler.convert(Self.sine(hz, rate: 48_000, seconds: 2), channels: 1, from: 48_000, to: 44_100)
            let gain = 20 * log10(Self.tone(Self.middle(y, rate: 44_100), hz: hz, rate: 44_100).amp / 0.5)
            #expect(abs(gain) < 0.05, "\(hz) Hz: \(gain) dB")
        }
        // 23 kHz would fold to 21.1 kHz at 44.1 kHz if it got through.
        let y = try Resampler.convert(Self.sine(23_000, rate: 48_000, seconds: 2), channels: 1, from: 48_000, to: 44_100)
        let left = Self.rmsDB(Self.middle(y, rate: 44_100)) - 10 * log10(0.125)
        #expect(left < -100, "\(left) dB")
    }

    @Test("Nothing moves: a click at one second is at one second, in stereo, and the two channels stay apart")
    func alignment() throws {
        var x = [Float](repeating: 0, count: 48_000 * 2 * 2)
        x[48_000 * 2] = 0.9          // left only, at 1.000 s
        let y = try Resampler.convert(x, channels: 2, from: 48_000, to: 44_100)
        #expect(y.count == 44_100 * 2 * 2)
        let left = stride(from: 0, to: y.count, by: 2).map { abs(y[$0]) }, right = stride(from: 1, to: y.count, by: 2).map { abs(y[$0]) }
        #expect(left.firstIndex(of: left.max()!) == 44_100 && right.max()! == 0)
        // Up as well: 44.1 → 96 kHz, a click at 0.5 s.
        var u = [Float](repeating: 0, count: 44_100)
        u[22_050] = 0.9
        let v = try Resampler.convert(u, channels: 1, from: 44_100, to: 96_000).map(abs)
        #expect(v.count == 96_000 && v.firstIndex(of: v.max()!) == 48_000)
    }

    @Test("The result doesn't depend on the blocks it is fed in, and is exactly as long as the input amounts to")
    func blocks() throws {
        var rng = SystemRandomNumberGenerator()
        let n = 48_000 + 123
        let x = (0..<(n * 2)).map { _ in Float.random(in: -0.5...0.5, using: &rng) }
        let whole = try Resampler.convert(x, channels: 2, from: 48_000, to: 44_100)
        #expect(whole.count == Int((Double(n) * 44_100 / 48_000).rounded()) * 2)
        let r = try Resampler(from: 48_000, to: 44_100, channels: 2)
        var parts: [Float] = []
        var at = 0
        for size in [1, 7, 4_095, 4_097, 20_000, n] where at < n { let m = min(size, n - at); parts += r.process(Array(x[(at * 2)..<((at + m) * 2)])); at += m }
        parts += r.process(Array(x[(at * 2)...]))
        parts += r.finish()
        #expect(parts == whole)
        // The same rate: the audio itself, untouched.
        #expect(try Resampler.convert(x, channels: 2, from: 48_000, to: 48_000) == x)
        #expect(try Resampler.convert([], channels: 2, from: 48_000, to: 44_100).isEmpty)
    }

    @Test("There and back: 48 → 44.1 → 48 kHz of band-limited noise nulls against the original to under −100 dB")
    func roundTrip() throws {
        // A sum of tones under 18 kHz: nothing the 44.1 kHz stage has to take away.
        let n = 48_000 * 2
        var x = [Float](repeating: 0, count: n)
        for (k, hz) in stride(from: 110.0, to: 18_000, by: 937).enumerated() { for i in 0..<n { x[i] += Float(0.02 * sin(2 * .pi * hz * Double(i) / 48_000 + Double(k))) } }
        let back = try Resampler.convert(try Resampler.convert(x, channels: 1, from: 48_000, to: 44_100), channels: 1, from: 44_100, to: 48_000)
        #expect(back.count == n)
        let diff = zip(Self.middle(back, rate: 48_000), Self.middle(x, rate: 48_000)).map { $0 - $1 }
        #expect(Self.rmsDB(diff[...]) - Self.rmsDB(Self.middle(x, rate: 48_000)) < -100)
    }

    @Test("Refused in words: a rate that isn't offered, nonsense rates, no channels")
    func refusals() {
        #expect(throws: Resampler.Failure.self) { _ = try Resampler(from: 48_000, to: 44_000, channels: 2) }
        #expect(throws: Resampler.Failure.self) { _ = try Resampler(from: 48_000, to: .nan, channels: 2) }
        #expect(throws: Resampler.Failure.self) { _ = try Resampler(from: 0, to: 44_100, channels: 2) }
        #expect(throws: Resampler.Failure.self) { _ = try Resampler(from: .infinity, to: 44_100, channels: 2) }
        #expect(throws: Resampler.Failure.self) { _ = try Resampler(from: 48_000, to: 44_100, channels: 0) }
        #expect(Resampler.version == "7.7")
    }

    /// Against two converters that have nothing to do with r8brain: ffmpeg's (swresample) and Apple's
    /// (afconvert at its best quality). The same band-limited signal through each, 48 → 44.1 kHz, and
    /// the difference between their output and ours. Skipped where the tools aren't installed.
    @Test("Agrees with ffmpeg's and Apple's converters on a band-limited signal")
    func references() throws {
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
        let dir = FileManager.default.temporaryDirectory.appending(path: "jammer-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let n = 48_000 * 3
        var x = [Float](repeating: 0, count: n)
        for (k, hz) in stride(from: 110.0, to: 16_000, by: 937).enumerated() { for i in 0..<n { x[i] += Float(0.03 * sin(2 * .pi * hz * Double(i) / 48_000 + Double(k))) } }
        let ours = try Resampler.convert(x, channels: 1, from: 48_000, to: 44_100)
        let raw = dir.appending(path: "in.f32")
        try x.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: raw)
        func run(_ tool: String, _ args: [String]) throws -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            return p.terminationStatus == 0
        }
        func floats(_ url: URL) throws -> [Float] { try Data(contentsOf: url).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
        /// Level of (theirs − ours) against the signal, in the middle of the file.
        func against(_ theirs: [Float]) -> Double {
            let m = min(theirs.count, ours.count), a = 11_025, b = m - 11_025
            let diff = zip(theirs[a..<b], ours[a..<b]).map { $0 - $1 }
            return Self.rmsDB(diff[...]) - Self.rmsDB(ours[a..<b])
        }
        var compared = 0
        if let ffmpeg {
            let out = dir.appending(path: "ffmpeg.f32")
            if try run(ffmpeg, ["-loglevel", "error", "-y", "-f", "f32le", "-ar", "48000", "-ac", "1", "-i", raw.path,
                                "-af", "aresample=44100:filter_size=512:phase_shift=14:linear_interp=0:cutoff=0.98", "-f", "f32le", out.path]) {
                let theirs = try floats(out)
                let d = against(theirs)
                print("RESAMPLE REFERENCE ffmpeg swresample: \(theirs.count) frames (ours \(ours.count)), difference \(String(format: "%.1f", d)) dB")
                #expect(abs(theirs.count - ours.count) <= 1 && d < -80)
                compared += 1
            }
        }
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/afconvert") {
            let wav = dir.appending(path: "in.wav"), out = dir.appending(path: "af.wav"), outRaw = dir.appending(path: "af.f32")
            if let ffmpeg, try run(ffmpeg, ["-loglevel", "error", "-y", "-f", "f32le", "-ar", "48000", "-ac", "1", "-i", raw.path, "-c:a", "pcm_f32le", wav.path]),
               try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEF32@44100", "--src-complexity", "bats", "-r", "127", wav.path, out.path]),
               try run(ffmpeg, ["-loglevel", "error", "-y", "-i", out.path, "-f", "f32le", outRaw.path]) {
                let theirs = try floats(outRaw)
                let d = against(theirs)
                print("RESAMPLE REFERENCE afconvert bats 127: \(theirs.count) frames (ours \(ours.count)), difference \(String(format: "%.1f", d)) dB")
                #expect(abs(theirs.count - ours.count) <= 1 && d < -80)
                compared += 1
            }
        }
        print("RESAMPLE REFERENCE compared with \(compared) converter(s)")
    }

    @Test("The figures, for the record") func figures() throws {
        for (from, to) in [(48_000.0, 44_100.0), (44_100.0, 48_000.0), (96_000.0, 44_100.0)] {
            let t = Self.tone(Self.middle(try Resampler.convert(Self.sine(997, rate: from, seconds: 2), channels: 1, from: from, to: to), rate: to), hz: 997, rate: to)
            print("RESAMPLE FIGURE \(Int(from))→\(Int(to)) 997 Hz: level \(String(format: "%+.4f", 20 * log10(t.amp / 0.5))) dB, everything else \(String(format: "%.1f", t.residualDB)) dB")
        }
        for hz in [20.0, 10_000, 18_000, 20_000, 21_000] {
            let y = try Resampler.convert(Self.sine(hz, rate: 48_000, seconds: 2), channels: 1, from: 48_000, to: 44_100)
            print("RESAMPLE FIGURE 48000→44100 \(Int(hz)) Hz: \(String(format: "%+.4f", 20 * log10(Self.tone(Self.middle(y, rate: 44_100), hz: hz, rate: 44_100).amp / 0.5))) dB")
        }
        for hz in [22_500.0, 23_000, 23_900] {
            let y = try Resampler.convert(Self.sine(hz, rate: 48_000, seconds: 2), channels: 1, from: 48_000, to: 44_100)
            print("RESAMPLE FIGURE 48000→44100 \(Int(hz)) Hz (over the new half rate): \(String(format: "%.1f", Self.rmsDB(Self.middle(y, rate: 44_100)) - 10 * log10(0.125))) dB")
        }
    }

    /// Importing a file at another rate than the document's used the system's converter until 2026-11-16
    /// and uses this one since. The same file through both: the same length, and the same audio within
    /// −90 dB for a signal under 18 kHz. (Projects made before point at files that were already
    /// converted, and those are not touched.)
    @Test("An import at another rate: the same result as the system's converter gave, within −90 dB", .serialized)
    func importAgrees() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "jammer-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir); SampleRateConversion.factory = nil }
        let n = 44_100 * 3
        var x = [Float](repeating: 0, count: n * 2)
        for (k, hz) in stride(from: 110.0, to: 18_000, by: 937).enumerated() {
            for i in 0..<n { let v = Float(0.02 * sin(2 * .pi * hz * Double(i) / 44_100 + Double(k))); x[i * 2] += v; x[i * 2 + 1] += v * 0.5 }
        }
        let file = dir.appending(path: "in.wav")
        let w = try WAVWriter(url: file, options: .init(encoding: .float32, channels: 2, sampleRate: 44_100))
        try w.write(x); try w.finish()
        func imported() throws -> [Float] {
            let r = try AudioImporter.importFile(file, sampleRate: 48_000, mediaFolder: dir.appending(path: UUID().uuidString))
            #expect(r.source.info.sampleRate == 48_000 && r.source.info.channels == 2)
            return SourcePool().read(r.source, from: 0, count: Int(r.source.info.frames))
        }
        SampleRateConversion.factory = nil
        let system = try imported()
        Resampler.register()
        let ours = try imported()
        #expect(ours.count == 48_000 * 3 * 2 && abs(system.count - ours.count) <= 2 * 2, "\(system.count) \(ours.count)")
        let m = min(system.count, ours.count), a = 48_000, b = m - 48_000
        let diff = zip(system[a..<b], ours[a..<b]).map { $0 - $1 }
        let level = Self.rmsDB(diff[...]) - Self.rmsDB(ours[a..<b])
        print("RESAMPLE IMPORT system converter vs r8brain: \(system.count / 2) and \(ours.count / 2) frames, difference \(String(format: "%.1f", level)) dB")
        #expect(level < -90)
        // The same rate: no converter is asked, and the audio is the file's.
        let same = try AudioImporter.importFile(file, sampleRate: 44_100, mediaFolder: dir.appending(path: "same"))
        #expect(SourcePool().read(same.source, from: 0, count: n) == x)
    }

    @Test("Batch export at another sample rate: the same field and the same refusals as a single export", .serialized)
    func batch() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "jammer-batch-rate-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir.appending(path: "in"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir); SampleRateConversion.factory = nil }
        let file = dir.appending(path: "in/talk.wav")
        let w = try WAVWriter(url: file, options: .init(encoding: .int24, channels: 2, sampleRate: 48_000, markers: [FileMarker(position: 48_000, length: 0, name: "One second")]))
        try w.write(Self.sine(997, rate: 48_000, seconds: 2).flatMap { [$0, $0] }); try w.finish()
        let policy = FolderPolicy(allowed: [dir])
        func body(_ export: [String: Any], out: String) -> [String: Any] { ["files": [file.path], "output": dir.appending(path: out).path, "export": export] }
        // Without the converter in the build it is refused before anything runs.
        SampleRateConversion.factory = nil
        #expect(throws: BatchError.self) { try BatchRequest.parse(body(["format": "wav", "sampleRate": 44_100], out: "x"), policy: policy) }
        Resampler.register()
        #expect(throws: BatchError.self) { try BatchRequest.parse(body(["format": "wav", "sampleRate": 44_000], out: "x"), policy: policy) }
        #expect(throws: BatchError.self) { try BatchRequest.parse(body(["format": "wav", "sampleRate": true], out: "x"), policy: policy) }
        #expect(throws: BatchError.self) { try BatchRequest.parse(body(["format": "opus", "sampleRate": 44_100], out: "x"), policy: policy) }
        let result = await BatchRunner.run(try BatchRequest.parse(body(["format": "wav", "bitDepth": 24, "sampleRate": 44_100], out: "out"), policy: policy), media: dir.appending(path: "media"))
        #expect(result.failed.isEmpty, "\(result.failed)")
        let out = try #require(try FileManager.default.contentsOfDirectory(at: dir.appending(path: "out"), includingPropertiesForKeys: nil).first { $0.pathExtension == "wav" })
        let info = try AudioFileReader.info(at: out)
        #expect(info.sampleRate == 44_100 && info.frames == 88_200 && info.channels == 2)
        // The marker moved with the audio, and the tone is the same tone.
        #expect(info.markers.first?.position == 44_100 && info.markers.first?.name == "One second")
        let y = SourcePool().read(SourceRef(name: "o", path: out.path, info: info), from: 0, count: 88_200)
        let t = Self.tone(Self.middle(stride(from: 0, to: y.count, by: 2).map { y[$0] }, rate: 44_100), hz: 997, rate: 44_100)
        #expect(abs(20 * log10(t.amp / 0.5)) < 0.01 && t.residualDB < -100, "\(t)")
        // Nothing left behind in the output folder but the file.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appending(path: "out").path).filter { !$0.hasPrefix(".DS") }.count == 1)
        // The same rate as the file: no conversion, and the audio is the source's, bit for bit.
        let same = await BatchRunner.run(try BatchRequest.parse(body(["format": "wav", "bitDepth": 24, "sampleRate": 48_000], out: "same"), policy: policy), media: dir.appending(path: "media"))
        #expect(same.failed.isEmpty)
        let s = try #require(try FileManager.default.contentsOfDirectory(at: dir.appending(path: "same"), includingPropertiesForKeys: nil).first { $0.pathExtension == "wav" })
        let sInfo = try AudioFileReader.info(at: s), fInfo = try AudioFileReader.info(at: file)
        #expect(SourcePool().read(SourceRef(name: "s", path: s.path, info: sInfo), from: 0, count: 96_000) == SourcePool().read(SourceRef(name: "f", path: file.path, info: fInfo), from: 0, count: 96_000))
    }
}
