import Foundation
import JammerAgent
import JammerCore

/// The assistant's vocabulary, generated from the same registry as the menus, ⌘K and the
/// agent API (`Operations`), so they can't drift apart. Pattern from Glimmer's AgentPlanner.
public struct AssistantAction: Sendable {
    public enum Kind: Sendable, Equatable {
        /// A step (`Operations.all`): runs with the others as one undo step.
        case step
        /// An endpoint of its own (`Operations.endpoints`): a job or a measurement.
        case endpoint
        /// Assistant-only: expanded into steps against the document before running.
        case macro
        /// A sibling app's operation (SIBLINGS.md), named `<slug>_<name>`.
        case sibling(slug: String, method: String?, path: String?)
    }

    public var name: String
    public var description: String
    public var params: [OperationSpec.Param]
    public var kind: Kind
    public var destructive: Bool

    /// The first sentence of the description, for the compact catalogue.
    var short: String {
        let d = description
        if let r = d.range(of: ". ") { return String(d[..<r.lowerBound]) + "." }
        return d
    }
}

public enum AssistantCatalog {
    /// Steps and endpoints that remove or replace audio: the plan is shown before it runs.
    static let destructiveNames: Set<String> = ["delete", "cut", "crop", "silence", "delete_words", "paste", "insert_silence",
                                                "echo", "restore", "remove_fillers", "remove_silences"]

    public static let macros: [AssistantAction] = [
        AssistantAction(name: "remove_fillers", description: "Removes every filler word (eh, ehm, öh, um, uh…) from the audio. Transcribes first if needed.",
                        params: [.init("words", .list, "More words to count as fillers.")], kind: .macro, destructive: true),
        AssistantAction(name: "remove_silences", description: "Removes long pauses (silences): every pause longer than min_length is cut down to keep seconds.",
                        params: [.init("min_length", .seconds, "Pauses at least this long, in seconds. Default 1.", range: 0.1...60),
                                 .init("keep", .seconds, "How much of each pause to keep, in seconds. Default 0.3.", range: 0...10),
                                 .init("threshold", .number, "Quiet means below this many dBFS. Default -45.", range: -90...(-10))],
                        kind: .macro, destructive: true),
    ]

    /// Values the assistant fills in when the model leaves out a required one.
    static let defaults: [String: [String: JSONValue]] = [
        "normalize": ["target": .string("loudness")],
        "echo": ["delay": .number(0.3)],
    ]

    /// Plugin steps need track and insert ids and weren't in the measured action set.
    public static let stepsNotForAssistant: Set<String> = ["add_insert", "set_insert", "remove_insert", "spectral_edit", "set_track", "set_group"]

    /// Own actions: every step (but the above), the useful endpoints, and the macros.
    public static var actions: [AssistantAction] {
        let endpointNames: Set<String> = ["transcribe", "restore", "analyze_restoration", "measure_loudness"]
        return Operations.all.filter { !stepsNotForAssistant.contains($0.name) }.map { AssistantAction(name: $0.name, description: $0.description, params: $0.params, kind: .step,
                                                    destructive: destructiveNames.contains($0.name)) }
            + Operations.endpoints.filter { endpointNames.contains($0.name) }.map {
                AssistantAction(name: $0.name, description: $0.description, params: $0.params, kind: .endpoint,
                                destructive: destructiveNames.contains($0.name))
            }
            + macros
    }

