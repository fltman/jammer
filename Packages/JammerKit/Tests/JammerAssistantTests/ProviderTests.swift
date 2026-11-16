import Foundation
import JammerAgent
import JammerCore
import Testing
@testable import JammerAssistant

/// The cloud text providers, against a stand-in server that answers in the form each provider's
/// documentation shows. No request leaves the test; no provider has been called for real from here.
extension ModelServices {
@Suite("Text providers", .serialized)
struct ProviderTests {
    let actions = AssistantCatalog.actions

    func context() -> (AssistantContext, [String]) { LocalModelTests().context() }
    func planner(_ id: String, model: String = "m", key: String? = "sk-secret-123", effort: String? = nil) -> CloudPlanner {
        CloudPlanner(provider: TextProvider.named(id)!, model: model, key: { key }, reasoningEffort: effort, session: StandInServer.session)
    }

    @Test("A key never follows a redirect to another host, another port or down to http")
    func redirects() async throws {
        let (c, _) = context()
        let models = #"{"data":[{"id":"some-model","capabilities":{"function_calling":true}}]}"#
        for (id, name) in [("berget", "Berget"), ("grunden", "Grunden"), ("openai", "OpenAI"), ("anthropic", "Anthropic"), ("xai", "xAI"), ("google", "Google"), ("openrouter", "OpenRouter")] {
            let provider = TextProvider.named(id)!
            let home = provider.endpoint.host()!
            for elsewhere in ["https://collector.example/v1", "http://\(home)/v1", "https://\(home):8443/v1"] {
                StandInServer.set(["/models": (200, models), "/chat/completions": (200, "{}"), "/responses": (200, "{}"), "/messages": (200, "{}")])
                StandInServer.redirect(["/models": elsewhere + "/models", "/chat/completions": elsewhere + "/chat/completions",
                                        "/responses": elsewhere + "/responses", "/messages": elsewhere + "/messages"])
                // The model list, with the key.
                await #expect(throws: AssistantError.provider(name, 302, "")) { _ = try await ModelCatalog.list(provider, key: "sk-secret-123", session: StandInServer.session) }
                // A request for a plan.
                do {
                    _ = try await planner(id).plan(goal: "sänk volymen 3 dB", context: c, history: [], actions: actions)
                    Issue.record("\(id) followed a redirect to \(elsewhere)")
                } catch {
                    #expect(error.localizedDescription.contains("302"), "\(error.localizedDescription)")
                }
                // Asked twice, both times at the provider's own address: nothing went to the other one.
                let asked = StandInServer.requests
                #expect(asked.count == 2 && asked.allSatisfy { $0.host == "\(home):0" && $0.scheme == "https" }, "\(id) → \(elsewhere): \(asked.map(\.host))")
            }
        }
        #expect(KeyedRequest.sameOrigin(URL(string: "https://api.berget.ai/v1/models"), URL(string: "https://api.berget.ai/v2/models")))
        #expect(KeyedRequest.sameOrigin(URL(string: "https://api.berget.ai/v1"), URL(string: "https://API.berget.ai:443/x")))
        for other in ["https://berget.ai/v1", "https://api.berget.ai.example/v1", "http://api.berget.ai/v1", "https://api.berget.ai:8443/v1", "https://collector.example/v1"] {
            #expect(!KeyedRequest.sameOrigin(URL(string: "https://api.berget.ai/v1/models"), URL(string: other)), "\(other)")
        }
    }

