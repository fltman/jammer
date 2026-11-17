import Foundation
import JammerCore
import Testing
@testable import JammerSpeech

/// Stands in for ElevenLabs, in the form its API reference shows. Nothing leaves the test, and no key is real.
final class FakeElevenLabs: URLProtocol, @unchecked Sendable {
    struct Asked { var method: String; var path: String; var query: String; var key: String; var json: [String: Any]; var fields: [String: String]; var files: Int }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var asked: [Asked] = []
    nonisolated(unsafe) private static var answers: [(Int, Data, [String: String])] = []
    static func set(_ a: [(Int, Data, [String: String])]) { lock.withLock { answers = a; asked = [] } }
    static var requests: [Asked] { lock.withLock { asked } }
    static var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeElevenLabs.self]
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
        var fields: [String: String] = [:], files = 0
        let type = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        if let b = type.components(separatedBy: "boundary=").last, type.contains("multipart/form-data") {
            for part in String(decoding: body, as: UTF8.self).components(separatedBy: "--\(b)") {
                guard let name = part.components(separatedBy: "name=\"").dropFirst().first?.components(separatedBy: "\"").first else { continue }
                if name == "files" { files += 1 } else if let v = part.components(separatedBy: "\r\n\r\n").dropFirst().first { fields[name] = v.replacingOccurrences(of: "\r\n", with: "") }
            }
        }
        let json = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let url = request.url!
        let answer = Self.lock.withLock { () -> (Int, Data, [String: String]) in
            Self.asked.append(Asked(method: request.httpMethod ?? "", path: url.path, query: url.query ?? "", key: request.value(forHTTPHeaderField: "xi-api-key") ?? "",
                                    json: json, fields: fields, files: files))
            return Self.answers.isEmpty ? (500, Data("{}".utf8), [:]) : Self.answers.removeFirst()
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: answer.0, httpVersion: nil, headerFields: answer.2)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Overdub: consent first, then a cloned voice and speech in it (a stand-in ElevenLabs)", .serialized)
struct OverdubTests {
    static let rate = 48_000.0
    static let sentence = Overdub.consentSentence(language: "sv-SE")

    /// A 15 s document whose transcript has the consent sentence between 1 and 5 s.
    static func project(_ dir: URL, consentWords: String = sentence) throws -> Project {
        let n = Int(rate * 15)
        let x = (0..<n).map { Float(0.1 * sin(Double($0) * 0.05)) }
        let url = dir.appending(path: "speech.wav")
        let w = try WAVWriter(url: url, options: .init(encoding: .float32, channels: 1, sampleRate: rate))
        try w.write(x); try w.finish()
        var p = Project(source: SourceRef(name: "speech", path: url.path, info: try AudioFileReader.info(at: url)))
        let tokens = consentWords.split(separator: " ").map(String.init)
        let words = tokens.enumerated().map { i, t in Word(text: t, start: Frame(rate * (1 + 4 * Double(i) / Double(tokens.count))), end: Frame(rate * (1 + 4 * Double(i + 1) / Double(tokens.count)))) }
        p.transcripts = [SourceTranscript(sourceID: p.sources[0].id, language: "sv-SE", engine: "test", words: words)]
        return p
    }
    static func folder() -> URL { FileManager.default.temporaryDirectory.appending(path: "jammer-overdub-\(UUID().uuidString)") }

    @Test("The consent sentence is heard when said (Eleven Labs or ElevenLabs, punctuation and case aside), not when only part of it is said, or when it is buried in a long passage")
    func heard() {
        #expect(Overdub.says("jag samtycker till att min röst klonas med Eleven Labs för att redigera den här inspelningen", sentence: Self.sentence))
        #expect(!Overdub.says("jag samtycker till att min röst", sentence: Self.sentence))
        #expect(!Overdub.says(Self.sentence + " " + String(repeating: "och sedan pratade vi länge om annat ", count: 6), sentence: Self.sentence))
        #expect(Overdub.consentSentence(language: "en-US").hasPrefix("I consent"))
    }

