import Foundation
import JammerCore
import Testing
@testable import JammerSpeech

/// Stands in for OpenAI's transcription endpoint, in the form its documentation shows. Nothing leaves the test.
final class FakeTranscriber: URLProtocol, @unchecked Sendable {
    struct Asked { var path: String; var host: String; var auth: String; var bytes: Int; var fields: [String: String]; var wavSeconds: Double }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var asked: [Asked] = []
    nonisolated(unsafe) private static var answers: [(Int, String)] = []
    static func set(_ a: [(Int, String)]) { lock.withLock { answers = a; asked = [] } }
    static var requests: [Asked] { lock.withLock { asked } }
    static var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeTranscriber.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 1 << 16)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; body.append(buf, count: n) }
        }
        // The text fields of the form, and the size of the file part.
        var fields: [String: String] = [:]
        var seconds = 0.0
        let type = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        if let b = type.components(separatedBy: "boundary=").last, type.contains("multipart/form-data") {
            let mark = Data("--\(b)".utf8)
            var parts: [Data] = []
            var at = body.startIndex
            while let r = body.range(of: mark, in: at..<body.endIndex) {
                if r.lowerBound > at { parts.append(body[at..<r.lowerBound]) }
                at = r.upperBound
            }
            for p in parts {
                guard let split = p.range(of: Data("\r\n\r\n".utf8)) else { continue }
                let head = String(decoding: p[p.startIndex..<split.lowerBound], as: UTF8.self)
                let content = p[split.upperBound..<(p.endIndex - 2)]
                guard let name = head.components(separatedBy: "name=\"").dropFirst().first?.components(separatedBy: "\"").first else { continue }
                if name == "file" { seconds = Double(content.count - 44) / 2 / 16_000; fields["filename"] = head.components(separatedBy: "filename=\"").last?.components(separatedBy: "\"").first }
                else { fields[name] = String(decoding: content, as: UTF8.self) }
            }
        }
        let url = request.url!
        let answer = Self.lock.withLock { () -> (Int, String) in
            Self.asked.append(Asked(path: url.path, host: url.host() ?? "", auth: request.value(forHTTPHeaderField: "Authorization") ?? "", bytes: body.count, fields: fields, wavSeconds: seconds))
            return Self.answers.isEmpty ? (500, "{}") : Self.answers.removeFirst()
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: answer.0, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("OpenAI transcription, text only", .serialized)
struct OpenAITranscriptionTests {
    /// 70 s at 48 kHz stereo: a tone that stops for half a second at 18.0 s, 36.0 s and 54.0 s.
    static func source(_ dir: URL) throws -> SourceRef {
        let url = dir.appending(path: "talk.wav")
        let w = try WAVWriter(url: url, options: .init(encoding: .float32, channels: 2, sampleRate: 48_000))
        let quiet: [Range<Double>] = [18.0..<18.5, 36.0..<36.5, 54.0..<54.5]
        var raw = [Float](repeating: 0, count: 48_000 * 2)
        for second in 0..<70 {
            for i in 0..<48_000 {
                let t = Double(second) + Double(i) / 48_000
                let v: Float = quiet.contains { $0.contains(t) } ? 0 : Float(0.3 * sin(2 * .pi * 220 * t))
                raw[i * 2] = v; raw[i * 2 + 1] = v
            }
            try w.write(raw)
        }
        try w.finish()
        return SourceRef(name: "talk", path: url.path, info: try AudioFileReader.info(at: url))
    }
    func folder() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "jammer-openai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    func engine(key: String? = "sk-secret-123") -> OpenAITranscription {
        var e = OpenAITranscription(model: "some-transcribe-model", key: { key }, session: FakeTranscriber.session)
        e.maxSeconds = 20
        e.searchSeconds = 5
        return e
    }

    @Test("A long file goes in pieces cut in the pauses, each under the limit, with the last words carried to the next")
    func pieces() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try Self.source(dir)
        FakeTranscriber.set([(200, #"{"text":"Hej och välkommen till podden.","languages":[{"code":"sv"}]}"#), (200, #"{"text":"Idag pratar vi om ljud.","languages":[{"code":"sv"}]}"#),
                             (200, #"{"text":"Det var allt.","languages":[]}"#), (200, #"{"text":"Hej då!","languages":[{"code":"sv"}]}"#)])
        let t = try await engine().transcribe(src, pool: SourcePool(), locale: Locale(identifier: "sv-SE")) { _ in }
        let asked = FakeTranscriber.requests
        #expect(asked.count == 4 && asked.allSatisfy { $0.path == "/v1/audio/transcriptions" && $0.host == "api.openai.com" && $0.auth == "Bearer sk-secret-123" })
        #expect(asked.allSatisfy { $0.fields["model"] == "some-transcribe-model" && $0.fields["languages[]"] == "sv" && $0.fields["language"] == nil })
        #expect(asked.map { $0.fields["filename"] } == ["part-1.wav", "part-2.wav", "part-3.wav", "part-4.wav"])
        // Cut inside the three pauses (18.0–18.5, 36.0–36.5, 54.0–54.5), never over 20 s a piece.
        let ends = asked.map(\.wavSeconds).reduce(into: [Double]()) { $0.append(($0.last ?? 0) + $1) }
        #expect(asked.allSatisfy { $0.wavSeconds <= 20 && $0.bytes < 25_000_000 })
        #expect((18.0...18.5).contains(ends[0]) && (36.0...36.5).contains(ends[1]) && (54.0...54.5).contains(ends[2]) && abs(ends[3] - 70) < 0.01, "\(ends)")
        // Context: nothing with the first piece, the end of what was heard with the rest.
        #expect(asked[0].fields["prompt"] == nil && asked[1].fields["prompt"]?.hasSuffix("välkommen till podden.") == true && asked[3].fields["prompt"]?.hasSuffix("Det var allt.") == true)
        // The transcript: the text, marked as without word times, each piece's words inside its piece.
        #expect(t.textOnly == true && t.engine == "openai some-transcribe-model" && t.language == "sv-SE")
        #expect(t.words.map(\.text).joined(separator: " ") == "Hej och välkommen till podden. Idag pratar vi om ljud. Det var allt. Hej då!")
        let first = t.words.prefix(5), second = t.words.dropFirst(5).prefix(5)
        #expect(first.allSatisfy { Double($0.end) / 48_000 <= ends[0] + 0.01 } && second.allSatisfy { Double($0.start) / 48_000 >= ends[0] - 0.01 && Double($0.end) / 48_000 <= ends[1] + 0.01 })
        #expect(zip(t.words, t.words.dropFirst()).allSatisfy { $0.start < $1.start && $0.end <= $1.start + 1 } && t.words.last!.end <= src.info.frames)
    }

    @Test("No key: nothing is sent. The provider's error: its own words. An answer in another form: said")
    func failures() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try Self.source(dir)
        FakeTranscriber.set([])
        await #expect(throws: TranscriptionError.self) { _ = try await engine(key: nil).transcribe(src, pool: SourcePool(), locale: Locale(identifier: "sv-SE")) { _ in } }
        #expect(FakeTranscriber.requests.isEmpty)
        FakeTranscriber.set([(401, #"{"error":{"message":"Incorrect API key provided.","type":"invalid_request_error"}}"#)])
        do {
            _ = try await engine().transcribe(src, pool: SourcePool(), locale: Locale(identifier: "sv-SE")) { _ in }
            Issue.record("no error")
        } catch {
            #expect(error.localizedDescription == "Transcription failed: OpenAI answered 401: Incorrect API key provided.")
            #expect(!error.localizedDescription.contains("sk-secret"))
        }
        // The second piece fails: the whole transcription fails, nothing half is returned.
        FakeTranscriber.set([(200, #"{"text":"Hej."}"#), (429, #"{"error":{"message":"Rate limit reached."}}"#)])
        await #expect(throws: TranscriptionError.failed("OpenAI answered 429: Rate limit reached.")) { _ = try await engine().transcribe(src, pool: SourcePool(), locale: Locale(identifier: "sv-SE")) { _ in } }
        FakeTranscriber.set([(200, #"{"segments":[]}"#)])
        await #expect(throws: TranscriptionError.failed("OpenAI's answer wasn't in the form its documentation shows.")) { _ = try await engine().transcribe(src, pool: SourcePool(), locale: Locale(identifier: "sv-SE")) { _ in } }
    }

    @Test("The models come from the provider's list: those that transcribe files, none written into the app")
    func models() async throws {
        FakeTranscriber.set([(200, #"{"data":[{"id":"some-chat-model"},{"id":"x-transcribe"},{"id":"x-live-transcribe"},{"id":"x-transcribe-diarize"},{"id":"a-mini-transcribe"}]}"#)])
        #expect(try await OpenAITranscription.models(key: "sk-secret-123", session: FakeTranscriber.session) == ["a-mini-transcribe", "x-transcribe"])
        #expect(FakeTranscriber.requests.first?.path == "/v1/models")
        // No model id stands in the source.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/JammerSpeech/OpenAITranscription.swift"), encoding: .utf8)
        for id in ["gpt-transcribe", "whisper-1", "gpt-4o"] { #expect(!source.contains("\"\(id)"), "\(id)") }
    }

    @Test("Cuts: nothing to cut in a short file; a file without pauses is cut at the limit all the same")
    func cuts() {
        #expect(SpeechAudio.cuts([Float](repeating: 0.1, count: 16_000 * 5), limit: 16_000 * 20, search: 16_000 * 5) == [0, 80_000])
        let steady = SpeechAudio.cuts([Float](repeating: 0.1, count: 16_000 * 50), limit: 16_000 * 20, search: 16_000 * 5)
        #expect(steady.first == 0 && steady.last == 800_000 && zip(steady, steady.dropFirst()).allSatisfy { $1 - $0 <= 16_000 * 20 && $1 > $0 })
        #expect(SpeechAudio.spread("ett två tre", over: 0..<1_100).map(\.text) == ["ett", "två", "tre"])
        #expect(SpeechAudio.spread("   ", over: 0..<1_000).isEmpty)
    }
}
