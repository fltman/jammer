import Foundation
import FoundationModels
import JammerCore

/// For a text in the omnibar that could be a command or a request: Apple's model on this Mac picks one of the
/// best matching commands, or the assistant. Free, and nothing leaves the Mac. The answer can only be one of
/// the offered titles or the assistant (structured output from a list made at run time).
public enum OmnibarRouter {
    /// Whether the model is there to ask (Apple Intelligence on, the model downloaded).
    public static var available: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static let assistant = "ask the assistant"

    /// The index in `candidates` of the command the text means, or nil for the assistant (also when the model
    /// isn't there, fails, or takes longer than `timeout` seconds).
    public static func pick(_ text: String, among candidates: [CommandSearch.Entry], timeout: Double = 3) async -> Int? {
        guard available, !candidates.isEmpty else { return nil }
        let titles = candidates.map(\.title)
        let schema: GenerationSchema
        do {
            schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Choice", anyOf: titles + [assistant]), dependencies: [])
        } catch { return nil }
        let instructions = """
            You route what a person typed in an audio editor's command field. If it names one of the listed \
            commands, answer with that command's title exactly. If it asks for something else, or for \
            several things, or is a question, answer "\(assistant)".
            """
        let prompt = "Typed: \(text)\nCommands: \(titles.joined(separator: "; "))"
        let answer = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let session = LanguageModelSession(instructions: instructions)
                let r = try? await session.respond(to: prompt, schema: schema, options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 40))
                return r.flatMap { try? $0.content.value(String.self) }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return answer.flatMap { titles.firstIndex(of: $0) }
    }
}
