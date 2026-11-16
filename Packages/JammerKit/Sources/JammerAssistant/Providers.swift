import Foundation
import JammerAgent

/// The text model services the assistant can use with the user's own key. One list drives the
/// settings, the key fields, the model pickers, the "key missing" messages and the manual
/// (the-apps/PROVIDERS.md, rule 2). Model ids are never written here: they come from each
/// provider's own list of models.
public struct TextProvider: Sendable, Identifiable, Equatable {
    /// How the provider wants a request with tools, and how its answer reads.
    public enum Shape: Sendable, Equatable {
        /// OpenAI-style Chat Completions (`tools[].function`, `message.tool_calls`).
        case chatCompletions
        /// OpenAI's Responses API (`tools[]` flat, `output[]` items of type `function_call`).
        case responses
        /// Anthropic's Messages API (`tools[].input_schema`, `content[]` blocks of type `tool_use`).
        case anthropic
    }

    /// The slug: the Keychain account, and the name in settings and in the agent API.
    public var id: String
    public var name: String
    /// The base that `chat/completions`, `responses`, `messages` and `models` hang under.
    public var endpoint: URL
    public var shape: Shape
    /// Shown in the app. A paid route stays hidden until it has been tried with a real, paid request
    /// (PROVIDERS.md, rule 3); Berget and Grunden are shown on the strength of their documentation.
    public var visible: Bool
    /// One line for where the key is entered: what was read of the provider's terms that a user should know.
    public var note: String

    public static let all: [TextProvider] = [
        TextProvider(id: "openrouter", name: "OpenRouter", endpoint: URL(string: "https://openrouter.ai/api/v1")!, shape: .chatCompletions, visible: true,
                     note: "Many models behind one key; each request goes to the model's own provider."),
        TextProvider(id: "berget", name: "Berget", endpoint: URL(string: "https://api.berget.ai/v1")!, shape: .chatCompletions, visible: true,
                     note: "Runs in Stockholm; says it never stores prompts or answers. Built from Berget's documentation, not yet tried with a paid request."),
        TextProvider(id: "grunden", name: "Grunden", endpoint: URL(string: "https://api.grunden.ai/v1")!, shape: .chatCompletions, visible: true,
                     note: "Processes everything in Sweden by its own account. Built from Grunden's documentation, not yet tried with a paid request."),
        TextProvider(id: "openai", name: "OpenAI", endpoint: URL(string: "https://api.openai.com/v1")!, shape: .responses, visible: false,
                     note: "Says API data isn't used for training unless you opt in."),
        TextProvider(id: "anthropic", name: "Anthropic", endpoint: URL(string: "https://api.anthropic.com/v1")!, shape: .anthropic, visible: false,
                     note: "With an API key from the Claude Console."),
        TextProvider(id: "xai", name: "xAI", endpoint: URL(string: "https://api.x.ai/v1")!, shape: .responses, visible: false,
                     note: "Grok models."),
        TextProvider(id: "google", name: "Google", endpoint: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!, shape: .chatCompletions, visible: false,
                     note: "Gemini through Google's OpenAI-compatible route, which Google calls beta."),
    ]

    public static func named(_ id: String) -> TextProvider? { all.first { $0.id == id } }
    /// The ones offered in the app. `showHidden` is for trying a hidden one on purpose (a debug setting).
    public static func offered(showHidden: Bool = false) -> [TextProvider] { all.filter { $0.visible || showHidden } }
}

/// One model a provider offers for text, as its own list describes it.
public struct ModelChoice: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    /// Whether it can call tools, when the list says. The assistant needs it.
    public var tools: Bool?
    /// Price per million tokens in and out, when the list says, with its currency.
    public var input: Double?
    public var output: Double?
    public var currency: String?
    /// The reasoning levels it takes, least first, when the list says (Grunden).
    public var reasoningLevels: [String] = []

    /// What a request of about 6,000 tokens in and 500 out costs, in words, or nil when the list has no price.
    public var estimate: String? {
        guard let input, let output, let currency else { return nil }
        let cost = (input * 6_000 + output * 500) / 1_000_000
        let amount = cost < 0.01 ? String(format: "%.4f", cost) : String(format: "%.2f", cost)
        return "About \(amount) \(currency) for this request (\(String(format: "%g", input)) in / \(String(format: "%g", output)) out per million tokens)."
    }
}

