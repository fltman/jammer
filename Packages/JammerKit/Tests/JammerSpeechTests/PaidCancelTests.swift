import Foundation
import JammerCore
import Testing
@testable import JammerSpeech

/// A stand-in provider that takes its time: it records the request, and answers only after two seconds,
/// unless the request is stopped first.
final class SlowProvider: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var arrived = 0, stopped = 0, answered = 0
    /// How many requests, from the first, are answered at once ("early words") instead of after two seconds.
    nonisolated(unsafe) static var answeredAtOnce = 0
    static func reset() { lock.withLock { arrived = 0; stopped = 0; answered = 0; answeredAtOnce = 0 } }
    static var counts: (arrived: Int, stopped: Int, answered: Int) { lock.withLock { (arrived, stopped, answered) } }
    static var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [SlowProvider.self]
        return URLSession(configuration: c)
    }
    private var cancelled = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let n = Self.lock.withLock { Self.arrived += 1; return Self.arrived }
        if n <= Self.lock.withLock({ Self.answeredAtOnce }) {
            Self.lock.withLock { Self.answered += 1 }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"text":"early words"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            guard !Self.lock.withLock({ cancelled }) else { return }
            Self.lock.withLock { Self.answered += 1 }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"text":"late words"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { Self.lock.withLock { cancelled = true; Self.stopped += 1 } }
}

@Suite("A paid request canceled after it left the app (SIBLINGS.md §2)", .serialized)
struct PaidCancelTests {
    @Test("Canceled while the stand-in provider holds the request: the request had arrived, it is stopped, nothing of the late answer is fetched, and the transcription throws instead of returning words")
    func transcriptionCanceled() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "jammer-paidcancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try OpenAITranscriptionTests.source(dir)
        SlowProvider.reset()
        let engine = OpenAITranscription(endpoint: URL(string: "https://stand-in.invalid/v1")!, model: "m", key: { "test-key" }, session: SlowProvider.session)
        let task = Task { try await engine.transcribe(src, pool: SourcePool(), locale: Locale(identifier: "sv-SE")) { _ in } }
        // Wait for the request to reach the provider (it has left the app), then cancel.
        for _ in 0..<200 where SlowProvider.counts.arrived == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(SlowProvider.counts.arrived == 1)
        task.cancel()
        let outcome = await task.result
        try await Task.sleep(for: .milliseconds(2_300))
        let c = SlowProvider.counts
        #expect(c.stopped >= 1 && c.answered == 0, "stopped \(c.stopped), answered \(c.answered)")
        if case .success(let t) = outcome { Issue.record("words came back: \(t.words.map(\.text))") }
    }

    @Test("Canceled in the second piece, after the first was answered: the first piece's words, paid for, come back with the stop; the second's answer is not fetched")
    func stoppedAfterAPiece() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "jammer-paidcancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try OpenAITranscriptionTests.source(dir)
        SlowProvider.reset()
        SlowProvider.answeredAtOnce = 1
        var engine = OpenAITranscription(endpoint: URL(string: "https://stand-in.invalid/v1")!, model: "m", key: { "test-key" }, session: SlowProvider.session)
        engine.maxSeconds = 20
        let e = engine
        let task = Task { try await e.transcribe(src, pool: SourcePool(), locale: Locale(identifier: "sv-SE")) { _ in } }
        for _ in 0..<200 where SlowProvider.counts.arrived < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(SlowProvider.counts.arrived == 2, "the second piece has left")
        task.cancel()
        let outcome = await task.result
        guard case .failure(let error) = outcome, let stopped = error as? TranscriptionStopped else {
            Issue.record("expected the stop with the first piece's words, got \(outcome)")
            return
        }
        #expect(stopped.partial.words.map(\.text) == ["early", "words"] && stopped.partial.sourceID == src.id)
        #expect(stopped.covers.lowerBound == 0 && stopped.covers.upperBound > 0 && stopped.covers.upperBound < src.info.frames, "the first piece only")
        #expect(SlowProvider.counts.answered == 1, "the second answer is never fetched")
    }
}