    /// Actions the small on-device model is told about only when the request has one of these words in it
    /// (lowercased, Swedish and English). Every action in the list costs that model attention and context:
    /// with 28 actions it planned 14 of 14 standard requests right; with all 37 in front of it, 10 of 14, and
    /// some requests no longer fitted its context (measured 2026-11-16). Larger models get the whole list.
    /// A new action goes either here, with its words, or into `onDeviceAlways` after the evaluation was run.
    public static let onDeviceWhenNamed: [String: [String]] = [
        "align_tracks": ["align", "sync", "synk", "linjera", "passa ihop"],
        "correct_drift": ["drift", "glider", "driver isär", "out of sync", "ur synk"],
        "debleed": ["bleed", "spill", "läck", "överhör"],
        "detect_tempo": ["tempo", "bpm", "takt", "beat"],
        "duck": ["duck", "under speech", "under the speech", "under the voice", "under talet", "under rösten", "musiken under", "music under", "sänk musiken", "lower the music"],
        "level_speakers": ["speakers", "talarna", "lika högt", "equally loud", "same level", "samma nivå", "even out", "jämna"],
        "loudness_preset": ["podcast", "podd", "spotify", "youtube", "apple", "broadcast", "ebu", "r128", "preset", "streaming", "sändning"],
        "rename_speaker": ["rename", "döp", "byt namn", "kalla", "call speaker", "name speaker"],
        "spectral_attenuate": ["frequenc", "frekvens", " hz", "khz", "band", "spectral", "spektral"],
    ]

    /// What the on-device model is given for this request: everything but the actions in
    /// `onDeviceWhenNamed` that the request doesn't name. Sibling apps' actions are already chosen by name.
    public static func forOnDevice(_ actions: [AssistantAction], goal: String) -> [AssistantAction] {
        let text = " " + goal.lowercased() + " "
        return actions.filter { a in
            guard let words = onDeviceWhenNamed[a.name] else { return true }
            return words.contains { text.contains($0) }
        }
    }

    /// One line per action: `- gain(db*, start, end): Changes the level…` (* = required).
    public static func catalogue(_ actions: [AssistantAction]) -> String {
        actions.map { a in
            let params = a.params.map { p -> String in
                var s = p.name + (p.required ? "*" : "")
                if let o = p.options { s += "=" + o.joined(separator: "|") }
                return s
            }.joined(separator: ", ")
            return "- \(a.name)(\(params)): \(a.short)"
        }.joined(separator: "\n")
    }
}

/// What the planner knows about the document.
public struct AssistantContext: Sendable {
    public var duration: Double
    public var selection: (Double, Double)?
    public var playhead: Double
    public var tracks: [(id: String, name: String)]
    /// "Speaker 2" / "talare 2" / track 2 → its id.
    public func trackID(_ ref: String) -> String? {
        if let n = Int(ref.filter(\.isNumber)), (1...tracks.count).contains(n), ref.count <= 12 { return tracks[n - 1].id }
        if let t = tracks.first(where: { $0.name.caseInsensitiveCompare(ref) == .orderedSame || $0.id == ref }) { return t.id }
        return nil
    }
    public var transcriptLanguage: String?
    public var transcriptExcerpt: String?
    public var fillerCount: Int

    public init(project: Project, selection: Range<Frame>?, playhead: Frame) {
        duration = project.duration
        self.selection = selection.map { (project.seconds($0.lowerBound), project.seconds($0.upperBound)) }
        self.playhead = project.seconds(playhead)
        tracks = project.tracks.map { ($0.id.uuidString, $0.name) }
        transcriptLanguage = project.transcripts.first?.language
        let text = project.transcriptText()
        transcriptExcerpt = text.isEmpty ? nil : String(text.prefix(600))
        fillerCount = project.fillerWordIDs().count
    }

    public var rendered: String {
        func t(_ s: Double) -> String { String(format: "%.2f", s) }
        var lines = ["- length: \(t(duration)) s", "- playhead: \(t(playhead)) s"]
        lines.append("- selection: " + (selection.map { "\(t($0.0))–\(t($0.1)) s" } ?? "none"))
        lines.append("- tracks (speakers), by number: " + tracks.enumerated().map { "\($0.offset + 1) = \($0.element.name)" }.joined(separator: ", "))
        if let lang = transcriptLanguage {
            lines.append("- transcript (\(lang)), \(fillerCount) filler words: \(transcriptExcerpt ?? "")")
        }
        return lines.joined(separator: "\n")
    }
}

public struct PlannedStep: Sendable, Equatable {
    public var op: String
    public var params: [String: JSONValue]
    public var why: String

    public init(op: String, params: [String: JSONValue] = [:], why: String = "") {
        self.op = op
        self.params = params
        self.why = why
    }
}

