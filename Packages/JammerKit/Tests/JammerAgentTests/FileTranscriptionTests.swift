import Foundation
import Testing
@testable import JammerAgent

/// POST /api/v1/transcribe/file (Drömmer's film captions): every case the route answers without a model.
@Suite("Files for another app: the body, the length, the words given once, the shared gate")
struct FileTranscriptionTests {
    func code(_ f: () throws -> Void) -> (Int, String)? {
        do { try f(); return nil } catch { return (error as? AgentAPI.APIError).map { ($0.status, $0.code) } ?? (0, "\(error)") }
    }

    @Test("The body is audio bytes or an upload; a path, an empty body or anything else is 400")
    func body() throws {
        let wav = TurnTranscriptionTests.wav()
        #expect(try FileTranscription.body(contentType: "audio/wav", data: wav) == .bytes(wav))
        #expect(try FileTranscription.body(contentType: "application/octet-stream", data: wav) == .bytes(wav))
        #expect(try FileTranscription.body(contentType: "application/json", data: Data(#"{"upload":"abc"}"#.utf8)) == .upload("abc"))
        #expect(code { _ = try FileTranscription.body(contentType: "audio/mp4", data: Data()) }! == (400, "bad_request"))
        #expect(code { _ = try FileTranscription.body(contentType: "application/json", data: Data(#"{"path":"/etc/passwd"}"#.utf8)) }! == (400, "bad_request"))
        #expect(code { _ = try FileTranscription.body(contentType: "application/json", data: Data(#"{"upload":""}"#.utf8)) }! == (400, "bad_request"))
        #expect(code { _ = try FileTranscription.body(contentType: "text/plain", data: Data("hello".utf8)) }! == (400, "bad_request"))
        do {
            _ = try FileTranscription.body(contentType: nil, data: Data(#"{"path":"/tmp/a.wav"}"#.utf8))
            Issue.record("A path was taken")
        } catch {
            #expect(error.message.hasPrefix("Jämmer doesn't read a file named by a path here."))
        }
    }

    @Test("At most two hours: 413 over, exactly two hours is taken, no sound is 400")
    func length() throws {
        try FileTranscription.checkLength(seconds: 7_200)
        #expect(code { try FileTranscription.checkLength(seconds: 7_200.5) }! == (413, "too_large"))
        #expect(code { try FileTranscription.checkLength(seconds: 0) }! == (400, "bad_request"))
    }

    @Test("The words come with the first read of the finished job; later reads say fetched, unread ones expire after 10 minutes")
    func once() throws {
        let store = FileTranscription.Results()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let words = FileTranscription.json(words: [.init(text: "Hej", start: 0.25, end: 0.5, confidence: 0.9)], engine: "pianissimo", model: "pianissimo-sv", language: "sv-SE")
        #expect(Set(words.keys) == ["text", "words", "engine", "model", "language"])
        store.put("A", words, at: t0)
        let job: [String: Any] = ["id": "A", "kind": FileTranscription.kind, "status": "done", "result": ["words": 1]]
        let first = FileTranscription.merged(job, id: "A", results: store, now: t0.addingTimeInterval(5))
        let r1 = try #require(first["result"] as? [String: Any])
        #expect(r1["text"] as? String == "Hej" && (r1["words"] as? [[String: Any]])?.first?["start"] as? Double == 0.25)
        #expect(store.count == 0)
        let second = try #require(FileTranscription.merged(job, id: "A", results: store, now: t0.addingTimeInterval(6))["result"] as? [String: Any])
        #expect(second["gone"] as? Bool == true && second["why"] as? String == "fetched" && second["words"] == nil)

        store.put("B", words, at: t0)
        let late = try #require(FileTranscription.merged(job, id: "B", results: store, now: t0.addingTimeInterval(601))["result"] as? [String: Any])
        #expect(late["gone"] as? Bool == true && late["why"] as? String == "expired")
        // A job the store never held keeps its own result.
        #expect((FileTranscription.merged(job, id: "C", results: store)["result"] as? [String: Any])?["words"] as? Int == 1)
    }

    @Test("One transcription for another app at a time: a file holds the gate against turns and files, each told why")
    func gate() throws {
        let g = TurnTranscription.Gate()
        try g.enter(.file)
        for what in [TurnTranscription.Gate.Holder.turn, .file] {
            do { try g.enter(what); Issue.record("let in") } catch {
                #expect(error.status == 409 && error.code == "busy" && error.message.hasPrefix("Jämmer is transcribing a file for another app."))
            }
        }
        g.leave()
        try g.enter(.turn)
        #expect(code { try g.enter(.file) }! == (409, "busy"))
        g.leave()
    }

    @Test("The route takes language, engine and upload, and is listed as a free endpoint that starts a job")
    func route() throws {
        let r = try #require(AgentAPI.routes.first { $0.matches("POST", ["api", "v1", "transcribe", "file"]) })
        #expect(r.query == ["language", "engine"] && r.body == ["upload"])
        let spec = try #require(Operations.endpoints.first { $0.name == "transcribe_file" })
        #expect(spec.call?.path == "/api/v1/transcribe/file" && !spec.paid && spec.startsJob)
        #expect(throws: AgentAPI.APIError.self) {
            try AgentAPI.checkParameters(method: "POST", path: ["api", "v1", "transcribe", "file"], query: [], body: Data(#"{"path":"/x"}"#.utf8))
        }
    }
}
