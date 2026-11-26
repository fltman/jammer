import Foundation
import Network
import Testing
@testable import JammerCore

/// A redirect from a server on this Mac isn't remembered (COMFORT.md 620092e): the next request asks that server again.
@Suite("Requests to this Mac keep nothing", .serialized)
struct LocalSessionTests {
    /// A server on 127.0.0.1 that answers each request with the next of `answers` (status and headers), counting them.
    final class Server: @unchecked Sendable {
        let listener: NWListener
        private let lock = NSLock()
        private var answers: [(Int, [String: String], String)]
        private(set) var hits = 0
        var port: UInt16 { listener.port?.rawValue ?? 0 }

        init(_ answers: [(Int, [String: String], String)]) throws {
            self.answers = answers
            let p = NWParameters.tcp
            p.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: p)
            listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
        }

        func start() async throws {
            let ready = AsyncStream<Void> { go in
                listener.stateUpdateHandler = { if case .ready = $0 { go.yield(); go.finish() } }
            }
            listener.start(queue: .global())
            for await _ in ready { break }
        }

        func stop() { listener.cancel() }

        private func serve(_ c: NWConnection) {
            c.start(queue: .global())
            c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] _, _, _, _ in
                guard let self else { return }
                self.lock.lock()
                self.hits += 1
                let (status, headers, body) = self.answers.count > 1 ? self.answers.removeFirst() : self.answers[0]
                self.lock.unlock()
                var head = "HTTP/1.1 \(status) X\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n"
                for (k, v) in headers { head += "\(k): \(v)\r\n" }
                c.send(content: Data((head + "\r\n" + body).utf8), completion: .contentProcessed { _ in c.cancel() })
            }
        }
    }

    /// Two requests to the first server, which answers a permanent redirect to the second once and then itself.
    func twice(_ session: URLSession) async throws -> (first: String, second: String, firstServerHits: Int) {
        let target = try Server([(200, [:], "moved")])
        try await target.start()
        let origin = try Server([(301, ["Location": "http://127.0.0.1:\(target.port)/new"], ""), (200, [:], "here")])
        try await origin.start()
        defer { origin.stop(); target.stop() }
        let url = URL(string: "http://127.0.0.1:\(origin.port)/old")!
        let a = String(decoding: try await session.data(from: url).0, as: UTF8.self)
        let b = String(decoding: try await session.data(from: url).0, as: UTF8.self)
        return (a, b, origin.hits)
    }

    @Test("Through LocalSession the second request asks the first server again, not the address it once redirected to")
    func notRemembered() async throws {
        let r = try await twice(URLSession(configuration: LocalSession.configuration))
        #expect(r.first == "moved")
        #expect(r.second == "here" && r.firstServerHits == 2)
        #expect(LocalSession.shared.configuration.urlCache == nil)
        #expect(LocalSession.isThisMac(URL(string: "http://127.0.0.1:9003/x")) && LocalSession.isThisMac(URL(string: "http://localhost:11434")))
        #expect(!LocalSession.isThisMac(URL(string: "https://api.openai.com/v1")))
    }

    @Test("The control: a session with a cache, in memory only, does remember the redirect (what the lesson was about)")
    func control() async throws {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = URLCache(memoryCapacity: 1 << 20, diskCapacity: 0)
        let r = try await twice(URLSession(configuration: c))
        #expect(r.first == "moved" && r.second == "moved" && r.firstServerHits == 1)
    }
}