public struct AssistantPlan: Sendable, Equatable {
    public var reply: String
    public var steps: [PlannedStep]
    /// Ops the model named that don't exist, or steps whose params were invalid.
    public var dropped: [String] = []
    /// Set by a paid planner: what the call cost, in USD, when known.
    public var cost: Double?

    public init(reply: String, steps: [PlannedStep], dropped: [String] = [], cost: Double? = nil) {
        self.reply = reply
        self.steps = steps
        self.dropped = dropped
        self.cost = cost
    }

    public func isDestructive(_ actions: [AssistantAction]) -> Bool {
        steps.contains { s in actions.first { $0.name == s.op }?.destructive ?? true }
    }
}

public protocol AssistantPlanner: Sendable {
    var id: String { get }
    /// True when calls cost money (the app asks first).
    var paid: Bool { get }
    func plan(goal: String, context: AssistantContext, history: [(user: String, reply: String)],
              actions: [AssistantAction]) async throws -> AssistantPlan
}

public enum AssistantError: Error, LocalizedError, Equatable {
    case unavailable(String)
    /// A model server on this Mac (Ollama, MLX) that can't do it, in words that stand on their own.
    case local(String)
    /// A provider answered with an error: its name, the status, and its own words.
    case provider(String, Int, String)
    /// No key for this provider in the Keychain.
    case missingKey(String)
    case noKey
    case http(Int, String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .unavailable(let why): "The on-device model isn't available: \(why)"
        case .local(let why): why
        case .provider(let name, let status, let said): "\(name) answered \(status): \(said)"
        case .missingKey(let name): "Add your \(name) key in the assistant's settings to use it."
        case .noKey: "Add your OpenRouter key in Settings to use a cloud model."
        case .http(let c, let m): "The model service answered \(c): \(m)"
        case .badResponse: "The model's answer couldn't be read."
        }
    }
}

public enum AssistantPrompt {
    /// Computed: reverb reduction can be left out of a build.
    public static var preamble: String { """
    You are the assistant inside Jämmer, a macOS audio editor for speech and podcasts. Turn the user's request into a short plan of the ACTIONS below, run in order. Times are seconds.
    Rules:
    - Use only the listed actions and params. Use as few steps as the request needs; add nothing it didn't ask for.
    - Without start and end, an action works on the selection, or on everything when it says so.
    - Repairs use restore: hum → kind dehum; clicks or pops → declick; clipping or distortion → declip; background noise or hiss → denoise\(Restoration.dereverber != nil ? "; room echo or reverb → dereverb" : ""). declick and declip are different.
    - "Cut", "remove" or "ta bort" a time range means delete with that start and end.
    - A speaker or track is given by its number in tracks (e.g. tracks=2).
    - Loudness in LUFS: normalize with target=loudness. Measuring it: measure_loudness.
    - Ask one short question (no steps) only if the request can't be understood.
    - Reply briefly in the language of the request (Swedish or English).
    Examples:
    - "normalize the peaks to -1 dB" → normalize(target=peak, level=-1)
    - "ta bort klickandet på spår 1" → restore(kind=declick, tracks=1)
    - "put a marker called Chapter 2 at 90 seconds" → add_marker(name=Chapter 2, at=90)
    """ }

    public static func instructions(_ actions: [AssistantAction]) -> String {
        preamble + "\nACTIONS (* = required):\n" + AssistantCatalog.catalogue(actions)
    }

    public static func prompt(goal: String, context: AssistantContext, history: [(user: String, reply: String)]) -> String {
        var s = "DOCUMENT:\n\(context.rendered)\n"
        if !history.isEmpty {
            s += "EARLIER:\n" + history.suffix(4).map { "- user: \($0.user)\n  you: \($0.reply)" }.joined(separator: "\n") + "\n"
        }
        return s + "REQUEST: \(goal)"
    }
}