    /// A request that carries a key goes through KeyedRequest; a call that reaches URLSession directly
    /// would follow redirects with the key in its headers.
    @Test("No request in the sources that hold keys goes to URLSession directly")
    func keyedCallsOnly() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "Sources")
        var keyed = 0
        for case let f as URL in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)! where f.pathExtension == "swift" {
            let s = try String(contentsOf: f, encoding: .utf8)
            let holdsKey = s.contains("forHTTPHeaderField: \"Authorization\"") || s.contains("forHTTPHeaderField: \"x-api-key\"") || f.path.contains("/JammerAssistant/")
            guard holdsKey, f.lastPathComponent != "KeyedRequest.swift" else { continue }
            keyed += 1
            for call in ["session.data(for", "session.data(from", "session.upload(", "session.download(", "session.bytes(", "URLSession.shared.data", "dataTask(with"] {
                #expect(!s.contains(call), "\(f.lastPathComponent) calls \(call)…) itself; use KeyedRequest.data(for:session:)")
            }
        }
        #expect(keyed >= 4)
    }

    @Test("One list: the seven providers by slug, all of them shown, each untried one saying so, none with a model id written in")
    func registry() {
        #expect(TextProvider.all.map(\.id) == ["openrouter", "berget", "grunden", "openai", "anthropic", "xai", "google"])
        #expect(TextProvider.offered().map(\.id) == TextProvider.all.map(\.id))
        // What is true is said: a service that has never answered a real request from Jämmer says so where its key is entered.
        #expect(TextProvider.all.allSatisfy { $0.tried || $0.note.hasSuffix(TextProvider.untried) })
        #expect(TextProvider.all.allSatisfy { !$0.tried || !$0.note.contains(TextProvider.untried) })
        #expect(TextProvider.all.allSatisfy { $0.endpoint.scheme == "https" && !$0.note.isEmpty && $0.id.allSatisfy { $0.isLowercase } })
        #expect(TextProvider.named("berget")?.endpoint.absoluteString == "https://api.berget.ai/v1" && TextProvider.named("grunden")?.endpoint.absoluteString == "https://api.grunden.ai/v1")
        #expect(TextProvider.named("klang") == nil)
    }

    @Test("Berget's and Grunden's lists, as they publish them: text models only, with tools and price read from the list")
    func lists() async throws {
        // Abbreviated from GET https://api.berget.ai/v1/models as it answered on 2026-11-16.
        let berget = #"{"object":"list","data":[{"id":"mistralai/Mistral-Small-3.2-24B-Instruct-2506","name":"Mistral-Small-3.2-24B-Instruct-2506","pricing":{"currency":"EUR","input":0.3,"output":0.3,"unit":"€ / M Token"},"capabilities":{"function_calling":true,"vision":false},"model_type":"text"},{"id":"zai-org/GLM-5.3-Flash","name":"GLM-5.3-Flash","pricing":{"currency":"EUR","input":0.25,"output":0.5},"capabilities":{"function_calling":true},"model_type":"text"},{"id":"KBLab/kb-whisper-large","model_type":"speech-to-text"},{"id":"BAAI/bge-reranker-v2-m3","model_type":"rerank"},{"id":"some/plain-text","model_type":"text","capabilities":{"function_calling":false}}]}"#
        StandInServer.set(["models": (200, berget)])
        let b = try await ModelCatalog.list(TextProvider.named("berget")!, key: nil, session: StandInServer.session)
        #expect(b.map(\.id) == ["mistralai/Mistral-Small-3.2-24B-Instruct-2506", "some/plain-text", "zai-org/GLM-5.3-Flash"])
        #expect(b[0].tools == true && b[1].tools == false && b[2].input == 0.25 && b[2].output == 0.5 && b[2].currency == "EUR" && b[0].name == "Mistral-Small-3.2-24B-Instruct-2506")
        #expect(b[2].estimate?.hasPrefix("About 0.001") == true && b[2].estimate?.hasSuffix("EUR for this request (0.25 in / 0.5 out per million tokens).") == true && b[1].estimate == nil)
        // The list is public: asked without a key, no Authorization header goes along.
        #expect(StandInServer.requests.last?.headers["Authorization"] == nil && StandInServer.requests.last?.host == "api.berget.ai:0")
        // Abbreviated from GET https://api.grunden.ai/v1/models, the same day.
        let grunden = #"{"object":"list","data":[{"id":"gemma-4-26b","type":"chat","capabilities":["chat","thinking_toggle","tools","vision"],"reasoning_levels":["none","high"],"default_reasoning_level":"none","tool_calling":true,"pricing":{"input_per_1m_tokens":{"amount":"0.15","currency":"EUR"},"output_per_1m_tokens":{"amount":"0.45","currency":"EUR"}}},{"id":"glm-5.3","type":"chat","capabilities":["chat","reasoning","tools"],"reasoning_levels":["low","high","max"],"default_reasoning_level":"max","tool_calling":true,"pricing":{"input_per_1m_tokens":{"amount":"0.90","currency":"EUR"},"output_per_1m_tokens":{"amount":"1.80","currency":"EUR"}}},{"id":"bge-m3","type":"embedding"},{"id":"kb-whisper-large","type":"stt"},{"id":"chatterbox","type":"tts"}]}"#
        let g = ModelCatalog.parse(TextProvider.named("grunden")!, Data(grunden.utf8))
        #expect(g.map(\.id) == ["gemma-4-26b", "glm-5.3"] && g.allSatisfy { $0.tools == true } && g[1].reasoningLevels == ["low", "high", "max"] && g[1].input == 0.9 && g[0].output == 0.45)
        // 6,000 tokens in and 500 out at 0.90 and 1.80 per million.
        #expect(g[1].estimate == "About 0.0063 EUR for this request (0.9 in / 1.8 out per million tokens).")
        // The others: what isn't a text model is left out by its name; whether a model calls tools isn't known from the list.
        let openai = ModelCatalog.parse(TextProvider.named("openai")!, Data(#"{"data":[{"id":"alpha-text"},{"id":"text-embedding-x"},{"id":"whisper-1"},{"id":"alpha-image-1"},{"id":"beta-text"}]}"#.utf8))
        #expect(openai.map(\.id) == ["alpha-text", "beta-text"] && openai[0].tools == nil)
        let google = ModelCatalog.parse(TextProvider.named("google")!, Data(#"{"data":[{"id":"models/gemini-x"},{"id":"models/imagen-y"},{"id":"models/embedding-z"}]}"#.utf8))
        #expect(google.map(\.id) == ["gemini-x"])
        let router = ModelCatalog.parse(TextProvider.named("openrouter")!, Data(#"{"data":[{"id":"a/b","name":"A B","pricing":{"prompt":"0.000001","completion":"0.000002"},"supported_parameters":["tools","temperature"]},{"id":"c/d","supported_parameters":["temperature"]}]}"#.utf8))
        #expect(router[0].input == 1 && router[0].output == 2 && router[0].tools == true && router[1].tools == false)
        // A list that can't be had says so in the provider's words.
        StandInServer.set(["models": (401, #"{"error":{"message":"Invalid API key"}}"#)])
        await #expect(throws: AssistantError.provider("Anthropic", 401, #"{"error":{"message":"Invalid API key"}}"#)) {
            try await ModelCatalog.list(TextProvider.named("anthropic")!, key: "bad", session: StandInServer.session)
        }
        #expect(StandInServer.requests.last?.headers["x-api-key"] == "bad" && StandInServer.requests.last?.headers["anthropic-version"] == "2026-10-21")
    }

    @Test("Chat Completions (Berget, Grunden, Google's route): the same request as OpenRouter, the key as a bearer token, Grunden's reasoning kept low")
    func chatCompletions() async throws {
        let (c, tracks) = context()
        StandInServer.set(["chat/completions": (200, #"{"choices":[{"message":{"content":"Jag tar bort brummet.","reasoning_content":"…","tool_calls":[{"id":"1","type":"function","function":{"name":"restore","arguments":"{\"kind\":\"dehum\",\"tracks\":[\"2\"]}"}}]}}],"usage":{"prompt_tokens":5000}}"#)])
        let plan = try await planner("grunden", model: "glm-5.3", effort: "low").plan(goal: "ta bort brummet på talare 2", context: c, history: [], actions: actions)
        #expect(plan.steps == [PlannedStep(op: "restore", params: ["kind": .string("dehum"), "tracks": .array([.string(tracks[1])])])] && plan.reply == "Jag tar bort brummet.")
        let asked = try #require(StandInServer.requests.last)
        #expect(asked.host == "api.grunden.ai:0" && asked.path == "/v1/chat/completions" && asked.headers["Authorization"] == "Bearer sk-secret-123")
        #expect(asked.body["model"] as? String == "glm-5.3" && asked.body["reasoning_effort"] as? String == "low" && (asked.body["tools"] as? [Any])?.count == actions.count)
        // The key is in the header and nowhere else.
        #expect(!String(describing: asked.body).contains("sk-secret-123") && !asked.path.contains("sk-secret"))
        _ = try await planner("berget", model: "zai-org/GLM-5.3-Flash").plan(goal: "ta bort brummet på talare 2", context: c, history: [], actions: actions)
        let b = try #require(StandInServer.requests.last)
        #expect(b.host == "api.berget.ai:0" && b.body["reasoning_effort"] == nil && b.headers["HTTP-Referer"] == nil)
        _ = try await planner("google", model: "gemini-x").plan(goal: "ta bort brummet på talare 2", context: c, history: [], actions: actions)
        #expect(StandInServer.requests.last?.path == "/v1beta/openai/chat/completions")
    }

    @Test("Responses (OpenAI, xAI): flat tools in, function_call items out; reasoning items are passed over")
    func responses() async throws {
        let (c, _) = context()
        StandInServer.set(["responses": (200, #"{"id":"resp_1","output":[{"type":"reasoning","summary":[]},{"type":"function_call","call_id":"call_1","name":"normalize","arguments":"{\"target\":\"loudness\",\"level\":-16}"},{"type":"function_call","call_id":"call_2","name":"nope","arguments":"{}"},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Jag normaliserar."}]}]}"#)])
        for id in ["openai", "xai"] {
            let plan = try await planner(id, model: "some-model").plan(goal: "normalisera till -16 LUFS", context: c, history: [], actions: actions)
            #expect(plan.steps == [PlannedStep(op: "normalize", params: ["level": .number(-16), "target": .string("loudness")])] && plan.reply == "Jag normaliserar." && plan.dropped == ["nope"])
            let asked = try #require(StandInServer.requests.last)
            #expect(asked.path == "/v1/responses" && asked.host == (id == "openai" ? "api.openai.com:0" : "api.x.ai:0") && asked.headers["Authorization"] == "Bearer sk-secret-123")
            let tools = asked.body["tools"] as? [[String: Any]] ?? []
            #expect(tools.count == actions.count && tools.allSatisfy { $0["type"] as? String == "function" && $0["name"] is String && $0["parameters"] is [String: Any] && $0["function"] == nil })
            #expect(asked.body["instructions"] is String && asked.body["input"] is String && asked.body["store"] as? Bool == false && asked.body["messages"] == nil)
        }
    }

    @Test("Messages (Anthropic): tools with input_schema in, tool_use blocks out, the key in x-api-key")
    func anthropic() async throws {
        let (c, tracks) = context()
        StandInServer.set(["messages": (200, #"{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"text","text":"Jag sänker Erik."},{"type":"tool_use","id":"toolu_1","name":"restore","input":{"kind":"dehum","tracks":["Erik"]}}],"stop_reason":"tool_use"}"#)])
        let plan = try await planner("anthropic", model: "some-model").plan(goal: "sänk Erik 3 dB", context: c, history: [], actions: actions)
        #expect(plan.steps == [PlannedStep(op: "restore", params: ["kind": .string("dehum"), "tracks": .array([.string(tracks[1])])])] && plan.reply == "Jag sänker Erik.")
        let asked = try #require(StandInServer.requests.last)
        #expect(asked.path == "/v1/messages" && asked.headers["x-api-key"] == "sk-secret-123" && asked.headers["anthropic-version"] == "2026-10-21" && asked.headers["Authorization"] == nil)
        let tools = asked.body["tools"] as? [[String: Any]] ?? []
        #expect(tools.count == actions.count && tools.allSatisfy { $0["name"] is String && $0["input_schema"] is [String: Any] && $0["type"] == nil })
        #expect(asked.body["system"] is String && asked.body["max_tokens"] as? Int == 2_048 && (asked.body["messages"] as? [[String: Any]])?.first?["role"] as? String == "user")
    }

    @Test("No key: no request. A provider's error: its own words and status. An answer in another form: said, not guessed")
    func failures() async throws {
        let (c, _) = context()
        StandInServer.set(["chat/completions": (200, "{}")])
        await #expect(throws: AssistantError.missingKey("Berget")) { try await planner("berget", key: nil).plan(goal: "sänk volymen 3 dB", context: c, history: [], actions: actions) }
        await #expect(throws: AssistantError.missingKey("Anthropic")) { try await planner("anthropic", key: "").plan(goal: "sänk volymen 3 dB", context: c, history: [], actions: actions) }
        #expect(StandInServer.requests.isEmpty && AssistantError.missingKey("Berget").localizedDescription == "Add your Berget key in the assistant's settings to use it.")
        let said = #"{"error":{"message":"The model `glm-9` does not exist or you do not have access to it.","code":"model_not_found"}}"#
        for (id, route) in [("grunden", "chat/completions"), ("openai", "responses"), ("anthropic", "messages")] {
            StandInServer.set([route: (404, said)])
            let name = TextProvider.named(id)!.name
            await #expect(throws: AssistantError.provider(name, 404, said)) { try await planner(id).plan(goal: "sänk volymen 3 dB", context: c, history: [], actions: actions) }
            #expect(AssistantError.provider(name, 404, said).localizedDescription == "\(name) answered 404: \(said)")
            StandInServer.set([route: (200, #"{"unexpected":true}"#)])
            await #expect(throws: AssistantError.badResponse) { try await planner(id).plan(goal: "sänk volymen 3 dB", context: c, history: [], actions: actions) }
        }
        #expect(planner("berget").paid && planner("berget", model: "x/y").id == "berget:x/y")
    }
}
}