public enum ModelCatalog {
    /// The provider's text models, read from its list endpoint. The key goes along when there is one;
    /// Berget's and Grunden's lists are public.
    public static func list(_ provider: TextProvider, key: String?, session: URLSession = .shared) async throws -> [ModelChoice] {
        var req = URLRequest(url: provider.endpoint.appending(path: "models"))
        req.timeoutInterval = 15
        CloudPlanner.authorize(&req, provider: provider, key: key)
        let (data, response) = try await KeyedRequest.data(for: req, session: session)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AssistantError.provider(provider.name, status, String(decoding: data.prefix(600), as: UTF8.self)) }
        return parse(provider, data)
    }

    static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    /// Each provider describes its models in its own way; what Jämmer needs is the id, whether it calls
    /// tools, and the price. Models that aren't for text (speech, embeddings, images) are left out.
    public static func parse(_ provider: TextProvider, _ data: Data) -> [ModelChoice] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let list = root["data"] as? [[String: Any]] else { return [] }
        let notText = ["embed", "whisper", "tts", "transcri", "rerank", "image", "dall-e", "audio", "realtime", "moderation", "sora", "veo", "imagen", "speech", "pii"]
        var out: [ModelChoice] = []
        for m in list {
            guard var id = m["id"] as? String, !id.isEmpty else { continue }
            var choice = ModelChoice(id: id, name: (m["display_name"] as? String) ?? (m["name"] as? String) ?? id)
            switch provider.id {
            case "berget":
                guard m["model_type"] as? String == "text" else { continue }
                choice.tools = (m["capabilities"] as? [String: Any])?["function_calling"] as? Bool
                if let p = m["pricing"] as? [String: Any] {
                    choice.input = number(p["input"]); choice.output = number(p["output"]); choice.currency = p["currency"] as? String
                }
            case "grunden":
                guard m["type"] as? String == "chat" else { continue }
                choice.tools = (m["tool_calling"] as? Bool) ?? (m["capabilities"] as? [String])?.contains("tools")
                choice.reasoningLevels = m["reasoning_levels"] as? [String] ?? []
                if let p = m["pricing"] as? [String: Any], let i = p["input_per_1m_tokens"] as? [String: Any], let o = p["output_per_1m_tokens"] as? [String: Any] {
                    choice.input = number(i["amount"]); choice.output = number(o["amount"]); choice.currency = i["currency"] as? String
                }
            case "openrouter":
                // Prices are per token, in dollars; a model takes tools when its supported parameters say so.
                if let p = m["pricing"] as? [String: Any], let i = number(p["prompt"]), let o = number(p["completion"]) {
                    choice.input = i * 1_000_000; choice.output = o * 1_000_000; choice.currency = "USD"
                }
                if let supported = m["supported_parameters"] as? [String] { choice.tools = supported.contains("tools") }
            case "google":
                // The compatible route lists them as "models/gemini-…".
                if id.hasPrefix("models/") { id = String(id.dropFirst("models/".count)); choice.id = id; if choice.name.hasPrefix("models/") { choice.name = id } }
                guard id.hasPrefix("gemini") else { continue }
            default:
                break
            }
            if provider.id != "berget", provider.id != "grunden", notText.contains(where: { id.lowercased().contains($0) }) { continue }
            out.append(choice)
        }
        return out.sorted { $0.id < $1.id }
    }
}

/// A model at one of the providers, with the user's own key. Paid: the app asks before every request.
/// The request and the answer are in the provider's own form; what comes out is the same plan.
public struct CloudPlanner: AssistantPlanner {
    public var provider: TextProvider
    public var model: String
    /// From the Keychain, read when a request is made; never kept on the planner.
    public var key: @Sendable () -> String?
    /// Grunden: the least reasoning the model takes, since a plan needs no deliberation and leaving it out means the most.
    public var reasoningEffort: String?
    public var session: URLSession

    public init(provider: TextProvider, model: String, key: @escaping @Sendable () -> String?, reasoningEffort: String? = nil, session: URLSession = .shared) {
        self.provider = provider
        self.model = model
        self.key = key
        self.reasoningEffort = reasoningEffort
        self.session = session
    }

    public var id: String { "\(provider.id):\(model)" }
    public var paid: Bool { true }

    /// Anthropic's API version, as its versioning page gives it (read 2026-11-16).
    static let anthropicVersion = "2026-10-21"