public enum PlanParser {
    /// Types the model's string values by each param's declared kind and drops what
    /// doesn't validate, rather than failing the whole plan.
    static let languageNames: [String: String] = [
        "swedish": "sv-SE", "svenska": "sv-SE", "sv": "sv-SE", "english": "en-US", "engelska": "en-US", "en": "en-US",
        "german": "de-DE", "tyska": "de-DE", "french": "fr-FR", "franska": "fr-FR", "spanish": "es-ES", "spanska": "es-ES",
        "norwegian": "nb-NO", "norska": "nb-NO", "danish": "da-DK", "danska": "da-DK",
    ]

    static let optionAliases: [String: String] = [
        "lufs": "loudness", "integrated": "loudness", "loudness_lufs": "loudness", "ljudstyrka": "loudness",
        "true_peak_dbtp": "true_peak", "truepeak": "true_peak", "dbtp": "true_peak", "peak_dbfs": "peak", "topp": "peak",
        "hum": "dehum", "brum": "dehum", "clicks": "declick", "click": "declick", "klick": "declick",
        "clipping": "declip", "noise": "denoise", "brus": "denoise", "reverb": "dereverb", "echo": "dereverb", "eko": "dereverb", "equalpower": "equal_power",
    ]

    /// Removes steps that only navigate before an action that doesn't need them.
    public static func tidy(_ steps: [PlannedStep], actions: [AssistantAction]) -> [PlannedStep] {
        let wholeByDefault: Set<String> = ["remove_fillers", "remove_silences", "restore", "gain", "normalize", "measure_loudness",
                                           "analyze_restoration", "transcribe", "echo"]
        var out: [PlannedStep] = []
        for (i, s) in steps.enumerated() {
            let next = i + 1 < steps.count ? steps[i + 1] : nil
            if s.op == "select_all", let n = next, wholeByDefault.contains(n.op) { continue }
            if s.op == "set_playhead", let n = next, n.params["at"] != nil || n.params["start"] != nil { continue }
            if s.op == "analyze_restoration", next?.op == "restore" { continue }
            // A selection that the next step repeats as an explicit range adds nothing.
            if s.op == "select", let n = next, n.params["start"] != nil, n.params["start"] == s.params["start"], n.params["end"] == s.params["end"] { continue }
            // Deleting a filler word by text: all filler words are meant.
            if s.op == "delete_words", let t = s.params["text"]?.string, Project.fillerWords.contains(t.lowercased()) {
                out.append(PlannedStep(op: "remove_fillers", why: s.why))
                continue
            }
            out.append(s)
        }
        return out
    }

    /// The same for arguments that came as JSON (a model that calls tools): each is read as the text a
    /// person would have written, so "2" or 2 for a track, "1:30" for a time and "podcast" for a preset
    /// are understood the same way whichever model said them.
    public static func typed(op: String, json: [String: JSONValue], why: String, actions: [AssistantAction],
                             context: AssistantContext? = nil) -> PlannedStep? {
        func text(_ v: JSONValue) -> String {
            switch v {
            case .number(let d): d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
            case .string(let s): s
            case .bool(let b): b ? "true" : "false"
            case .array(let a): a.map(text).joined(separator: ",")
            case .null: ""
            }
        }
        return typed(op: op, args: json.sorted { $0.key < $1.key }.map { ($0.key, text($0.value)) }, why: why, actions: actions, context: context)
    }

