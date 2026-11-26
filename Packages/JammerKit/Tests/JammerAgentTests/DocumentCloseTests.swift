import Foundation
import Testing
@testable import JammerAgent

/// DELETE /api/v1/documents/{id} (File › Close for an agent) and what a closed connection stops.
@Suite("Closing a document for an agent")
struct DocumentCloseTests {
    @Test("Nothing unsaved: it closes, whoever opened it")
    func closes() {
        #expect(DocumentClose.refusal(.init(edited: false)) == nil)
        #expect(DocumentClose.refusal(.init(edited: false, linkedFile: "film.wav")) == nil, "a linked document saved back closes as its alert lets it")
    }

    @Test("Unsaved changes: 409 unsaved_changes, never discarded, never saved unasked; a linked one where its close alert would ask")
    func refuses() throws {
        let plain = try #require(DocumentClose.refusal(.init(edited: true)))
        #expect(plain.status == 409 && plain.code == "unsaved_changes" && plain.message.contains("POST …/save"))
        let linked = try #require(DocumentClose.refusal(.init(edited: true, linkedFile: "film.wav")))
        #expect(linked.code == "unsaved_changes" && linked.message.contains("not yet saved back to film.wav"))
        let lost = try #require(DocumentClose.refusal(.init(edited: true, lostLink: "the file was moved")))
        #expect(lost.code == "unsaved_changes" && lost.message.contains("the file was moved"))
        let sheet = try #require(DocumentClose.refusal(.init(edited: false, sheet: true)))
        #expect(sheet.status == 409 && sheet.code == "sheet_open")
    }

    @Test("A closed connection stops a turn, an export and a run of steps, and nothing else")
    func hangUp() {
        let doc = ["api", "v1", "documents", "D"]
        #expect(AgentAPI.stopsOnHangUp(method: "POST", segments: ["api", "v1", "transcribe"]))
        #expect(AgentAPI.stopsOnHangUp(method: "POST", segments: doc + ["export"]))
        #expect(AgentAPI.stopsOnHangUp(method: "POST", segments: doc + ["steps"]))
        #expect(!AgentAPI.stopsOnHangUp(method: "POST", segments: ["api", "v1", "transcribe", "file"]), "a file job goes on; DELETE stops it")
        #expect(!AgentAPI.stopsOnHangUp(method: "POST", segments: doc + ["transcribe"]))
        #expect(!AgentAPI.stopsOnHangUp(method: "GET", segments: doc + ["export"]))
    }
}

/// A connection that answers each read from a script: bytes, then (perhaps) its end; past the script it waits.
final class ScriptedConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var script: [(Data?, Bool, Error?)]
    private(set) var reads = 0
    init(_ script: [(Data?, Bool, Error?)]) { self.script = script }
    func receive(_ answer: @escaping @Sendable (Data?, Bool, Error?) -> Void) {
        let next: (Data?, Bool, Error?)? = lock.withLock {
            reads += 1
            return script.isEmpty ? nil : script.removeFirst()
        }
        if let next { answer(next.0, next.1, next.2) }
    }
}

final class Count: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

@Suite("A call that stops when its caller hangs up")
struct HangUpWatchTests {
    @Test("Bytes after the request don't end the watch: the hang-up after them is still seen (one read used to decide, and missed it)")
    func extraBytesThenHangUp() {
        let script: [(Data?, Bool, Error?)] = [(Data("\r\n".utf8), false, nil), (Data("GET /x HTTP/1.1\r\n".utf8), false, nil), (nil, true, nil)]
        let c = ScriptedConnection(script), gone = Count()
        AgentAPI.watchForHangUp(receive: c.receive, gone: gone.add)
        #expect(gone.value == 1 && c.reads == 3)
        // Before: one read, and a byte in it was taken as "still there" for good.
        let old = ScriptedConnection(script), oldGone = Count()
        old.receive { _, isComplete, error in if isComplete || error != nil { oldGone.add() } }
        #expect(oldGone.value == 0, "the old watch never saw the hang-up")
    }

    @Test("Still there: no hang-up; an error: gone; the end at once: gone")
    func endsAndErrors() {
        let waiting = ScriptedConnection([(Data("x".utf8), false, nil)]), none = Count()
        AgentAPI.watchForHangUp(receive: waiting.receive, gone: none.add)
        #expect(none.value == 0 && waiting.reads == 2, "reading on, nothing more has come")
        let broken = ScriptedConnection([(nil, false, URLError(.networkConnectionLost))]), err = Count()
        AgentAPI.watchForHangUp(receive: broken.receive, gone: err.add)
        #expect(err.value == 1)
        let closed = ScriptedConnection([(nil, true, nil)]), end = Count()
        AgentAPI.watchForHangUp(receive: closed.receive, gone: end.add)
        #expect(end.value == 1)
    }
}
