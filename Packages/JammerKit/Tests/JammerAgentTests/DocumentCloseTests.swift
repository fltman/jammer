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