    static func authorize(_ req: inout URLRequest, provider: TextProvider, key: String?) {
        guard let key, !key.isEmpty else { return }
        if provider.shape == .anthropic {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        } else {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if provider.id == "openrouter" {
            req.setValue("https://jammer.brattoo.com", forHTTPHeaderField: "HTTP-Referer")
            req.setValue("Jammer", forHTTPHeaderField: "X-Title")
        }
    }

    static func schema(_ a: AssistantAction) -> [String: Any] {
        var props: [String: Any] = [:]
        for p in a.params { props[p.name] = p.schema }
        return ["type": "object", "properties": props, "required": a.params.filter(\.required).map(\.name)]
    }

    public func request(goal: String, context: AssistantContext, history: [(user: String, reply: String)], actions: [AssistantAction]) -> (path: String, body: [String: Any]) {
        let system = AssistantPrompt.preamble + "\nCall the tools in the order they should run; each call is one step. Also reply with a short message."
        let user = AssistantPrompt.prompt(goal: goal, context: context, history: history)
        switch provider.shape {
        case .chatCompletions:
            var body = OpenRouterPlanner(endpoint: provider.endpoint, model: model, key: { nil }).requestBody(goal: goal, context: context, history: history, actions: actions)
            if let reasoningEffort { body["reasoning_effort"] = reasoningEffort }
            return ("chat/completions", body)
        case .responses:
            let tools = actions.map { ["type": "function", "name": OpenRouterPlanner.toolName($0), "description": $0.description, "parameters": Self.schema($0)] as [String: Any] }
            return ("responses", ["model": model, "instructions": system, "input": user, "tools": tools, "tool_choice": "auto", "store": false])
        case .anthropic:
            let tools = actions.map { ["name": OpenRouterPlanner.toolName($0), "description": $0.description, "input_schema": Self.schema($0)] as [String: Any] }
            return ("messages", ["model": model, "max_tokens": 2_048, "system": system, "messages": [["role": "user", "content": user]], "tools": tools])
        }
    }

    public func plan(goal: String, context: AssistantContext, history: [(user: String, reply: String)],
                     actions: [AssistantAction]) async throws -> AssistantPlan {
        if let reply = PlanParser.guardrail(goal) { return AssistantPlan(reply: reply, steps: []) }
        guard let key = key(), !key.isEmpty else { throw AssistantError.missingKey(provider.name) }
        let (path, body) = request(goal: goal, context: context, history: history, actions: actions)
        var req = URLRequest(url: provider.endpoint.appending(path: path))
        req.timeoutInterval = 60 // offline or stalled: an error in the panel, never a hang
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.authorize(&req, provider: provider, key: key)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await KeyedRequest.data(for: req, session: session)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // The provider's own words, with the status: nobody has made this request for real before the user does.
        guard (200..<300).contains(status) else { throw AssistantError.provider(provider.name, status, String(decoding: data.prefix(600), as: UTF8.self)) }
        let plan: AssistantPlan
        switch provider.shape {
        case .chatCompletions: plan = try OpenRouterPlanner.decode(data, actions: actions, context: context)
        case .responses: plan = try Self.decodeResponses(data, actions: actions, context: context)
        case .anthropic: plan = try Self.decodeAnthropic(data, actions: actions, context: context)
        }
        return PlanParser.augment(goal: goal, plan: plan)
    }

    static func step(named name: String, arguments: Any?, actions: [AssistantAction], context: AssistantContext?, dropped: inout [String]) -> PlannedStep? {
        guard let action = actions.first(where: { OpenRouterPlanner.toolName($0) == name }) else { dropped.append(name); return nil }
        var obj = arguments as? [String: Any] ?? [:]
        if let text = arguments as? String, let parsed = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] { obj = parsed }
        var params: [String: JSONValue] = [:]
        for (k, v) in obj { if let j = JSONValue(v) { params[k] = j } }
        return OpenRouterPlanner.step(action, params, context)
    }

    /// Responses: `output` is a list of items; a `function_call` has `name` and `arguments` (JSON as text),
    /// a `message` has `content` parts of type `output_text`. Reasoning items are passed over.
    static func decodeResponses(_ data: Data, actions: [AssistantAction], context: AssistantContext? = nil) throws -> AssistantPlan {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let output = root["output"] as? [[String: Any]] else { throw AssistantError.badResponse }
        var dropped: [String] = [], steps: [PlannedStep] = [], reply = ""
        for item in output {
            switch item["type"] as? String {
            case "function_call":
                if let name = item["name"] as? String, let s = step(named: name, arguments: item["arguments"], actions: actions, context: context, dropped: &dropped) { steps.append(s) }
            case "message":
                for part in item["content"] as? [[String: Any]] ?? [] where part["type"] as? String == "output_text" { reply += part["text"] as? String ?? "" }
            default: break
            }
        }
        return PlanParser.validate(AssistantPlan(reply: reply.trimmingCharacters(in: .whitespacesAndNewlines), steps: steps, dropped: dropped), actions: actions)
    }

    /// Messages: `content` is a list of blocks; `tool_use` has `name` and `input` (an object), `text` has `text`.
    static func decodeAnthropic(_ data: Data, actions: [AssistantAction], context: AssistantContext? = nil) throws -> AssistantPlan {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let content = root["content"] as? [[String: Any]] else { throw AssistantError.badResponse }
        var dropped: [String] = [], steps: [PlannedStep] = [], reply = ""
        for block in content {
            switch block["type"] as? String {
            case "tool_use":
                if let name = block["name"] as? String, let s = step(named: name, arguments: block["input"], actions: actions, context: context, dropped: &dropped) { steps.append(s) }
            case "text": reply += block["text"] as? String ?? ""
            default: break
            }
        }
        return PlanParser.validate(AssistantPlan(reply: reply.trimmingCharacters(in: .whitespacesAndNewlines), steps: steps, dropped: dropped), actions: actions)
    }
}
