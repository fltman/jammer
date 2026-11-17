import Foundation
import JammerCore
import Testing
@testable import JammerSpeech

/// A stand-in provider that takes its time: it records the request, and answers only after two seconds,
/// unless the request is stopped first.
final class SlowProvider: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var arrived = 0, stopped = 0, answered = 0
    static func reset() { lock.withLock { arrived = 0; stopped = 0; answered = 0 } }
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
        Self.lock.withLock { Self.arrived += 1 }
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
}
