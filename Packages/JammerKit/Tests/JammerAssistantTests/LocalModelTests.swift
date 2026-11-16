import Foundation
import JammerAgent
import JammerCore
import Testing
@testable import JammerAssistant

/// A stand-in for a model server: answers by the end of the request's path, and keeps what it was asked.
final class StandInServer: URLProtocol, @unchecked Sendable {
    struct Asked { var path: String; var host: String; var body: [String: Any]; var headers: [String: String]; var scheme = "" }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: (Int, Data)] = [:]
    nonisolated(unsafe) private static var asked: [Asked] = []
    /// Path ending → where the server says to go instead (HTTP 302), as a provider or a proxy might.
    nonisolated(unsafe) private static var redirects: [String: String] = [:]
    static func redirect(_ r: [String: String]) { lock.withLock { redirects = r } }

    static func set(_ r: [String: (Int, String)]) { lock.withLock { routes = r.mapValues { ($0.0, Data($0.1.utf8)) }; asked = []; redirects = [:] } }
    static var requests: [Asked] { lock.withLock { asked } }
    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StandInServer.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
        }
        let url = request.url!
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let route = Self.lock.withLock { () -> (Int, Data)? in
            Self.asked.append(Asked(path: url.path, host: "\(url.host() ?? ""):\(url.port ?? 0)", body: body, headers: request.allHTTPHeaderFields ?? [:], scheme: url.scheme ?? ""))
            return Self.routes.first { url.path.hasSuffix($0.key) }?.value
        }
        // A redirect only from where the request first went, so that a followed one gets its answer.
        if let to = Self.lock.withLock({ Self.redirects.first { url.path.hasSuffix($0.key) && !$0.value.hasPrefix("\(url.scheme ?? "")://\(url.host() ?? "-")\(url.port.map { ":\($0)" } ?? "")/") }?.value }), let target = URL(string: to) {
            var next = request
            next.url = target
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": to])!
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            // Not followed: the redirect itself is the answer.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        guard let route else {
            // No such server: what a connection that is refused looks like to the caller.
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: route.0, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: route.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Everything that talks to the stand-in server takes turns: it is one server with one set of answers.
@Suite("Model services", .serialized)
struct ModelServices {}

extension ModelServices {
@Suite("Models on this Mac", .serialized)
struct LocalModelTests {
    let actions = AssistantCatalog.actions

    func context() -> (AssistantContext, [String]) {
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: 48_000 * 60, chunks: [], bext: nil, ixml: nil, markers: [])
        var p = Project(source: SourceRef(name: "Anna", path: "/dev/null", info: info))
        let b = SourceRef(name: "Erik", path: "/dev/null", info: info)
        p.sources.append(b)
        p.tracks.append(Track(name: "Erik", clips: [Clip(sourceID: b.id, start: 0, length: 48_000 * 60)]))
        return (AssistantContext(project: p, selection: nil, playhead: 0), p.tracks.map(\.id.uuidString))
    }

    @Test("Ollama: asked in its own form, with room for the tools and without thinking; a track's number becomes its id")
    func ollama() async throws {
        let (c, tracks) = context()
        StandInServer.set([
            "api/show": (200, #"{"capabilities":["completion","tools","thinking"]}"#),
            "api/chat": (200, #"{"message":{"role":"assistant","content":"<think>hm</think>Jag tar bort brummet.","tool_calls":[{"function":{"name":"restore","arguments":{"kind":"dehum","tracks":"2"}}},{"function":{"name":"gain","arguments":"{\"db\":-3}"}},{"function":{"name":"nope","arguments":{}}}]}}"#),
        ])
        let planner = OllamaPlanner(model: "qwen3:8b", session: StandInServer.session)
        let plan = try await planner.plan(goal: "ta bort brummet på talare 2 och sänk 3 dB", context: c, history: [], actions: actions)
        #expect(plan.steps == [PlannedStep(op: "restore", params: ["kind": .string("dehum"), "tracks": .array([.string(tracks[1])])]),
                               PlannedStep(op: "gain", params: ["db": .number(-3)])])
        #expect(plan.reply == "Jag tar bort brummet." && plan.dropped == ["nope"] && plan.cost == nil && !planner.paid && planner.id == "ollama:qwen3:8b")
        let chat = try #require(StandInServer.requests.last { $0.path.hasSuffix("api/chat") })
        #expect(chat.host == "127.0.0.1:11434" && chat.headers["Authorization"] == nil)
        #expect(chat.body["tool_choice"] == nil && chat.body["stream"] as? Bool == false && chat.body["think"] as? Bool == false)
        #expect((chat.body["options"] as? [String: Any])?["num_ctx"] as? Int == 16_384)
        #expect((chat.body["tools"] as? [[String: Any]])?.count == actions.count)
        // A model that doesn't think isn't told not to (Ollama refuses the setting for those).
        StandInServer.set(["api/show": (200, #"{"capabilities":["completion","tools"]}"#), "api/chat": (200, #"{"message":{"content":"Klart.","tool_calls":[]}}"#)])
        _ = try await planner.plan(goal: "sänk volymen 3 dB", context: c, history: [], actions: actions)
        let plain = try #require(StandInServer.requests.last { $0.path.hasSuffix("api/chat") })
        #expect(!plain.body.keys.contains("think"))
    }

    @Test("Ollama: what can't work is said before the request: no tools, no such model, no server; its own error comes through word for word")
    func ollamaRefusals() async throws {
        let (c, _) = context()
        let planner = OllamaPlanner(model: "gemma3:4b", session: StandInServer.session)
        func failure() async -> String {
            do { _ = try await planner.plan(goal: "sänk volymen 3 dB", context: c, history: [], actions: actions); return "no error" } catch { return error.localizedDescription }
        }
        StandInServer.set(["api/show": (200, #"{"capabilities":["completion","vision"]}"#)])
        var said = await failure()
        #expect(said.contains("can't call tools"))
        #expect(!StandInServer.requests.contains { $0.path.hasSuffix("api/chat") })
        StandInServer.set(["api/show": (404, #"{"error":"model 'gemma3:4b' not found"}"#), "api/version": (200, #"{"version":"0.15.6"}"#)])
        said = await failure()
        #expect(said == "Ollama has no model called gemma3:4b.")
        StandInServer.set([:])
        said = await failure()
        #expect(said == "Ollama isn't running on this Mac.")
        StandInServer.set(["api/show": (200, #"{"capabilities":["tools"]}"#), "api/chat": (500, #"{"error":"model requires more system memory (9.1 GiB) than is available (4.0 GiB)"}"#)])
        said = await failure()
        #expect(said.contains("500") && said.contains("model requires more system memory (9.1 GiB) than is available (4.0 GiB)"))
        StandInServer.set(["api/show": (200, #"{"capabilities":["tools"]}"#), "api/chat": (200, "not json")])
        said = await failure()
        #expect(said == AssistantError.badResponse.localizedDescription)
    }

    @Test("Ollama: what is installed, and what each model can do, comes from the server")
    func ollamaDiscovery() async {
        StandInServer.set(["api/version": (200, #"{"version":"0.15.6"}"#),
                           "api/tags": (200, #"{"models":[{"name":"qwen3:8b"},{"name":"gemma3:4b"},{"name":"bge-m3:latest"}]}"#),
                           "api/show": (200, #"{"capabilities":["completion","tools","thinking"]}"#)])
        let s = StandInServer.session
        let version = await Ollama.version(session: s), models = await Ollama.models(session: s)
        let tools = await Ollama.supportsTools("qwen3:8b", session: s), caps = await Ollama.capabilities("qwen3:8b", session: s)
        #expect(version == "0.15.6" && models == ["bge-m3:latest", "gemma3:4b", "qwen3:8b"] && tools && caps == ["completion", "tools", "thinking"])
        StandInServer.set([:])
        let noVersion = await Ollama.version(session: s), noModels = await Ollama.models(session: s), noTools = await Ollama.supportsTools("qwen3:8b", session: s)
        #expect(noVersion == nil && noModels.isEmpty && !noTools)
    }

    @Test("A Chat Completions server on this Mac: free, no key, no tool_choice; an address that isn't this Mac is refused")
    func localServer() async throws {
        let (c, _) = context()
        StandInServer.set(["chat/completions": (200, #"{"choices":[{"message":{"content":"Ok.","tool_calls":[{"function":{"name":"normalize","arguments":"{\"target\":\"loudness\",\"level\":-16}"}}]}}],"usage":{"cost":0.5}}"#)])
        let planner = LocalServerPlanner(endpoint: URL(string: "http://127.0.0.1:8080/v1")!, model: "mlx-community/x", kind: "mlx", session: StandInServer.session)
        let plan = try await planner.plan(goal: "normalisera till -16 LUFS", context: c, history: [], actions: actions)
        #expect(plan.steps == [PlannedStep(op: "normalize", params: ["level": .number(-16), "target": .string("loudness")])] && plan.cost == nil && !planner.paid && planner.id == "mlx:mlx-community/x")
        let asked = try #require(StandInServer.requests.last)
        #expect(asked.host == "127.0.0.1:8080" && asked.body["tool_choice"] == nil && asked.headers["Authorization"] == nil)
        for (address, local) in [("http://localhost:8080/v1", true), ("http://[::1]:8080/v1", true), ("http://192.168.1.20:8080/v1", false),
                                 ("https://example.com/v1", false), ("http://127.0.0.1.example.com/v1", false), ("file:///tmp/v1", false)] {
            #expect(LocalServerPlanner.isThisMac(URL(string: address)!) == local, "\(address)")
        }
        let away = LocalServerPlanner(endpoint: URL(string: "http://192.168.1.20:8080/v1")!, model: "x", session: StandInServer.session)
        let before = StandInServer.requests.count
        await #expect(throws: AssistantError.self) { try await away.plan(goal: "normalisera till -16 LUFS", context: c, history: [], actions: actions) }
        #expect(StandInServer.requests.count == before)
    }
}
}
