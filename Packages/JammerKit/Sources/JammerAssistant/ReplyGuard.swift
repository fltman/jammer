import Foundation
import JammerAgent
import NaturalLanguage

/// What a model wrote is checked before it is shown. A measurement never comes out of a model's own
/// text: at the time it writes, nothing has been measured, so a figure it gives is one it made up
/// ("The loudness is -16 LUFS" in front of a measured −18.0). Jämmer writes measured figures itself.
public enum ReplyGuard {
    /// Actions whose answer is a measurement. A plan made only of these is answered by Jämmer from the
    /// result; the model chose what to measure and its own sentence isn't shown.
    public static let measuring: Set<String> = ["measure_loudness", "analyze_restoration", "detect_tempo", "analyze_rhythm"]

    static let units = ["LUFS", "LKFS", "LU", "dBTP", "dBFS", "dBu", "dBV", "dB", "kHz", "Hz", "BPM", "ms", "%", "procent", "percent",
                        "seconds", "second", "secs", "sec", "sekunder", "sekund", "s", "minutes", "minute", "minuter", "minut", "min",
                        "samples", "frames", "bits", "bit", "kbps", "semitones", "halvtoner", "cents"]
    static let figure: NSRegularExpression = {
        let u = units.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return try! NSRegularExpression(pattern: "(?<![\\p{L}\\d.,])[-−–+]?\\s?(\\d+(?:[.,]\\d+)?)\\s*(?:\(u))(?![\\p{L}\\d])", options: [.caseInsensitive])
    }()
    static let number = try! NSRegularExpression(pattern: "\\d+(?:[.,]\\d+)?")

    static func value(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: ".")) }

    /// Every number in a text, without sign: what a reply may repeat.
    static func numbers(in text: String) -> [Double] {
        let ns = text as NSString
        return number.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { value(ns.substring(with: $0.range)) }
    }
    static func numbers(in v: JSONValue) -> [Double] {
        switch v {
        case .number(let d): [abs(d)]
        case .string(let s): numbers(in: s)
        case .array(let a): a.flatMap { numbers(in: $0) }
        default: []
        }
    }

    /// The figures with a unit in a text (the number, unsigned).
    static func figures(in text: String) -> [Double] {
        let ns = text as NSString
        return figure.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { value(ns.substring(with: $0.range(at: 1))) }
    }

    static func sentences(_ text: String) -> [String] {
        let t = NLTokenizer(unit: .sentence)
        t.string = text
        return t.tokens(for: text.startIndex..<text.endIndex).map { String(text[$0]) }
    }

    /// The text without every sentence that has a figure with a unit that isn't among `known`.
    public static func withoutInventedFigures(_ text: String, known: [Double]) -> String {
        func isKnown(_ d: Double) -> Bool { known.contains { abs($0 - d) < 0.0005 } }
        return sentences(text).filter { figures(in: $0).allSatisfy(isKnown) }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Swedish or English, when the text is long enough to tell.
    public static func language(of text: String) -> NLLanguage? {
        guard text.filter(\.isLetter).count >= 12 else { return nil }
        let r = NLLanguageRecognizer()
        r.languageConstraints = [.swedish, .english]
        r.processString(text)
        guard let l = r.dominantLanguage, (r.languageHypotheses(withMaximum: 2)[l] ?? 0) >= 0.75 else { return nil }
        return l
    }

    static func cannot(_ language: NLLanguage?) -> String {
        language == .swedish ? "Det kan jag inte göra så som det är sagt. Jag arbetar med ljudet i det här dokumentet: säg vad som ska hända med det."
                             : "I can't do that as asked. I work with the sound in this document: say what should happen to it."
    }

    /// What was wrong with a model's reply as it came, for the evaluation sets: a figure of its own,
    /// and a language other than the request's.
    public static func faults(_ plan: AssistantPlan, goal: String, context: AssistantContext) -> (inventedFigure: Bool, wrongLanguage: Bool) {
        let known = numbers(in: goal) + numbers(in: context.rendered) + plan.steps.flatMap { $0.params.values.flatMap { numbers(in: $0) } }
        let invented = !figures(in: plan.reply).allSatisfy { d in known.contains { abs($0 - d) < 0.0005 } }
        let asked = language(of: goal), got = language(of: plan.reply)
        return (invented, asked != nil && got != nil && asked != got)
    }

    /// The plan with a reply that is safe to show:
    /// - no sentence with a figure and a unit that isn't word for word in the request, the document's
    ///   description or the plan's own values;
    /// - no sentence of the model's at all when the plan only measures (Jämmer writes that answer);
    /// - in the language of the request, or Jämmer's own words in that language.
    public static func checked(_ plan: AssistantPlan, goal: String, context: AssistantContext) -> AssistantPlan {
        var out = plan
        // A plan that only moves the playhead or the selection, for a request that asks for neither, is no plan.
        let text = " " + goal.lowercased() + " "
        if !plan.steps.isEmpty, plan.steps.allSatisfy({ s in AssistantCatalog.viewOnly[s.op].map { words in !words.contains { text.contains($0) } } ?? false }) {
            out.steps = []
        }
        if !out.steps.isEmpty, out.steps.allSatisfy({ measuring.contains($0.op) }) {
            out.reply = ""
            return out
        }
        let known = numbers(in: goal) + numbers(in: context.rendered) + plan.steps.flatMap { $0.params.values.flatMap { numbers(in: $0) } }
        out.reply = withoutInventedFigures(plan.reply, known: known)
        let asked = language(of: goal)
        if let asked, let got = language(of: out.reply), got != asked { out.reply = "" }
        if out.reply.isEmpty, out.steps.isEmpty { out.reply = cannot(asked) }
        return out
    }
}

public extension AssistantPlanner {
    /// `plan`, with the reply checked (`ReplyGuard`). This is what reaches the screen, from every planner.
    func answer(goal: String, context: AssistantContext, history: [(user: String, reply: String)],
                actions: [AssistantAction]) async throws -> AssistantPlan {
        ReplyGuard.checked(try await plan(goal: goal, context: context, history: history, actions: actions), goal: goal, context: context)
    }
}
