import Foundation
import JammerCore
import Testing
@testable import JammerSpeech

@Suite("Hosted Pianissimo")
struct BergetPianissimoTests {
    private final class Socket: PianissimoSocket, @unchecked Sendable {
        let lock = NSLock()
        var events: [String]
        var types: [String] = []
        var audioBytes = 0
        var wasClosed = false

        init(_ events: [String]) { self.events = events }

        func sendText(_ text: String) async throws {
            let packet = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let type = try #require(packet["type"] as? String)
            lock.withLock {
                types.append(type)
                if let encoded = packet["audio"] as? String { audioBytes += Data(base64Encoded: encoded)?.count ?? 0 }
            }
        }

        func receiveData() async throws -> Data {
            let event = lock.withLock { events.isEmpty ? nil : events.removeFirst() }
            return try Data(#require(event).utf8)
        }

        func close() { lock.withLock { wasClosed = true } }
    }

    @Test func sendsBoundedTurnsAndUsesOnlyTheFinalText() async throws {
        let confirmed = #"{"type":"session.updated","session":{"audio":{"input":{"transcription":{"model":"klang/pianissimo"}}}}}"#
        let socket = Socket([#"{"type":"session.created"}"#, confirmed,
                             #"{"type":"conversation.item.input_audio_transcription.delta","delta":"partial"}"#,
                             #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"Hej nu."}"#,
                             #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"Tack."}"#])
        let engine = BergetPianissimo(key: "test") { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test")
            return socket
        }
        let words = try await engine.transcribe([Float](repeating: 0.1, count: 400_000), sourceFrames: 1_200_000, sourceRate: 48_000) { _ in }
        #expect(socket.types.first == "session.update")
        #expect(socket.types.filter { $0 == "input_audio_buffer.commit" }.count == 2)
        #expect(socket.audioBytes == 800_000)
        #expect(words.map(\.text) == ["Hej", "nu.", "Tack."])
        #expect(words.allSatisfy { $0.untimed == true })
        #expect(socket.wasClosed)
    }
}
