import Foundation
import Testing
@testable import JammerAgent

/// POST /api/v1/transcribe (Drömmer's short turns): every case the route answers without a model.
@Suite("Short turns: the request, the gate and the answer")
struct TurnTranscriptionTests {
    static func wav(rate: Int = 16_000, channels: Int = 1, bits: Int = 16, seconds: Double = 1, extraChunk: Bool = false) -> Data {
        let frames = Int(Double(rate) * seconds)
        let dataBytes = frames * channels * bits / 8
        var d = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes + (extraChunk ? 12 : 0)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(channels); u32(rate); u32(rate * channels * bits / 8); u16(channels * bits / 8); u16(bits)
        if extraChunk { d.append(contentsOf: Array("LIST".utf8)); u32(3); d.append(contentsOf: [1, 2, 3, 0]) }
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        // A full-scale square at 100 Hz, so the values can be checked.
        for i in 0..<frames { for _ in 0..<channels { if bits == 16 { u16(Int(UInt16(bitPattern: (i / 80) % 2 == 0 ? 16_384 : -16_384))) } else { d.append(0) } } }
        return d
    }

    func code(_ f: () throws -> Void) -> (Int, String)? {
        do { try f(); return nil } catch { return (error as? AgentAPI.APIError).map { ($0.status, $0.code) } ?? (0, "\(error)") }
    }

    @Test("A turn of 16 kHz mono PCM16 is read as floats, with the language and engine from the query; a padded chunk before data is skipped")
    func reads() throws {
        let r = try TurnTranscription.parse(query: ["language": "sv-SE", "engine": "whisper"], body: Self.wav(seconds: 2, extraChunk: true))
        #expect(r.samples.count == 32_000 && r.seconds == 2 && r.language == "sv-SE" && r.engine == .whisper)
        #expect(r.samples[0] == 0.5 && r.samples[80] == -0.5)
        let d = try TurnTranscription.parse(query: [:], body: Self.wav())
        #expect(d.language == "sv-SE" && d.engine == .auto)
    }

    @Test("Anything else is 400: another rate, stereo, 24-bit, not a WAV, no audio, an engine that doesn't exist")
    func refuses() {
        #expect(code { _ = try TurnTranscription.parse(query: [:], body: Self.wav(rate: 44_100)) }! == (400, "bad_request"))
        #expect(code { _ = try TurnTranscription.parse(query: [:], body: Self.wav(channels: 2)) }! == (400, "bad_request"))
        #expect(code { _ = try TurnTranscription.parse(query: [:], body: Self.wav(bits: 24)) }! == (400, "bad_request"))
        #expect(code { _ = try TurnTranscription.parse(query: [:], body: Data("hello".utf8)) }! == (400, "bad_request"))
        #expect(code { _ = try TurnTranscription.parse(query: [:], body: Self.wav(seconds: 0)) }! == (400, "bad_request"))
        #expect(code { _ = try TurnTranscription.parse(query: ["engine": "apple"], body: Self.wav()) }! == (400, "bad_request"))
    }

    @Test("More than 15 s is 413; exactly 15 s is a turn")
    func tooLong() throws {
        #expect(code { _ = try TurnTranscription.parse(query: [:], body: Self.wav(seconds: 15.1)) }! == (413, "too_large"))
        #expect(try TurnTranscription.parse(query: [:], body: Self.wav(seconds: 15)).seconds == 15)
    }

    @Test("One turn at a time: a second while one runs is 409 busy, and the next after it is let in")
    func gate() throws {
        let g = TurnTranscription.Gate()
        try g.enter()
        #expect(code { try g.enter() }! == (409, "busy"))
        g.leave()
        try g.enter()
        g.leave()
    }

    @Test("Turned off in Settings: 403 sibling_transcription_off")
    func off() {
        let e = TurnTranscription.off()
        #expect(e.status == 403 && e.code == "sibling_transcription_off")
    }

    @Test("The answer: text, words with times in seconds and confidence (null when there is none), engine, model, ms")
    func answer() throws {
        let j = TurnTranscription.json(words: [.init(text: "Hej", start: 0.1234, end: 0.5, confidence: 0.91), .init(text: "där", start: 0.6, end: 0.9, confidence: nil)],
                                       engine: "whisper", model: "kb-whisper-small", ms: 412)
        #expect(j["text"] as? String == "Hej där" && j["engine"] as? String == "whisper" && j["model"] as? String == "kb-whisper-small" && j["ms"] as? Int == 412)
        let words = try #require(j["words"] as? [[String: Any]])
        #expect(words[0]["start"] as? Double == 0.123 && words[0]["confidence"] as? Double == 0.91 && words[1]["confidence"] is NSNull)
        #expect(Set(words[0].keys) == ["text", "start", "end", "confidence"])
    }

    @Test("The route takes language and engine in the query and a raw body, and is listed as a free endpoint")
    func route() throws {
        let r = try #require(AgentAPI.routes.first { $0.matches("POST", ["api", "v1", "transcribe"]) })
        #expect(r.query == ["language", "engine"] && r.body == nil)
        let spec = try #require(Operations.endpoints.first { $0.name == "transcribe_turn" })
        #expect(spec.call?.path == "/api/v1/transcribe" && !spec.paid)
        #expect(throws: AgentAPI.APIError.self) { try AgentAPI.checkParameters(method: "POST", path: ["api", "v1", "transcribe"], query: ["model"], body: Data()) }
    }
}
