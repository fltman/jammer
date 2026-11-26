import Foundation
import Testing
@testable import JammerAgent

/// A pretend sibling's port: answers each request from a script (an error or a status), counting them.
final class PretendPort: @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Result<[String: Any], URLError>]
    private(set) var asked: [TimeInterval] = []
    init(_ script: [Result<[String: Any], URLError>]) { self.script = script }
    func fetch(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let next: Result<[String: Any], URLError> = lock.withLock {
            asked.append(r.timeoutInterval)
            return script.isEmpty ? .failure(URLError(.cannotConnectToHost)) : script.removeFirst()
        }
        switch next {
        case .failure(let e): throw e
        case .success(let o): return (try JSONSerialization.data(withJSONObject: o), HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
}

@Suite("Finding a sibling: refused, busy, another app (SIBLINGS da5b9d2)")
struct SiblingProbeTests {
    /// Outside the siblings' ranges (9001–9319), as the rule asks of tests.
    let base = URL(string: "http://127.0.0.1:9890")!
    let flimmer: [String: Any] = ["app": ["name": "Flimmer", "bundleID": "com.brattoo.flimmer"]]

    @Test("Refused: not running at once, one request")
    func refused() async {
        let port = PretendPort([.failure(URLError(.cannotConnectToHost))])
        #expect(await SiblingProbe.status(at: base, timeout: 2, fetch: port.fetch) == nil)
        #expect(port.asked.count == 1)
    }

    @Test("The time up after the connection was taken: busy, asked once more with 3 s, and found")
    func busyThenFound() async {
        let port = PretendPort([.failure(URLError(.timedOut)), .success(flimmer)])
        let status = await SiblingProbe.status(at: base, timeout: 2, fetch: port.fetch)
        #expect((status?["app"] as? [String: Any])?["name"] as? String == "Flimmer")
        #expect(port.asked == [2, 3], "the second try has 3 s")
        let still = PretendPort([.failure(URLError(.timedOut)), .failure(URLError(.timedOut))])
        #expect(await SiblingProbe.status(at: base, timeout: 2, fetch: still.fetch) == nil, "busy twice: not running")
        #expect(still.asked.count == 2, "and only one more try")
    }

    @Test("Another app on the port: no second try; Flimmer's own search goes on to the next port")
    func anotherApp() async {
        let other = PretendPort([.success(["app": ["name": "Glimmer"]])])
        let status = await SiblingProbe.status(at: base, timeout: 2, fetch: other.fetch)
        #expect((status?["app"] as? [String: Any])?["name"] as? String == "Glimmer" && other.asked.count == 1)
        // Two ports outside the ranges: the first another app's, the second a busy Flimmer of this kind.
        let script = PretendPort([.success(["app": ["name": "Glimmer"]]), .failure(URLError(.timedOut)), .success(["app": ["name": "Flimmer", "bundleID": "com.brattoo.flimmer.debug"]])])
        let found = await FlimmerSend.find(ports: [9890, 9891], first: 2, rest: 2, transport: { try await script.fetch($0) }, own: .debug)
        #expect(found?.absoluteString == "http://127.0.0.1:9891" && script.asked.count == 3)
    }
}
