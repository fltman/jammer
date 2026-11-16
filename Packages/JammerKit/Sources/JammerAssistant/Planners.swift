import Foundation
import FoundationModels
import JammerAgent

/// Apple's on-device model (Foundation Models): free, private, works offline. The plan
/// comes back as structured output whose schema is built from the catalogue at run time,
/// so `op` can only be a real action name.
public struct OnDevicePlanner: AssistantPlanner {
    public init() {}
    public var id: String { "apple-on-device" }
    public var paid: Bool { false }

    public static var availability: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(let reason): String(describing: reason)
        }
    }

    public static func supports(_ locale: Locale) -> Bool { SystemLanguageModel.default.supportsLocale(locale) }

    static func schema(_ actions: [AssistantAction]) throws -> GenerationSchema {
        let arg = DynamicGenerationSchema(name: "Arg", properties: [
            .init(name: "name", description: "Parameter name from the action's list.", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "value", description: "The value as text (numbers like -16 or 0.5; lists comma-separated).", schema: DynamicGenerationSchema(type: String.self)),
        ])
        let step = DynamicGenerationSchema(name: "Step", properties: [
            .init(name: "op", schema: DynamicGenerationSchema(name: "Op", anyOf: actions.map(\.name))),
            .init(name: "args", schema: DynamicGenerationSchema(arrayOf: arg, maximumElements: 8)),
            .init(name: "why", description: "One short sentence.", schema: DynamicGenerationSchema(type: String.self)),
        ])
        let plan = DynamicGenerationSchema(name: "Plan", properties: [
            .init(name: "reply", description: "Short answer to the user in their language.", schema: DynamicGenerationSchema(type: String.self)),
            .init(name: "steps", schema: DynamicGenerationSchema(arrayOf: step, maximumElements: 10)),
        ])
        return try GenerationSchema(root: plan, dependencies: [])
    }

    public func plan(goal: String, context: AssistantContext, history: [(user: String, reply: String)],
                     actions: [AssistantAction]) async throws -> AssistantPlan {
        if let why = Self.availability { throw AssistantError.unavailable(why) }
        if let reply = PlanParser.guardrail(goal) { return AssistantPlan(reply: reply, steps: []) }
        let session = LanguageModelSession(instructions: AssistantPrompt.instructions(actions))
        let response = try await session.respond(to: AssistantPrompt.prompt(goal: goal, context: context, history: history),
                                                 schema: try Self.schema(actions),
                                                 options: GenerationOptions(samplingMode: .greedy))
        return PlanParser.augment(goal: goal, plan: try Self.decode(response.content, actions: actions, context: context))
    }

    static func decode(_ content: GeneratedContent, actions: [AssistantAction], context: AssistantContext? = nil) throws -> AssistantPlan {
        struct Raw: Decodable {
            struct Arg: Decodable { var name: String; var value: String }
            struct S: Decodable { var op: String; var args: [Arg]?; var why: String? }
            var reply: String?
            var steps: [S]?
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: Data(content.jsonString.utf8)) else { throw AssistantError.badResponse }
        var dropped: [String] = []
        let steps = (raw.steps ?? []).compactMap { s -> PlannedStep? in
            guard let p = PlanParser.typed(op: s.op, args: (s.args ?? []).map { ($0.name, $0.value) }, why: s.why ?? "", actions: actions, context: context) else {
                dropped.append(s.op); return nil
            }
            return p
        }
        return PlanParser.validate(AssistantPlan(reply: raw.reply ?? "", steps: steps, dropped: dropped), actions: actions)
    }
}

/// A model on OpenRouter (or a compatible endpoint) with the user's own key, through
/// tool calling. Paid: the app shows the price and asks before every request.
public struct OpenRouterPlanner: AssistantPlanner {
    public var endpoint: URL
    public var model: String
    public var key: @Sendable () -> String?
    public var session: URLSession

    public init(endpoint: URL = URL(string: "https://openrouter.ai/api/v1")!, model: String,
                key: @escaping @Sendable () -> String?, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.model = model
        self.key = key
        self.session = session
    }

    public var id: String { "openrouter:\(model)" }
    public var paid: Bool { true }

