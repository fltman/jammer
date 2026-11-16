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

    /// What sort of figure a unit makes. The sort decides what can back the figure up (see `Backing`).
    enum Sort: Equatable { case level, time, money, size, percent, other }
    static func sort(of unit: String) -> Sort {
        switch unit.lowercased() {
        case "lufs", "lkfs", "lu", "dbtp", "dbfs", "db": .level
        case "seconds", "second", "secs", "sec", "sekunder", "sekund", "s", "minutes", "minute", "minuter", "minut", "min", "ms": .time
        case "kr", "sek", "usd", "eur", "dollar", "dollars", "kronor", "euro", "euros", "$", "€": .money
        case "kb", "mb", "gb", "tb", "bytes", "byte": .size
        case "%", "procent", "percent": .percent
        default: .other
        }
    }
    /// Seconds in one of a time unit.
    static func seconds(per unit: String) -> Double {
        switch unit.lowercased() {
        case "ms": 0.001
        case "minutes", "minute", "minuter", "minut", "min": 60
        default: 1
        }
    }
    /// Money and sizes on disk, which the older list didn't have: they are never the assistant's to state.
    static let moreUnits = ["kr", "SEK", "USD", "EUR", "dollars", "dollar", "kronor", "euros", "euro", "KB", "MB", "GB", "TB", "bytes", "byte"]
    static let more: NSRegularExpression = {
        let u = moreUnits.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return try! NSRegularExpression(pattern: "(?<![\\p{L}\\d.,])(\\d+(?:[.,]\\d+)?)\\s*(\(u)|[$€])(?![\\p{L}\\d])", options: [.caseInsensitive])
    }()
    static let moneyFirst = try! NSRegularExpression(pattern: "([$€])\\s?(\\d+(?:[.,]\\d+)?)")
    static let withUnit: NSRegularExpression = {
        let u = units.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return try! NSRegularExpression(pattern: "(?<![\\p{L}\\d.,])[-−–+]?\\s?(\\d+(?:[.,]\\d+)?)\\s*(\(u))(?![\\p{L}\\d])", options: [.caseInsensitive])
    }()

    struct Figure: Equatable { var value: Double; var unit: String; var sort: Sort }
    /// The figures with a unit in a text, each with its unit (the number unsigned).
    static func unitFigures(in text: String) -> [Figure] {
        let ns = text as NSString, all = NSRange(location: 0, length: ns.length)
        var out: [Figure] = []
        for (re, n, u) in [(withUnit, 1, 2), (more, 1, 2), (moneyFirst, 2, 1)] {
            for m in re.matches(in: text, range: all) {
                guard let v = value(ns.substring(with: m.range(at: n))) else { continue }
                let unit = ns.substring(with: m.range(at: u))
                out.append(Figure(value: v, unit: unit, sort: sort(of: unit)))
            }
        }
        return out
    }

    /// Numbers a request gives in words ("two seconds", "en halv sekund", "minus eighteen"): given, like digits.
    static let numberWords: [String: Double] = {
        var w: [String: Double] = ["half": 0.5, "halv": 0.5, "halvt": 0.5, "halvan": 0.5, "quarter": 0.25, "kvarts": 0.25]
        let en = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
                  "sixteen", "seventeen", "eighteen", "nineteen", "twenty"]
        let sv = ["noll", "en", "två", "tre", "fyra", "fem", "sex", "sju", "åtta", "nio", "tio", "elva", "tolv", "tretton", "fjorton", "femton",
                  "sexton", "sjutton", "arton", "nitton", "tjugo"]
        for (i, x) in en.enumerated() { w[x] = Double(i) }
        for (i, x) in sv.enumerated() { w[x] = Double(i) }
        for (x, v) in [("thirty", 30.0), ("forty", 40), ("fifty", 50), ("sixty", 60), ("seventy", 70), ("eighty", 80), ("ninety", 90), ("hundred", 100),
                       ("trettio", 30), ("fyrtio", 40), ("femtio", 50), ("sextio", 60), ("sjuttio", 70), ("åttio", 80), ("nittio", 90), ("hundra", 100)] { w[x] = v }
        return w
    }()
    static func wordNumbers(in text: String) -> [Double] {
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        var out = words.compactMap { numberWords[$0] }
        // "one and a half", "en och en halv", "två och en halv": the whole number and the half together.
        for (i, w) in words.enumerated() {
            guard let n = numberWords[w], n >= 1, n == n.rounded() else { continue }
            let next = words[(i + 1)...].prefix(3)
            if ["and", "och"].contains(next.first ?? ""), next.contains(where: { numberWords[$0] == 0.5 }) { out.append(n + 0.5) }
        }
        return out
    }

    /// What can back a figure up (SIBLINGS.md, "Siffror i assistentens svar"), made once for a reply:
    /// 1. the request, in digits or in words; 2. what the model was told about the document; the values
    ///    of the plan's own steps (what will run, shown to the user beside the sentence);
    /// 3. an action's description, only for a sentence that names that action or what it is about, and
    ///    never for a sentence that says something about the user's own sound;
    /// 4. a closed set worked out from 1 and 2 before the reply is read (`derived`).
    /// Money and sizes on disk are backed by 1 and 2 only, and so is a time in a sentence about how long
    /// something will take, and every figure in a sentence about a service.
    struct Backing {
        var given: [Double]            // 1 and 2
        var planned: [Double]          // the plan's own values
        var derivedTimes: [Double]     // seconds
        var derivedLevels: [Double]    // dB / LU
        var steps: Int
        var actions: [(words: [String], numbers: [Double])]

        static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.0005 }
        /// Membership with the rounding a person sees: the derived value as it is, or to 0, 1 or 2 decimals.
        static func rounds(_ derived: Double, to shown: Double) -> Bool {
            near(derived, shown) || [1.0, 10, 100].contains { near((derived * $0).rounded() / $0, shown) }
        }

        func backs(_ f: Figure, in sentence: String) -> Bool {
            let s = " " + sentence.lowercased() + " "
            if given.contains(where: { Self.near($0, f.value) }) { return true }
            let never = f.sort == .money || f.sort == .size
                || ReplyGuard.serviceWords.contains { s.contains($0) }
                || (f.sort == .time && ReplyGuard.takingWords.contains { s.contains($0) })
            if never { return false }
            // 0, 1 and a count up to the number of steps.
            if f.value == 0 || f.value == 1 || (f.value == f.value.rounded() && f.value <= Double(steps)) { return true }
            if planned.contains(where: { Self.near($0, f.value) }) { return true }
            if f.sort == .time, derivedTimes.contains(where: { Self.rounds($0 / ReplyGuard.seconds(per: f.unit), to: f.value) }) { return true }
            if f.sort == .level, derivedLevels.contains(where: { Self.rounds($0, to: f.value) }) { return true }
            if !ReplyGuard.aboutTheirSound.contains(where: { s.contains($0) }) {
                let words = s.split { !$0.isLetter && $0 != "_" }.map(String.init)
                for a in actions where a.numbers.contains(where: { Self.near($0, f.value) }) {
                    if a.words.contains(where: { w in w.contains(" ") ? s.contains(w) : words.contains { $0.hasPrefix(w) } }) { return true }
                }
            }
            return false
        }
    }
    static let serviceWords = ["openrouter", "hugging face", "huggingface", " api ", "server", "tjänst", "service", "provider", "leverantör", "subscription",
                               "abonnemang", "credits", "quota", "kvot", "rate limit"]
    static let takingWords = [" takes ", " take about ", " will take ", " tar ", " ta ungefär ", " dröjer ", " wait ", " vänta ", " ready in ", " klar om ", " klart om ", " done in "]
    static let aboutTheirSound = [" your ", " yours ", " is at ", " are at ", " measures ", " measured ", " currently ", " right now ", " din ", " ditt ", " dina ",
                                  " ligger på ", " är på ", " mäter ", " uppmätt ", " just nu ", " the recording is ", " the file is ", " inspelningen är ", " filen är ", " ljudet är "]
    /// Parameter names too common to say which action a sentence is about.
    static let commonNames: Set<String> = ["start", "end", "level", "track", "tracks", "name", "range", "length", "target", "amount", "strip"]

    /// The closed set (rule 4), worked out from the request and the document's description. Listed in the
    /// manual ("The assistant"); a new member goes in both places.
    /// Times, in seconds: the selection's length; what is left after the playhead and after the selection;
    /// half the document and half the selection; and for two times in the request, their sum and their
    /// difference. (Any of them may be said in ms, s or minutes.)
    /// Levels: the difference between any two levels in the request and the document's description
    /// (a target minus a level given: "from −23 to −16 LUFS" is 7 dB).
    static func derived(goal: String, context: AssistantContext) -> (times: [Double], levels: [Double]) {
        var times: [Double] = []
        let length = context.duration
        times += [length / 2, length - context.playhead]
        if let (a, b) = context.selection { times += [b - a, (b - a) / 2, length - b] }
        // Every given time in seconds, so that it may be said in another unit too.
        let asked = unitFigures(in: goal).filter { $0.sort == .time }.map { $0.value * seconds(per: $0.unit) }
        times += asked + [length] + (context.selection.map { [$0.0, $0.1] } ?? []) + [context.playhead]
        for (i, x) in asked.enumerated() { for y in asked[(i + 1)...] { times += [x + y, abs(x - y)] } }
        var differences: [Double] = []
        // Signed, as written: −23 and −16 are 7 apart, −3 and 6 are 9 apart.
        let signed = signedLevels(in: goal) + signedLevels(in: context.rendered)
        for (i, x) in signed.enumerated() { for y in signed[(i + 1)...] { differences.append(abs(x - y)) } }
        return (times.filter { $0 > 0 }, differences.filter { $0 > 0 })
    }
    static func signedLevels(in text: String) -> [Double] {
        let ns = text as NSString
        return withUnit.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard sort(of: ns.substring(with: m.range(at: 2))) == .level, let v = value(ns.substring(with: m.range(at: 1))) else { return nil }
            let whole = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
            return whole.hasPrefix("-") || whole.hasPrefix("−") || whole.hasPrefix("–") ? -v : v
        }
    }

    static func backing(_ plan: AssistantPlan, goal: String, context: AssistantContext, actions: [AssistantAction]) -> Backing {
        let d = derived(goal: goal, context: context)
        let named = actions.map { a -> (words: [String], numbers: [Double]) in
            var words = [a.name.lowercased(), a.name.lowercased().replacingOccurrences(of: "_", with: " ")]
            words += a.name.lowercased().split(separator: "_").map(String.init).filter { $0.count >= 5 && !commonNames.contains($0) }
            words += a.params.map { $0.name.lowercased() }.filter { $0.count >= 5 && !commonNames.contains($0) }
            words += (AssistantCatalog.onDeviceWhenNamed[a.name] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 4 }
            var numbers = numbers(in: a.description)
            for p in a.params { numbers += ReplyGuard.numbers(in: p.description); if let r = p.range { numbers += [abs(r.lowerBound), abs(r.upperBound)] } }
            return (words, numbers)
        }
        return Backing(given: numbers(in: goal) + wordNumbers(in: goal) + numbers(in: context.rendered),
                       planned: plan.steps.flatMap { $0.params.values.flatMap { numbers(in: $0) } },
                       derivedTimes: d.times, derivedLevels: d.levels, steps: plan.steps.count, actions: named)
    }

    /// The reply's sentences that have a figure nothing backs up.
    static func unbacked(_ text: String, _ backing: Backing) -> [String] {
        sentences(text).filter { s in !unitFigures(in: s).allSatisfy { backing.backs($0, in: s) } }
    }
    public static func heldBackNote(_ language: NLLanguage?, count: Int) -> String {
        language == .swedish ? (count == 1 ? "En mening med en siffra jag inte kan belägga hölls tillbaka." : "\(count) meningar med siffror jag inte kan belägga hölls tillbaka.")
                             : (count == 1 ? "A sentence with a figure I can't back up was held back." : "\(count) sentences with figures I can't back up were held back.")
    }

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
    public static func faults(_ plan: AssistantPlan, goal: String, context: AssistantContext,
                              actions: [AssistantAction] = AssistantCatalog.actions) -> (inventedFigure: Bool, wrongLanguage: Bool) {
        let invented = !unbacked(plan.reply, backing(plan, goal: goal, context: context, actions: actions)).isEmpty
        let asked = language(of: goal), got = language(of: plan.reply)
        return (invented, asked != nil && got != nil && asked != got)
    }

    /// The plan with a reply that is safe to show:
    /// - no sentence with a figure and a unit that nothing backs up (`Backing`); the sentences taken out
    ///   are kept in `heldBack`, and the user is told that something was held back;
    /// - no sentence of the model's at all when the plan only measures (Jämmer writes that answer), or
    ///   when any step it planned was left out (the sentence may say that something was done that wasn't);
    /// - in the language of the request, or Jämmer's own words in that language.
    public static func checked(_ plan: AssistantPlan, goal: String, context: AssistantContext,
                               actions: [AssistantAction] = AssistantCatalog.actions) -> AssistantPlan {
        var out = plan
        // A plan that only moves the playhead or the selection, for a request that asks for neither, is no plan.
        let text = " " + goal.lowercased() + " "
        if !plan.steps.isEmpty, plan.steps.allSatisfy({ s in AssistantCatalog.viewOnly[s.op].map { words in !words.contains { text.contains($0) } } ?? false }) {
            out.steps = []
        }
        // A step of that kind that was left out for a missing value is not worth a line to the user either.
        out.dropped.removeAll { d in AssistantCatalog.viewOnly.keys.contains { d == $0 || d.hasPrefix($0 + " ") } }
        if !out.steps.isEmpty, out.steps.allSatisfy({ measuring.contains($0.op) }) {
            out.reply = ""
            return out
        }
        // Every step the model planned was left out: its sentence speaks of something that won't happen
        // ("VCA Voices removed." above "Left out: remove_vca"). Jämmer's own words stand instead.
        if out.steps.isEmpty, !out.dropped.isEmpty {
            out.reply = cannot(language(of: goal))
            return out
        }
        // Some steps stay and some were left out: whether the model's sentence claims more than what will
        // run can't be told, so it isn't shown. The plan itself (what it does, in Jämmer's words) and the
        // line about what was left out say it.
        if !out.dropped.isEmpty {
            out.reply = ""
            return out
        }
        let held = unbacked(plan.reply, backing(plan, goal: goal, context: context, actions: actions))
        out.reply = sentences(plan.reply).filter { !held.contains($0) }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        out.heldBack = held.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
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
        ReplyGuard.checked(try await plan(goal: goal, context: context, history: history, actions: actions), goal: goal, context: context, actions: actions)
    }
}