    public static func typed(op: String, args: [(String, String)], why: String, actions: [AssistantAction],
                             context: AssistantContext? = nil) -> PlannedStep? {
        guard let action = actions.first(where: { $0.name == op }) else { return nil }
        var params: [String: JSONValue] = [:]
        for (name, raw) in args {
            let value = raw.trimmingCharacters(in: .whitespaces)
            guard let p = action.params.first(where: { $0.name == name }), !value.isEmpty, value.lowercased() != "null" else { continue }
            switch p.kind {
            case .seconds where value.contains(":"):
                // m:ss or h:mm:ss
                let parts = value.split(separator: ":").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard !parts.isEmpty else { continue }
                params[name] = .number(parts.reduce(0) { $0 * 60 + $1 })
            case .seconds, .number:
                let cleaned = value.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "−", with: "-")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "-.0123456789").inverted)
                guard var d = Double(cleaned) else { continue }
                // Out of range: the nearest allowed value (the plan shows it before it runs).
                if let r = p.range { d = min(max(d, r.lowerBound), r.upperBound) }
                params[name] = .number(d)
            case .boolean:
                params[name] = .bool(["true", "yes", "ja", "1"].contains(value.lowercased()))
            case .numbers:
                let n = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if n.isEmpty { continue }
                params[name] = .array(n.map { .number($0) })
            case .list:
                var items = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if name == "tracks", let context { items = items.compactMap { context.trackID($0) } }
                if items.isEmpty { continue }
                params[name] = .array(items.map { .string($0) })
            case .string:
                if name == "language", value.lowercased() == "auto" { continue }
                var v = name == "language" ? (languageNames[value.lowercased()] ?? value) : value
                if let options = p.options {
                    let key = v.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
                    guard let match = options.first(where: { $0 == key }) ?? optionAliases[key].flatMap({ a in options.first { $0 == a } }) else { continue }
                    v = match
                }
                params[name] = .string(v)
            }
        }
        for (k, v) in AssistantCatalog.defaults[op] ?? [:] where params[k] == nil { params[k] = v }
        return PlannedStep(op: op, params: params, why: why)
    }

    /// Decided before any model is asked: things Jämmer must not do, and requests too vague
    /// to act on. Returns the reply, or nil to let the planner try.
    public static func guardrail(_ goal: String) -> String? {
        let t = Project.tokens(goal)
        let text = " " + t.joined(separator: " ") + " "
        // The recogniser when the request is long enough for it, a few sure words and letters otherwise.
        let swedish = ReplyGuard.language(of: goal).map { $0 == .swedish }
            ?? (goal.lowercased().contains { "åäö".contains($0) } || t.contains { ["och", "det", "ljudet", "gör", "ta", "bort", "fixa", "spela", "radera", "bättre", "lite"].contains($0) })
        // Asking to record, not talking about a recording ("the recording is distorted").
        let recording = text.contains(" spela in ") || text.contains(" record a ") || text.contains(" record me ") || text.contains(" start recording ")
            || text.contains(" record new ") || text.contains(" ny inspelning ") || text.contains(" starta inspelning")
        let fileWords = ["fil", "filen", "filer", "file", "files", "disk", "disken", "originalfilen", "original"]
        let deleting = ["radera", "delete", "remove", "erase", "ta", "move", "flytta", "rename", "döp"].contains { text.contains(" \($0) ") }
        if recording {
            return swedish ? "Jag kan inte starta en inspelning; det gör du själv i Jämmer." : "I can't start a recording; that's up to you in Jämmer."
        }
        if deleting, t.contains(where: fileWords.contains) {
            return swedish ? "Jag kan inte radera eller flytta filer på disken. Redigeringar ändrar aldrig originalfilen." : "I can't delete or move files on disk. Edits never change the original file."
        }
        let actionWords = [" up ", " down ", "upp", " ner ", "klipp", "cut", "trim", "tona", "fade", "volym", "volume", "tystare", "quieter", "högre", "louder", "gain", "db", "lufs", "normalis", "normaliz",
                           "eko", "echo", "brum", "hum", "buzz", "klick", "click", "knast", "crackl", "brus", "noise", "hiss", "överstyr", "clip", "distort",
                           "tystnad", "paus", "pause", "silenc", "ehm", "öh", "filler", "fyllnad", "transkri", "transcri", "markör", "marker", "kopier", "copy",
                           "klistra", "paste", "markera", "select", "mät", "measure", "loud", "högt", "tempo", "bpm", "radera", "delete", "ta bort", "remove"]
        let hasAction = actionWords.contains { text.contains($0) }
        let hasNumber = t.contains { Double($0) != nil }
        if !hasAction, !hasNumber, t.count <= 5 {
            return swedish ? "Vad vill du att jag ändrar? Till exempel brus, brum, klick, nivå eller pauser."
                           : "What should I change? For example noise, hum, clicks, level or pauses."
        }
        return nil
    }

    /// A keyword safety net for the small model's most common miss: with several tasks in
    /// one sentence it may plan only one. If the request names filler words or pauses and
    /// the plan has no step for them, the macro is added (fillers first).
    public static func augment(goal: String, plan: AssistantPlan) -> AssistantPlan {
        let words = Set(Project.tokens(goal))
        let fillerKeys: Set<String> = Project.fillerWords.union(["fyllnadsord", "utfyllnadsord", "filler", "fillers", "ehms", "ums"])
        let pauseKeys: Set<String> = ["tystnad", "tystnader", "tystnaderna", "paus", "pauser", "pauserna", "silence", "silences", "pause", "pauses"]
        var out = plan
        let ops = Set(plan.steps.map(\.op))
        if !words.isDisjoint(with: fillerKeys), !ops.contains("remove_fillers"), !ops.contains("delete_words") {
            out.steps.insert(PlannedStep(op: "remove_fillers", why: "The request mentions filler words."), at: 0)
        }
        if !words.isDisjoint(with: pauseKeys), !ops.contains("remove_silences"), !ops.contains("delete"), !ops.contains("silence") {
            out.steps.append(PlannedStep(op: "remove_silences", why: "The request mentions pauses."))
        }
        return out
    }

    /// Checks steps against the registry (types, ranges, required params).
    public static func validate(_ plan: AssistantPlan, actions: [AssistantAction]) -> AssistantPlan {
        var out = plan
        out.steps = []
        for s in tidy(plan.steps, actions: actions) {
            guard let a = actions.first(where: { $0.name == s.op }) else { out.dropped.append(s.op); continue }
            if a.kind == .step {
                do { try StepRunner.validate(Step(op: s.op, params: s.params)) } catch { out.dropped.append("\(s.op) (\(error.localizedDescription))"); continue }
            } else if let missing = a.params.first(where: { $0.required && s.params[$0.name] == nil }) {
                out.dropped.append("\(s.op) (needs \(missing.name))")
                continue
            }
            out.steps.append(s)
        }
        return out
    }
}