    /// One tool call as a step. Jämmer's own operations go through the same reading of values as the
    /// on-device model's answers (track numbers to ids, clock times, ranges); a sibling's are passed as they came.
    static func step(_ action: AssistantAction, _ params: [String: JSONValue], _ context: AssistantContext?) -> PlannedStep {
        if case .sibling = action.kind { return PlannedStep(op: action.name, params: params, why: "") }
        return PlanParser.typed(op: action.name, json: params, why: "", actions: [action], context: context) ?? PlannedStep(op: action.name, params: params, why: "")
    }

    /// Tool names allowed by the providers: ^[a-zA-Z0-9_-]{1,64}$.
    public static func toolName(_ action: AssistantAction) -> String {
        let raw: String
        if case .sibling(let slug, _, _) = action.kind { raw = "\(slug)_\(action.name)" } else { raw = action.name }
        return String(raw.map { $0.isLetter && $0.isASCII || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" }.prefix(64))
    }

    public static func tools(_ actions: [AssistantAction]) -> [[String: Any]] {
        actions.map { a in
            var props: [String: Any] = [:]
            for p in a.params { props[p.name] = p.schema }
            return ["type": "function", "function": [
                "name": toolName(a), "description": a.description,
                "parameters": ["type": "object", "properties": props, "required": a.params.filter(\.required).map(\.name)],
            ] as [String: Any]]
        }
    }

    public func requestBody(goal: String, context: AssistantContext, history: [(user: String, reply: String)],
                            actions: [AssistantAction]) -> [String: Any] {
        let system = AssistantPrompt.preamble + "\nCall the tools in the order they should run; each call is one step. Also reply with a short message."
        return ["model": model, "tool_choice": "auto", "tools": Self.tools(actions),
                "messages": [["role": "system", "content": system],
                             ["role": "user", "content": AssistantPrompt.prompt(goal: goal, context: context, history: history)]]]
    }

    public func plan(goal: String, context: AssistantContext, history: [(user: String, reply: String)],
                     actions: [AssistantAction]) async throws -> AssistantPlan {
        if let reply = PlanParser.guardrail(goal) { return AssistantPlan(reply: reply, steps: []) }
        guard let key = key(), !key.isEmpty else { throw AssistantError.noKey }
        var req = URLRequest(url: endpoint.appending(path: "chat/completions"))
        req.timeoutInterval = 30 // offline or stalled: an error in the panel, never a hang
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://jammer.brattoo.com", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("Jammer", forHTTPHeaderField: "X-Title")
        req.httpBody = try JSONSerialization.data(withJSONObject: requestBody(goal: goal, context: context, history: history, actions: actions))
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AssistantError.http(status, String(decoding: data.prefix(300), as: UTF8.self)) }
        return PlanParser.augment(goal: goal, plan: try Self.decode(data, actions: actions, context: context))
    }

    static func decode(_ data: Data, actions: [AssistantAction], context: AssistantContext? = nil) throws -> AssistantPlan {
        struct Raw: Decodable {
            struct Call: Decodable { struct F: Decodable { var name: String; var arguments: String }; var function: F }
            struct Msg: Decodable { var content: String?; var tool_calls: [Call]? }
            struct Choice: Decodable { var message: Msg }
            struct Usage: Decodable { var cost: Double? }
            var choices: [Choice]
            var usage: Usage?
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data), let msg = raw.choices.first?.message else { throw AssistantError.badResponse }
        var dropped: [String] = []
        let steps = (msg.tool_calls ?? []).compactMap { call -> PlannedStep? in
            guard let action = actions.first(where: { toolName($0) == call.function.name }) else { dropped.append(call.function.name); return nil }
            let obj = (try? JSONSerialization.jsonObject(with: Data(call.function.arguments.utf8))) as? [String: Any] ?? [:]
            var params: [String: JSONValue] = [:]
            for (k, v) in obj { if let j = JSONValue(v) { params[k] = j } }
            return Self.step(action, params, context)
        }
        return PlanParser.validate(AssistantPlan(reply: msg.content ?? "", steps: steps, dropped: dropped, cost: raw.usage?.cost), actions: actions)
    }
}

/// A model behind a Chat Completions endpoint on this Mac (Ollama; an MLX server): free, and
/// nothing leaves the machine, so it isn't asked about like a paid request. The endpoint has to
/// be this Mac itself; anything else is refused rather than quietly sent somewhere.
/// `tool_choice` is left out: Ollama's compatible endpoint doesn't take it.
public struct LocalServerPlanner: AssistantPlanner {
    public var endpoint: URL
    public var model: String
    /// "ollama" or "mlx", for the id stored with a plan.
    public var kind: String
    public var session: URLSession
    /// A local model can take a while to load into memory the first time.
    public var timeout: TimeInterval

