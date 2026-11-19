import AVFoundation
import Foundation
import Testing
@testable import JammerCore
@testable import JammerDiarize

/// The voice-profile threshold, measured before the feature is shown (SIBLINGS, "Röstprofiler", 2026-11-19).
/// A profile is made from one chapter of a reader, and tried against utterances of another chapter by the same
/// reader (should match) and by every other reader (should not), clean and under three conditions applied here:
/// noise, a phone line and a room. Readers: LibriSpeech test-clean (40 real, consenting readers, CC BY 4.0,
/// downloaded with Anders's yes) in JAMMER_CORPUS, and macOS voices (synthetic). Runs only with JAMMER_BENCH=1;
/// the model from JAMMER_MODELS_DIR (the app's own, already installed). Results go in docs/DIARISATION.md.
@Suite("Voiceprints", .serialized, .enabled(if: ProcessInfo.processInfo.environment["JAMMER_BENCH"] == "1"))
struct VoiceprintEval {
    let sr = 16_000.0

    /// A file as mono 16 kHz floats (LibriSpeech is FLAC).
    func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: file.processingFormat, to: target)!
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: input)
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * sr / file.processingFormat.sampleRate) + 1024)!
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    /// A macOS voice saying a line, mono 16 kHz.
    func speak(_ voice: String, _ text: String, dir: URL) throws -> [Float] {
        // WAV: AIFF can't hold little-endian floats, and say writes nothing then.
        let url = dir.appending(path: "\(UUID().uuidString).wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "-o", url.path, "--file-format=WAVE", "--data-format=LEF32@16000", text]
        try p.run(); p.waitUntilExit()
        return try read(url)
    }

    // The conditions, applied to a test utterance (never to the profile, which is made from clean speech).
    func noise(_ x: [Float], snr: Double, seed: UInt64) -> [Float] {
        var g = SystemRandomNumberGenerator()
        _ = seed
        let p = x.reduce(0) { $0 + Double($1 * $1) } / Double(max(x.count, 1))
        let s = Float(sqrt(p / pow(10, snr / 10)))
        return x.map { $0 + s * Float(Double.random(in: -1.732...1.732, using: &g)) }
    }
    func biquad(_ x: [Float], b: [Double], a: [Double]) -> [Float] {
        var y = [Float](repeating: 0, count: x.count), x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in x.indices {
            let v = b[0] * Double(x[i]) + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2
            x2 = x1; x1 = Double(x[i]); y2 = y1; y1 = v; y[i] = Float(v)
        }
        return y
    }
    /// RBJ high- or low-pass, Q 0.707.
    func pass(_ x: [Float], _ f: Double, high: Bool) -> [Float] {
        let w = 2 * .pi * f / sr, al = sin(w) / (2 * 0.7071), c = cos(w)
        let b = high ? [(1 + c) / 2, -(1 + c), (1 + c) / 2] : [(1 - c) / 2, 1 - c, (1 - c) / 2]
        let a0 = 1 + al
        return biquad(x, b: b.map { $0 / a0 }, a: [1, -2 * c / a0, (1 - al) / a0])
    }
    func phone(_ x: [Float]) -> [Float] { noise(pass(pass(x, 300, high: true), 3_400, high: false), snr: 25, seed: 2) }
    /// A room: an exponentially decaying noise tail (RT60 0.5 s) mixed half wet.
    func room(_ x: [Float]) -> [Float] {
        let n = Int(0.5 * sr)
        var g = SystemRandomNumberGenerator()
        let ir = (0..<n).map { i in Float(Double.random(in: -1...1, using: &g) * exp(-6.9 * Double(i) / Double(n))) * 0.02 }
        var y = x
        // A sparse convolution (every 8th tap) keeps it quick and is plenty for a diffuse tail.
        for k in stride(from: 1, to: n, by: 8) where ir[k] != 0 { for i in k..<x.count { y[i] += x[i - k] * ir[k] * 8 } }
        let peak = y.map(abs).max() ?? 1, peak0 = x.map(abs).max() ?? 1
        return y.map { $0 * peak0 / max(peak, 1e-6) }
    }

    struct Reader { var name: String; var enroll: [[Float]]; var tests: [[Float]] }

    /// LibriSpeech test-clean: per reader, up to 4 utterances of the first chapter for the profile, up to 3 of
    /// another chapter (or of the same chapter's last ones when there is only one) to try.
    func libriSpeech(_ root: URL) throws -> [Reader] {
        let fm = FileManager.default
        var out: [Reader] = []
        for speaker in try fm.contentsOfDirectory(atPath: root.path).filter({ Int($0) != nil }).sorted() {
            let chapters = try fm.contentsOfDirectory(atPath: root.appending(path: speaker).path).filter { Int($0) != nil }.sorted()
            func files(_ c: String) throws -> [URL] {
                try fm.contentsOfDirectory(atPath: root.appending(path: "\(speaker)/\(c)").path).filter { $0.hasSuffix(".flac") }.sorted()
                    .map { root.appending(path: "\(speaker)/\(c)/\($0)") }
            }
            let a = try files(chapters[0])
            let b = chapters.count > 1 ? try files(chapters[1]) : Array(a.suffix(3))
            let enroll = try a.prefix(4).map(read), tests = try b.prefix(3).map(read)
            out.append(Reader(name: "LS\(speaker)", enroll: enroll, tests: tests))
        }
        return out
    }

    func synthetic(dir: URL) throws -> [Reader] {
        let enrollLines = ["The ferry leaves the old harbour at seven every morning, whatever the weather.",
                           "Most of the people on board are going to work on the other side of the bay.",
                           "In winter the crossing takes longer, because the ice has to be broken first.",
                           "Nobody really remembers why the timetable was set like this so long ago."]
        let testLines = ["Today we are talking about small towns by the sea and the boats that connect them.",
                         "The vote last spring kept the early ferry, and most people seemed happy with that.",
                         "Thanks for listening, and see you again next week on the same channel."]
        let voices = ["Samantha", "Daniel", "Karen", "Moira", "Tessa", "Rishi", "Flo", "Alva"]
        // A voice that isn't installed on this Mac gives no audio and is left out.
        return try voices.compactMap { v in
            guard let e = try? enrollLines.map({ try speak(v, $0, dir: dir) }), e.allSatisfy({ $0.count > 8_000 }) else { return nil }
            return Reader(name: "macOS-\(v)", enroll: e, tests: try testLines.map { try speak(v, $0, dir: dir) })
        }
    }

    @Test("Same reader against other readers, clean and under noise, phone and room")
    func threshold() async throws {
        let models = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JAMMER_MODELS_DIR"] ?? NSTemporaryDirectory()).appending(path: "diarisation")
        let engine = FluidDiarizer(folder: models, source: URL(string: "https://huggingface.co")!)
        let dir = FileManager.default.temporaryDirectory.appending(path: "jammer-vp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var sets: [(String, [Reader])] = []
        if let c = ProcessInfo.processInfo.environment["JAMMER_CORPUS"] { sets.append(("LibriSpeech test-clean", try libriSpeech(URL(fileURLWithPath: c)))) }
        sets.append(("macOS voices", try synthetic(dir: dir)))
        func print_(_ s: String) {
            print(s)
            guard let p = ProcessInfo.processInfo.environment["JAMMER_EVAL_REPORT"] else { return }
            if !FileManager.default.fileExists(atPath: p) { FileManager.default.createFile(atPath: p, contents: nil) }
            if let h = FileHandle(forWritingAtPath: p) { h.seekToEndOfFile(); h.write(Data((s + "\n").utf8)); try? h.close() }
        }
        for (setName, readers) in sets {
            // One print per clip, from the whole clip.
            func vp(_ x: [Float]) async throws -> [Float]? { try await engine.voiceprints(mono16k: x, spans: ["s": [0..<Double(x.count) / sr]])?["s"] }
            var profiles: [String: [Float]] = [:]
            for r in readers {
                var joined: [Float] = [], spans: [Range<Double>] = []
                for e in r.enroll { spans.append(Double(joined.count) / sr..<Double(joined.count + e.count) / sr); joined += e }
                profiles[r.name] = try await engine.voiceprints(mono16k: joined, spans: ["s": spans])?["s"]
            }
            let conditions: [(String, ([Float]) -> [Float])] = [("clean", { $0 }), ("noise 15 dB", { noise($0, snr: 15, seed: 1) }), ("phone", phone), ("room", room)]
            for (cname, apply) in conditions {
                var genuine: [Double] = [], impostor: [Double] = []
                for r in readers {
                    for t in r.tests {
                        guard let v = try await vp(apply(t)) else { continue }
                        for (name, p) in profiles {
                            let s = VoicePrint.similarity(p, v)
                            if name == r.name { genuine.append(s) } else { impostor.append(s) }
                        }
                    }
                }
                func rates(_ th: Double) -> (Double, Double) {
                    (Double(impostor.filter { $0 >= th }.count) / Double(max(impostor.count, 1)), Double(genuine.filter { $0 < th }.count) / Double(max(genuine.count, 1)))
                }
                let grid = stride(from: 0.30, through: 0.90, by: 0.01).map { $0 }
                let eer = grid.min { abs(rates($0).0 - rates($0).1) < abs(rates($1).0 - rates($1).1) }!
                var row = String(format: "VP %@ | %@ | readers %d, same-reader pairs %d, other-reader pairs %d | EER ≈ %.1f%% at %.2f |", setName, cname,
                                 readers.count, genuine.count, impostor.count, (rates(eer).0 + rates(eer).1) * 50, eer)
                for th in [0.50, 0.55, 0.60, 0.65, 0.70, 0.75] { let (fa, fr) = rates(th); row += String(format: " %.2f: false match %.2f%%, miss %.1f%%;", th, fa * 100, fr * 100) }
                print_(row)
            }
        }
    }
}