    @Test("Nothing is prepared, and nothing could be sent, without the attestation, an adult, a transcript, the sentence heard where it is said to be, and enough of the speaker")
    func refusals() throws {
        let dir = Self.folder(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = try Self.project(dir)
        let plan = PlanCompiler.compile(p, pool: SourcePool())
        func reason(_ kind: VoiceAttestation.Kind?, adult: Bool = true, consent: ClosedRange<Double> = 0.9...5.1, samples: [ClosedRange<Double>] = [5...11, 9...15], project: Project? = nil) -> String? {
            do { _ = try OverdubService.prepareClone(project ?? p, plan: plan, kind: kind, adult: adult, consent: consent, samples: samples); return nil }
            catch let e as OverdubError { return e.reason } catch { return "\(error)" }
        }
        #expect(reason(nil) == "not_attested")
        #expect(reason(.own, adult: false) == "not_adult")
        var bare = p; bare.transcripts = []
        #expect(reason(.own, project: bare) == "no_transcript")
        #expect(reason(.own, consent: 10...14) == "consent_not_heard")
        #expect(reason(.own, samples: [5...9]) == "samples_too_short")
        #expect(reason(.own, samples: [5...16]) == "sample_outside")
        #expect(reason(.ownerConsent) == nil)
        let (attestation, files) = try OverdubService.prepareClone(p, plan: plan, kind: .own, adult: true, consent: 0.9...5.1, samples: [5...11, 9...15])
        #expect(attestation.kind == .own && attestation.heard.hasPrefix("Jag samtycker") && files.count == 2 && files[0].count == 44 + 6 * 48_000 * 2)
    }

    @Test("Cloned at the stand-in: the samples go as files beside the name and a description of the consent, with the user's key; the voice keeps its attestation. Speech in it: the text and model as JSON, MP3 asked for, the file kept as it came; the clip replaces the words, carries the mark and its words, and the project is saved as format 7")
    func cloneAndSpeak() async throws {
        let dir = Self.folder(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var p = try Self.project(dir)
        let plan = PlanCompiler.compile(p, pool: SourcePool())
        let (attestation, files) = try OverdubService.prepareClone(p, plan: plan, kind: .own, adult: true, consent: 0.9...5.1, samples: [5...11, 9...15])
        // The stand-in's speech: a 2 s WAV (the importer reads by content; ElevenLabs would send MP3).
        let said = ElevenLabs.wav([Float](repeating: 0.05, count: 96_000), rate: 48_000)
        FakeElevenLabs.set([(200, Data(#"{"voice_id":"voice-123","requires_verification":false}"#.utf8), [:]),
                            (200, said, ["character-cost": "12"])])
        let service = OverdubService(provider: ElevenLabs(base: URL(string: "https://stand-in.invalid")!, key: { "test-key" }, session: FakeElevenLabs.session))
        let (voice, verify) = try await service.clone(name: "Anders", attestation: attestation, samples: [5...11, 9...15], files: files)
        #expect(voice.providerVoiceID == "voice-123" && !verify && voice.attestation == attestation)
        let made = try await service.speak(voice, text: "Hej igen", model: ElevenLabs.defaultModel, previous: "före", next: "efter", sampleRate: Self.rate, folder: dir)
        let asked = FakeElevenLabs.requests
        #expect(asked.count == 2)
        #expect(asked[0].method == "POST" && asked[0].path == "/v1/voices/add" && asked[0].key == "test-key" && asked[0].files == 2 && asked[0].fields["name"] == "Anders")
        #expect(asked[0].fields["description"]?.contains("own voice") == true)
        #expect(asked[1].path == "/v1/text-to-speech/voice-123" && asked[1].query == "output_format=mp3_44100_128")
        #expect(asked[1].json["text"] as? String == "Hej igen" && asked[1].json["model_id"] as? String == "eleven_multilingual_v2" && asked[1].json["previous_text"] as? String == "före")
        #expect(made.synthetic?.voice == voice.id && made.synthetic?.cloned == true && made.synthetic?.text == "Hej igen")
        let kept = try #require(made.originalPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: kept)) == said, "ElevenLabs' file kept byte for byte")
        p.voices.append(voice)
        let before = p.length
        try p.overdub(Frame(6 * Self.rate)..<Frame(7 * Self.rate), track: 0, with: made, words: "Hej igen", language: "sv-SE")
        #expect(p.length == before - Frame(Self.rate) + made.info.frames)
        #expect(p.placedWords(in: Frame(6 * Self.rate)..<Frame(8 * Self.rate)).map(\.word.text) == ["Hej", "igen"])
        #expect(p.syntheticNote(in: 0..<p.length)?.contains("cloned voice: Anders (elevenlabs, eleven_multilingual_v2)") == true)
        #expect(p.syntheticNote(in: 0..<Frame(Self.rate)) == nil)
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        #expect(saved["formatVersion"] as? Int == Project.voiceFormatVersion)
        let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        #expect(back.voices == p.voices && back.sources.contains { $0.synthetic == made.synthetic })
    }

    @Test("The provider's refusal in its own words (401: the key), no key at all, a deleted voice, empty or too long text")
    func failures() async throws {
        let dir = Self.folder(); defer { try? FileManager.default.removeItem(at: dir) }
        FakeElevenLabs.set([(401, Data(#"{"detail":{"status":"invalid_api_key","message":"Invalid API key"}}"#.utf8), [:])])
        let el = ElevenLabs(base: URL(string: "https://stand-in.invalid")!, key: { "bad" }, session: FakeElevenLabs.session)
        do { _ = try await el.clone(name: "x", description: "", samples: [Data()]); Issue.record("no error") }
        catch let f as ElevenLabs.Failure { #expect(f.status == 401 && f.reason == "key_rejected" && f.message == "Invalid API key") }
        let none = ElevenLabs(base: URL(string: "https://stand-in.invalid")!, key: { nil }, session: FakeElevenLabs.session)
        await #expect(throws: ElevenLabs.NoKey.self) { try await none.delete(voiceID: "v") }
        let att = VoiceAttestation(kind: .own, adult: true, sentence: "", heardAt: 0...1, heard: "", date: Date(), termsRead: "")
        var voice = ClonedVoice(provider: "elevenlabs", providerVoiceID: "v", name: "x", attestation: att, samples: [], created: Date())
        let service = OverdubService(provider: el)
        await #expect(throws: OverdubError.emptyText) { _ = try await service.speak(voice, text: "  ", model: "m", previous: nil, next: nil, sampleRate: 48_000, folder: dir) }
        await #expect(throws: OverdubError.textTooLong(ElevenLabs.maxCharacters)) { _ = try await service.speak(voice, text: String(repeating: "a", count: 10_001), model: "m", previous: nil, next: nil, sampleRate: 48_000, folder: dir) }
        voice.deleted = Date()
        await #expect(throws: OverdubError.voiceDeleted) { _ = try await service.speak(voice, text: "hej", model: "m", previous: nil, next: nil, sampleRate: 48_000, folder: dir) }
        FakeElevenLabs.set([(422, Data(#"{"detail":[{"loc":["body","text"],"msg":"field required","type":"missing"}]}"#.utf8), [:])])
        do { _ = try await el.speak(voiceID: "v", text: "x", model: "m", previous: nil, next: nil); Issue.record("no error") }
        catch let f as ElevenLabs.Failure { #expect(f.status == 422 && f.message == "field required") }
    }
}

@Suite("Overdub: the speaker's own pieces for a voice")
struct VoiceSampleTests {
    @Test("Pieces of the speaker who says the consent (by diarisation): runs of words within 0.7 s, each at least 5 s, nearest the consent first, at most two minutes; another speaker's words are never taken")
    func samples() throws {
        let rate = 48_000.0
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 1, sampleRate: rate, channelMask: nil,
                                 dataOffset: 0, frames: Int64(rate * 600), chunks: [], bext: nil, ixml: nil, markers: [])
        var p = Project(source: SourceRef(name: "talk", path: "/dev/null", info: info))
        var words: [Word] = []
        // Speaker 0 talks in 20 s runs every 40 s; speaker 1 in between.
        for block in 0..<15 {
            let base = Double(block) * 40
            for i in 0..<40 { words.append(Word(text: "a", start: Frame(rate * (base + Double(i) * 0.5)), end: Frame(rate * (base + Double(i) * 0.5 + 0.45)), speaker: 0)) }
            for i in 0..<30 { words.append(Word(text: "b", start: Frame(rate * (base + 21 + Double(i) * 0.5)), end: Frame(rate * (base + 21 + Double(i) * 0.5 + 0.45)), speaker: 1)) }
        }
        p.transcripts = [SourceTranscript(sourceID: p.sources[0].id, language: "sv-SE", engine: "test", words: words, speakers: ["A", "B"])]
        let pieces = p.voiceSamples(around: 80...84)
        let total = pieces.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
        #expect(total <= 120.001 && total >= 100, "\(total)")
        #expect(pieces.allSatisfy { $0.upperBound - $0.lowerBound >= 5 })
        // Only speaker 0's stretches (each starts on a multiple of 40 s).
        #expect(pieces.allSatisfy { $0.lowerBound.truncatingRemainder(dividingBy: 40) < 0.01 }, "\(pieces)")
        #expect(pieces.contains { $0.lowerBound == 80 }, "the run with the consent in it is among them")
    }
}