    public init(endpoint: URL = Ollama.base.appending(path: "v1"), model: String, kind: String = "ollama", session: URLSession = .shared, timeout: TimeInterval = 180) {
        self.endpoint = endpoint
        self.model = model
        self.kind = kind
        self.session = session
        self.timeout = timeout
    }

    public var id: String { "\(kind):\(model)" }
    public var paid: Bool { false }

    public static func isThisMac(_ url: URL) -> Bool {
        guard url.scheme == "http" || url.scheme == "https", let host = url.host()?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }

    public func requestBody(goal: String, context: AssistantContext, history: [(user: String, reply: String)], actions: [AssistantAction]) -> [String: Any] {
        var body = OpenRouterPlanner(endpoint: endpoint, model: model, key: { nil }).requestBody(goal: goal, context: context, history: history, actions: actions)
        body["tool_choice"] = nil
        body["stream"] = false
        return body
    }

    public func plan(goal: String, context: AssistantContext, history: [(user: String, reply: String)],
                     actions: [AssistantAction]) async throws -> AssistantPlan {
        if let reply = PlanParser.guardrail(goal) { return AssistantPlan(reply: reply, steps: []) }
        guard Self.isThisMac(endpoint) else { throw AssistantError.local("A local model's address has to be on this Mac (127.0.0.1); \(endpoint.host() ?? "that address") isn't.") }
        var req = URLRequest(url: endpoint.appending(path: "chat/completions"))
        req.timeoutInterval = timeout
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: requestBody(goal: goal, context: context, history: history, actions: actions))
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) } catch {
            throw AssistantError.local("The local model server at \(endpoint.host() ?? "127.0.0.1"):\(endpoint.port ?? 80) didn't answer (\(error.localizedDescription)).")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AssistantError.http(status, String(decoding: data.prefix(300), as: UTF8.self)) }
        var plan = try OpenRouterPlanner.decode(data, actions: actions, context: context)
        plan.reply = Self.withoutThinking(plan.reply)
        plan.cost = nil
        return PlanParser.augment(goal: goal, plan: plan)
    }

    /// Some local models put their reasoning in the reply between <think> tags; that isn't the answer.
    static func withoutThinking(_ text: String) -> String {
        var out = text
        while let a = out.range(of: "<think>"), let b = out.range(of: "</think>", range: a.upperBound..<out.endIndex) { out.removeSubrange(a.lowerBound..<b.upperBound) }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A model in Ollama on this Mac, through Ollama's own chat API. Its OpenAI-style endpoint would do
/// for the chat itself, but not for two things that decide whether a small model can plan at all:
/// the context has to hold Jämmer's whole list of tools (Ollama's default of 4,096 tokens cuts it
/// off), and a model that "thinks" before it answers takes minutes per request unless told not to.
public struct OllamaPlanner: AssistantPlanner {
    public var model: String
    public var session: URLSession
    public var timeout: TimeInterval
    /// Tokens of context asked for: the tools and the document's description fit in this.
    public var context: Int

    public init(model: String, session: URLSession = .shared, timeout: TimeInterval = 240, context: Int = 16_384) {
        self.model = model
        self.session = session
        self.timeout = timeout
        self.context = context
    }

    public var id: String { "ollama:\(model)" }
    public var paid: Bool { false }

    public func requestBody(goal: String, context c: AssistantContext, history: [(user: String, reply: String)], actions: [AssistantAction], thinks: Bool) -> [String: Any] {
        var body = OpenRouterPlanner(model: model, key: { nil }).requestBody(goal: goal, context: c, history: history, actions: actions)
        body["tool_choice"] = nil
        body["stream"] = false
        body["options"] = ["num_ctx": context, "temperature": 0] as [String: Any]
        if thinks { body["think"] = false }
        return body
    }

    public func plan(goal: String, context c: AssistantContext, history: [(user: String, reply: String)],
                     actions: [AssistantAction]) async throws -> AssistantPlan {
        if let reply = PlanParser.guardrail(goal) { return AssistantPlan(reply: reply, steps: []) }
        // Said before the request, not found out from a confusing answer: the model has to be one that calls tools.
        guard let caps = await Ollama.capabilities(model, session: session) else {
            throw AssistantError.local(await Ollama.version(session: session) == nil ? "Ollama isn't running on this Mac." : "Ollama has no model called \(model).")
        }
        guard caps.contains("tools") else { throw AssistantError.local("\(model) can't call tools, which the assistant needs. Pick a model that Ollama lists with tools.") }
        var req = URLRequest(url: Ollama.base.appending(path: "api/chat"))
        req.timeoutInterval = timeout
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: requestBody(goal: goal, context: c, history: history, actions: actions, thinks: caps.contains("thinking")))
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) } catch {
            throw AssistantError.local("Ollama didn't answer (\(error.localizedDescription)).")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AssistantError.http(status, String(decoding: data.prefix(300), as: UTF8.self)) }
        return PlanParser.augment(goal: goal, plan: try Self.decode(data, actions: actions, context: c))
    }

    /// Ollama's own shape: `message.tool_calls[].function` with `arguments` as an object (not a string).
    static func decode(_ data: Data, actions: [AssistantAction], context: AssistantContext? = nil) throws -> AssistantPlan {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let message = root["message"] as? [String: Any] else { throw AssistantError.badResponse }
        var dropped: [String] = []
        let calls = message["tool_calls"] as? [[String: Any]] ?? []
        let steps = calls.compactMap { call -> PlannedStep? in
            guard let f = call["function"] as? [String: Any], let name = f["name"] as? String else { return nil }
            guard let action = actions.first(where: { OpenRouterPlanner.toolName($0) == name }) else { dropped.append(name); return nil }
            var args = f["arguments"] as? [String: Any] ?? [:]
            // Some models send the arguments as text all the same.
            if let text = f["arguments"] as? String, let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] { args = obj }
            var params: [String: JSONValue] = [:]
            for (k, v) in args { if let j = JSONValue(v) { params[k] = j } }
            return OpenRouterPlanner.step(action, params, context)
        }
        let reply = LocalServerPlanner.withoutThinking(message["content"] as? String ?? "")
        return PlanParser.validate(AssistantPlan(reply: reply, steps: steps, dropped: dropped), actions: actions)
    }
}

