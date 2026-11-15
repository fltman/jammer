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
        let session = LanguageModelSession(instructions: AssistantPrompt.instructions(actions))
        let response = try await session.respond(to: AssistantPrompt.prompt(goal: goal, context: context, history: history),
                                                 schema: try Self.schema(actions),
                                                 options: GenerationOptions(samplingMode: .greedy))
        return try Self.decode(response.content, actions: actions, context: context)
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
        guard let key = key(), !key.isEmpty else { throw AssistantError.noKey }
        var req = URLRequest(url: endpoint.appending(path: "chat/completions"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://jammer.brattoo.com", forHTTPHeaderField: "HTTP-Referer")
        req.setValue("Jammer", forHTTPHeaderField: "X-Title")
        req.httpBody = try JSONSerialization.data(withJSONObject: requestBody(goal: goal, context: context, history: history, actions: actions))
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AssistantError.http(status, String(decoding: data.prefix(300), as: UTF8.self)) }
        return try Self.decode(data, actions: actions)
    }

    static func decode(_ data: Data, actions: [AssistantAction]) throws -> AssistantPlan {
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
            return PlannedStep(op: action.name, params: params, why: "")
        }
        return PlanParser.validate(AssistantPlan(reply: msg.content ?? "", steps: steps, dropped: dropped, cost: raw.usage?.cost), actions: actions)
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
