import Foundation
import Testing
@testable import JammerAgent

/// The agent server's answers are never kept by a client's cache (COMFORT.md 620092e): every one says no-store.
@Suite("The agent API's answers are not to be stored")
struct NoStoreTests {
    @Test("Every kind of answer carries Cache-Control: no-store")
    func noStore() {
        let answers: [AgentAPI.Response] = [.json(["ok": true]), .error(AgentAPI.APIError(404, "not_found", "x")), AgentAPI.Response(status: 200, contentType: "audio/wav", body: Data([1, 2]))]
        for a in answers {
            let head = String(decoding: a.serialized.prefix(400), as: UTF8.self)
            #expect(head.contains("\r\nCache-Control: no-store\r\n"), "\(head)")
        }
    }
}