/// What Jämmer asks of an Ollama server on this Mac besides the chat itself.
public enum Ollama {
    public static let base = URL(string: "http://127.0.0.1:11434")!

    static func get(_ path: String, session: URLSession, timeout: TimeInterval = 3) async -> Data? {
        var req = URLRequest(url: base.appending(path: path))
        req.timeoutInterval = timeout
        guard let (data, response) = try? await session.data(for: req), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// The server's version, or nil when none is running here.
    public static func version(session: URLSession = .shared) async -> String? {
        guard let d = await get("api/version", session: session) else { return nil }
        return ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["version"] as? String
    }

    /// The models that are installed (Jämmer never fetches one).
    public static func models(session: URLSession = .shared) async -> [String] {
        guard let d = await get("api/tags", session: session), let list = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["models"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["name"] as? String }.sorted()
    }

    /// What the server says the model can do (`capabilities` of /api/show: "completion", "tools",
    /// "thinking", "vision"), or nil when it has no such model or isn't running.
    public static func capabilities(_ model: String, session: URLSession = .shared) async -> [String]? {
        var req = URLRequest(url: base.appending(path: "api/show"))
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        guard let (data, response) = try? await session.data(for: req), (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["capabilities"] as? [String] ?? []
    }

    public static func supportsTools(_ model: String, session: URLSession = .shared) async -> Bool {
        await capabilities(model, session: session)?.contains("tools") ?? false
    }
}

/// For tests and for the evaluation's baseline: answers from a table.
public struct ScriptedPlanner: AssistantPlanner {
    public var answers: [String: AssistantPlan]
    public init(_ answers: [String: AssistantPlan]) { self.answers = answers }
    public var id: String { "scripted" }
    public var paid: Bool { false }
    public func plan(goal: String, context: AssistantContext, history: [(user: String, reply: String)],
                     actions: [AssistantAction]) async throws -> AssistantPlan {
        PlanParser.validate(answers[goal] ?? AssistantPlan(reply: "?", steps: []), actions: actions)
    }
}
