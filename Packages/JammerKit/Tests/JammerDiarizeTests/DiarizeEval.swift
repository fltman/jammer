import Foundation
import Testing
@testable import JammerCore
@testable import JammerDiarize

/// The Community-1 model on synthetic conversations made with macOS voices (no real
/// people). Downloads the model (about 30 MB) into JAMMER_MODELS_DIR, so it only runs
/// with JAMMER_BENCH=1. Results go in docs/DIARISATION.md.
@Suite("Diarisation model", .serialized, .enabled(if: ProcessInfo.processInfo.environment["JAMMER_BENCH"] == "1"))
struct DiarizeEval {
    struct Line { var voice: String; var text: String; var gapBefore: Double }

    /// Easy: a woman and a man, long turns, no overlap.
    static let easy: [Line] = [
        .init(voice: "Alva", text: "Välkommen till podden. I dag ska vi prata om hur man spelar in ett samtal på distans utan att ljudet blir dåligt.", gapBefore: 0.5),
        .init(voice: "Daniel", text: "Thanks for having me. The first thing I always tell people is to record locally on each side, and to send the files afterwards.", gapBefore: 0.6),
        .init(voice: "Alva", text: "Det låter klokt. Men vad gör man om internet försvinner mitt i inspelningen?", gapBefore: 0.5),
        .init(voice: "Daniel", text: "Then the local recording saves you. You line the files up afterwards, and nobody can hear that anything went wrong.", gapBefore: 0.7),
        .init(voice: "Alva", text: "Och hur får man rösterna att låta lika starka i slutändan?", gapBefore: 0.4),
        .init(voice: "Daniel", text: "Measure the loudness of each track, bring them to the same level, and then normalise the mix for the platform.", gapBefore: 0.5),
    ]

    /// Hard: two Scandinavian women, many turns under a second, a little overlap
    /// (negative gaps start a line before the previous one ends).
    static let hard: [Line] = [
        .init(voice: "Alva", text: "Jag tänkte att vi börjar med inspelningen.", gapBefore: 0.4),
        .init(voice: "Nora", text: "Ja.", gapBefore: 0.15),
        .init(voice: "Alva", text: "Och sedan klipper vi.", gapBefore: 0.2),
        .init(voice: "Nora", text: "Akkurat.", gapBefore: -0.25),
        .init(voice: "Alva", text: "Precis.", gapBefore: 0.1),
        .init(voice: "Nora", text: "Men hva med lyden fra telefonen?", gapBefore: 0.3),
        .init(voice: "Alva", text: "Mm.", gapBefore: -0.2),
        .init(voice: "Nora", text: "Den er ofte litt dårlig.", gapBefore: 0.1),
        .init(voice: "Alva", text: "Okej.", gapBefore: 0.15),
        .init(voice: "Nora", text: "Ja.", gapBefore: 0.1),
        .init(voice: "Alva", text: "Då tar vi den från datorn i stället, den låter bättre.", gapBefore: 0.2),
        .init(voice: "Nora", text: "Fint.", gapBefore: -0.3),
        .init(voice: "Alva", text: "Bra.", gapBefore: 0.1),
        .init(voice: "Nora", text: "Skal vi ta det igjen fra starten?", gapBefore: 0.25),
        .init(voice: "Alva", text: "Ja, gärna.", gapBefore: 0.1),
        .init(voice: "Nora", text: "Nei.", gapBefore: 0.2),
        .init(voice: "Alva", text: "Nej?", gapBefore: 0.1),
        .init(voice: "Nora", text: "Jo, selvfølgelig, vi tar det fra starten.", gapBefore: -0.2),
    ]

    let sr = 48_000.0