/// Turns macros into concrete steps against the document as it will be at that point:
/// earlier steps run on a scratch copy first, so every range is right when the plan runs.
public enum MacroExpander {
    public static func expand(_ steps: [PlannedStep], state: EditState) throws -> [Step] {
        var scratch = state
        var out: [Step] = []
        let measure: StepRunner.Measure = { p, r in LoudnessMeter.measure(PlanCompiler.compile(p, pool: state.pool ?? SourcePool()), r) }
        for s in steps {
            let concrete: [Step]
            switch s.op {
            case "remove_fillers":
                let extra = Set(s.params["words"]?.strings ?? [])
                let ids = scratch.project.fillerWordIDs(extra: extra)
                concrete = ids.isEmpty ? [] : [Step(op: "delete_words", params: ["words": .array(ids.map { .string($0.uuidString) }), "bridge": .number(0.05)])]
            case "remove_silences":
                guard let pool = scratch.pool else { throw StepFailure("remove_silences needs the app.") }
                let p = scratch.project
                let minLen = p.frames(s.params["min_length"]?.double ?? 1)
                let keep = p.frames(s.params["keep"]?.double ?? 0.3)
                let found = p.silences(minLength: max(minLen, keep + 1), threshold: s.params["threshold"]?.double ?? -45, pool: pool)
                // Back to front, keeping half the kept pause on each side.
                concrete = found.reversed().compactMap { r -> Step? in
                    let a = r.lowerBound + keep / 2, b = r.upperBound - (keep - keep / 2)
                    guard b > a else { return nil }
                    return Step(op: "delete", params: ["start": .number(p.seconds(a)), "end": .number(p.seconds(b))])
                }
            default:
                concrete = [Step(op: s.op, params: s.params)]
            }
            for c in concrete {
                let r = StepRunner.run([c], on: &scratch, measure: measure)
                if r.first?.status == .failed { throw StepFailure("\(c.op): \(r.first?.error ?? "failed")") }
            }
            out += concrete
        }
        return out
    }
}
