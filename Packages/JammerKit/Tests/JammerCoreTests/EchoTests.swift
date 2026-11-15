import CryptoKit
import Foundation
import Testing
@testable import JammerCore

@Suite("Echo")
struct EchoTests {
    @Test("An impulse comes back after each delay, scaled by feedback and mix")
    func impulse() {
        var line = Echo.Line(Echo(delay: 0.001, feedback: 0.5, mix: 0.8), sampleRate: 10_000) // D = 10 samples
        var x = [Float](repeating: 0, count: 45)
        x[0] = 1
        let y = line.process(x)
        #expect(y[0] == 1)
        #expect(y[10] == 0.8 && y[20] == 0.4 && y[30] == 0.2 && y[40] == 0.1)
        #expect(y.enumerated().allSatisfy { [0, 10, 20, 30, 40].contains($0.offset) || $0.element == 0 })
        // Streaming in pieces gives the same result.
        var a = Echo.Line(Echo(delay: 0.001, feedback: 0.5, mix: 0.8), sampleRate: 10_000)
        #expect(a.process(Array(x[0..<7])) + a.process(Array(x[7...])) == y)
        // Mix 0: the input, bit for bit.
        var z = Echo.Line(Echo(delay: 0.3, feedback: 0.9, mix: 0), sampleRate: 48_000)
        let noise = (0..<1_000).map { Float(($0 * 37) % 101) / 101 - 0.5 }
        #expect(z.process(noise) == noise)
    }

    @Test("Tail lasts until the echoes are 60 dB down, capped at 10 s")
    func tail() {
        #expect(Echo(delay: 0.5, feedback: 0, mix: 1).tail(sampleRate: 48_000) == 24_000)
        #expect(Echo(delay: 0.1, feedback: 0.5, mix: 1).tail(sampleRate: 48_000) == 4_800 * 10) // 0.5^10 < 0.001
        #expect(Echo(delay: 2, feedback: 0.95, mix: 1).tail(sampleRate: 48_000) == 480_000)
    }

    @Test("Bounced in place: the range gets the echo, other tracks and the rest stay bit-exact, tail makes room, words follow")
    func bounce() throws {
        let n = 48_000
        let a = (0..<(n * 2)).map { i -> Float in i / 2 % 4_800 == 0 ? 0.5 : 0 }   // clicks every 0.1 s
        let b = (0..<(n * 2)).map { Float(($0 * 13) % 65_536 - 32_768) / 65_536 }
        var (p, pool) = memoryProject(a)
        let infoB = p.sources[0].info
        let refB = SourceRef(name: "b", path: "/dev/null", info: infoB)
        pool.register(refB.id, memory: b, channels: 2)
        p.sources.append(refB)
        p.tracks.append(Track(name: "B", clips: [Clip(sourceID: refB.id, start: 0, length: Frame(n))]))
        p.setTranscript(SourceTranscript(sourceID: p.sources[0].id, language: "sv-SE", engine: "t",
                                         words: [Word(text: "ett", start: 12_000, end: 14_000), Word(text: "två", start: 40_000, end: 42_000)]))
        let media = FileManager.default.temporaryDirectory.appending(path: "jammer-echo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: media) }
        let echo = Echo(delay: 0.05, feedback: 0.5, mix: 0.5)
        let range: Range<Frame> = 9_600..<19_200
        let q = try p.applyingEcho(echo, range: range, tracks: [p.tracks[0].id], tail: true, pool: pool, media: media)
        let tail = echo.tail(sampleRate: 48_000)
        #expect(q.length == p.length + tail)
        #expect(q.tracks[1].clips.count == 2) // track B was split by the gap, untouched otherwise
        func render(_ x: Project) -> [Float] { let plan = PlanCompiler.compile(x, pool: pool); return plan.render(from: 0, frames: Int(plan.length)) }
        let before = render(p), after = render(q)
        // Before the range: identical.
        #expect(Array(after[0..<(9_600 * 2)]) == Array(before[0..<(9_600 * 2)]))
        // Clicks every 4 800 frames; the one at 9 600 echoes 2 400 frames later at mix × 1,
        // then again with feedback; the click at 14 400 adds to the second echo.
        let soloA = { (x: Project) -> [Float] in var s = x; s.tracks = [s.tracks[0]]; return render(s) }
        let qa = soloA(q)
        #expect(qa[12_000 * 2] == 0.25)
        #expect(qa[14_400 * 2] == 0.5 + 0.125)
        // The words of track A in the range keep their ids and their place.
        #expect(q.placedWords().first { $0.word.text == "ett" }?.start == 12_000)
        #expect(q.placedWords().first { $0.word.text == "ett" }?.word.id == p.placedWords().first { $0.word.text == "ett" }?.word.id)
        // After the range and its tail, everything is the old audio moved right by the tail.
        #expect(Array(soloA(q)[((30_000 + Int(tail)) * 2)..<((40_000 + Int(tail)) * 2)]) == Array(soloA(p)[(30_000 * 2)..<(40_000 * 2)]))
        // Mix 0 changes no samples.
        let z = try p.applyingEcho(Echo(delay: 0.1, feedback: 0.5, mix: 0), range: range, tail: false, pool: pool, media: media)
        #expect(render(z) == before)
        let digest = SHA256.hash(data: qa.withUnsafeBytes { Data($0) }).prefix(8).map { String(format: "%02x", $0) }.joined()
        if ProcessInfo.processInfo.environment["JAMMER_UPDATE_GOLDEN"] != nil { print("GOLDEN echo: \(digest)") }
        else { #expect(digest == "0d555eee71f193a1", "golden render echo changed: \(digest)") }
        #expect(throws: EffectError.self) { try p.applyingEcho(Echo(delay: 5, feedback: 0, mix: 1), range: range, tail: false, pool: pool, media: media) }
    }
}