    /// Speaks one line, trimmed to where the voice is, mono at 48 kHz.
    func speak(_ line: Line, dir: URL) throws -> [Float] {
        let url = dir.appending(path: "\(UUID().uuidString).aiff")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", line.voice, "-o", url.path, "--data-format=BEF32@48000", line.text]
        try p.run()
        p.waitUntilExit()
        let info = try AudioFileReader.info(at: url)
        let ref = SourceRef(name: "l", path: url.path, info: info)
        let x = SourcePool().read(ref, from: 0, count: Int(info.frames))
        let mono = info.channels == 1 ? x : stride(from: 0, to: x.count, by: info.channels).map { x[$0] }
        let peak = mono.map(abs).max() ?? 0
        let first = mono.firstIndex { abs($0) > peak * 0.02 } ?? 0, last = mono.lastIndex { abs($0) > peak * 0.02 } ?? mono.count - 1
        return Array(mono[first...last]).map { $0 * 0.3 / max(peak, 1e-6) }
    }

    /// The conversation as one mono file, with its answer key.
    func conversation(_ lines: [Line], dir: URL) throws -> (URL, [DiarizationScore.Segment]) {
        var mix: [Float] = []
        var key: [DiarizationScore.Segment] = []
        var cursor = 0
        for line in lines {
            let audio = try speak(line, dir: dir)
            let start = max(0, cursor + Int(line.gapBefore * sr))
            if mix.count < start + audio.count { mix += [Float](repeating: 0, count: start + audio.count - mix.count) }
            for i in audio.indices { mix[start + i] += audio[i] }
            key.append(.init(line.voice, Double(start) / sr, Double(start + audio.count) / sr))
            cursor = start + audio.count
        }
        mix += [Float](repeating: 0, count: Int(sr))
        let floor = (0..<mix.count).map { i in Float(sin(Double(i) * 12.9898).truncatingRemainder(dividingBy: 1)) * 0.0005 }
        let url = dir.appending(path: "conversation.wav")
        let w = try WAVWriter(url: url, options: .init(encoding: .float32, channels: 1, sampleRate: sr))
        try w.write(zip(mix, floor).map { $0 + $1 })
        try w.finish()
        return (url, key)
    }

    func run(_ name: String, _ lines: [Line], speakers: Int?) async throws -> (DiarizationScore.Result, DiarizationScore.Result) {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JAMMER_MODELS_DIR"] ?? NSTemporaryDirectory()).appending(path: "diarisation")
        let dir = FileManager.default.temporaryDirectory.appending(path: "jammer-diar-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (url, key) = try conversation(lines, dir: dir)
        let p = Project(source: SourceRef(name: name, path: url.path, info: try AudioFileReader.info(at: url)))
        Diarization.engine = FluidDiarizer(folder: folder, source: URL(string: "https://huggingface.co")!)
        let r = try await Diarization.model(p, pool: SourcePool(), tracks: [p.tracks[0].id], minSpeakers: speakers, maxSpeakers: speakers)
        let hyp = r[0].turns.map { DiarizationScore.Segment(r[0].names[$0.speaker], p.seconds($0.range.lowerBound), p.seconds($0.range.upperBound)) }
        let strict = DiarizationScore.score(reference: key, hypothesis: hyp)
        let collar = DiarizationScore.score(reference: key, hypothesis: hyp, collar: 0.25)
        print(String(format: "DIAR %@ speakers=%@ found=%d ref=%.1fs DER %.1f%% (miss %.1f, FA %.1f, conf %.1f) | collar 0.25: DER %.1f%% (conf %.1f)",
                     name, speakers.map(String.init) ?? "auto", r[0].names.count, strict.referenceSeconds, strict.der * 100, strict.missed * 100,
                     strict.falseAlarm * 100, strict.confusion * 100, collar.der * 100, collar.confusion * 100))
        return (strict, collar)
    }

    @Test("Easy: two different voices, long turns")
    func easyCase() async throws {
        let (_, collar) = try await run("easy", Self.easy, speakers: nil)
        #expect(collar.der < 0.15)
    }

    @Test("Hard: similar voices, short turns, overlap (reported, loose bound)")
    func hardCase() async throws {
        let (_, auto) = try await run("hard", Self.hard, speakers: nil)
        let (_, two) = try await run("hard-2", Self.hard, speakers: 2)
        #expect(auto.der < 0.8 && two.der < 0.8)
    }
}
