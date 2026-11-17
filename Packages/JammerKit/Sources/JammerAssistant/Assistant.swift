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
    /// Settings that belong to one sort only (a sibling's `x-byType`, SIBLINGS.md §3): the parameter
    /// that chooses the sort, and for each of its values the names that go with it.
    public struct ByType: Sendable, Equatable {
        public var key: String
        public var names: [String: Set<String>]
    }
    public var byType: ByType?
    /// Names from an `x-byType` table that had no `x-byTypeKey`: which sort they go with can't be read,
    /// so they can't be checked, and Jämmer doesn't send them on a guess.
    public var uncheckable: Set<String> = []

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
                                                "echo", "restore", "remove_fillers", "remove_silences", "limit",
                                                // Taking a bus away takes its level, pan and sends with it: shown first, always.
                                                "remove_bus"]

    public static let macros: [AssistantAction] = [
        AssistantAction(name: "remove_fillers", description: "Removes every filler word (eh, ehm, öh, um, uh…) from the audio. Transcribes first if needed.",
                        params: [.init("words", .list, "More words to count as fillers.")], kind: .macro, destructive: true),
        AssistantAction(name: "remove_silences", description: "Removes long pauses (silences): every pause longer than min_length is cut down to keep seconds.",
                        params: [.init("min_length", .seconds, "Pauses at least this long, in seconds. Default 1.", range: 0.1...60),
                                 .init("keep", .seconds, "How much of each pause to keep, in seconds. Default 0.3.", range: 0...10),
                                 .init("threshold", .number, "Quiet means below this many dBFS. Default -45.", range: -90...(-10))],
                        kind: .macro, destructive: true),
    ]

    /// Actions that leave the document as it is: measurements, and where the playhead and the selection are.
    public static let changesNothing: Set<String> = ReplyGuard.measuring.union(["select", "select_all", "deselect", "set_playhead", "copy"])

    /// How a request names each action that changes the document, in Swedish and English (lowercased,
    /// matched anywhere in the request). Used for one thing: a step whose action the request doesn't
    /// name waits for a yes. Generous on purpose where a word could mean the action; an action missing
    /// here always waits.
    public static let spokenAs: [String: [String]] = {
        var w: [String: [String]] = [
            "set_track": ["pan", "left", "right", "vänster", "höger", "centre", "center", "mitten", "route", "send it to", "skicka", "bus", "buss", "mute", "tysta", "rename", "döp", "volym", "volume", "level", "nivå", " db", "gain", "track", "spår"],
            "gain": ["volym", "volume", "level", "nivå", " db", "louder", "quieter", "högre", "lägre", "tystare", "starkare", "svagare", "sänk", "höj", "lower", "raise", "gain", "boost", "turn up", "turn down", "loud", "quiet", "soft"],
            "normalize": ["normal", "lufs", "loudness", "ljudstyrk", "peak", "topp"],
            "fade_in": ["fade", "tona"], "fade_out": ["fade", "tona"],
            "echo": ["echo", "eko", "delay"],
            "restore": ["hum", "brum", "buzz", "click", "klick", "noise", "brus", "hiss", "clip", "överstyr", "distort", "reverb", "rumsklang", "eko", "echo", "repair", "laga", "restore", "rensa", "clean", "crackl", "knast", "knäpp", "sprak"],
            "add_marker": ["marker", "markör", "chapter", "kapitel"], "remove_marker": ["marker", "markör", "chapter", "kapitel"],
            "set_tempo": ["tempo", "bpm", "takt"], "remove_tempo_change": ["tempo", "bpm", "takt"],
            "transcribe": ["transcri", "transkri", "text", "skriv ut", "write down"],
            "insert_silence": ["silence", "tystnad", "paus", "pause", "gap", "lucka"],
            "silence": ["silence", "tysta", "mute", "tyst"],
            "delete": ["delete", "remove", "radera", "ta bort", "cut", "klipp", "stryk"], "cut": ["cut", "klipp"],
            "crop": ["crop", "trim", "beskär", "trimma", "keep only", "behåll bara"],
            "paste": ["paste", "klistra"],
            "delete_words": ["word", "ord", "delete", "remove", "ta bort", "radera", "stryk"],
            "correct_word": ["word", "ord", "rätta", "correct", "stava", "spell"],
            "remove_fillers": ["ehm", "eh ", "öh", "um ", "uh ", "filler", "fyllnad", "utfyllnad", "tvekljud"],
            "remove_silences": ["silence", "tystnad", "paus", "pause", "gap", "luckor"],
        ]
        for (op, words) in onDeviceWhenNamed where w[op] == nil { w[op] = words }
        return w
    }()

    /// How a request names the steps that only move the playhead or the selection. One of these that the
    /// request doesn't name is left out of the plan: it changes nothing, and "Done (1 step)" after "write a
    /// poem about the sea" is not an answer.
    public static let viewOnly: [String: [String]] = [
        "select": ["select", "markera", "välj", "choose", "from ", "från ", "between", "mellan", "first", "last", "första", "sista"],
        "select_all": ["select", "markera", "välj", "all", "everything", "allt", "hela"],
        "deselect": ["deselect", "avmarkera", "unselect", "clear the selection", "ingen markering"],
        "set_playhead": ["playhead", "spelhuvud", "go to", "gå till", "jump", "hoppa", "move to", "flytta", "start", "början", "beginning", "end", "slutet", "rewind", "spola", " at ", " vid "],
        "copy": ["copy", "kopier"],
    ]

    /// Values the assistant fills in when the model leaves out a required one.
    static let defaults: [String: [String: JSONValue]] = [
        "normalize": ["target": .string("loudness")],
        "echo": ["delay": .number(0.3)],
    ]

    /// Plugin steps need track and insert ids and weren't in the measured action set.
    /// (Buses are named to the model by name, and `set_bus` and `remove_bus` take the name. Sends are not offered yet.)
    public static let stepsNotForAssistant: Set<String> = ["set_timecode", "add_insert", "set_insert", "remove_insert", "spectral_edit", "set_track", "set_group", "set_automation", "clear_automation"]

    /// Own actions: every step (but the above), the useful endpoints, and the macros.
    public static var actions: [AssistantAction] {
        let endpointNames: Set<String> = ["transcribe", "restore", "analyze_restoration", "measure_loudness", "freeze", "unfreeze"]
        return Operations.all.filter { !stepsNotForAssistant.contains($0.name) }.map { AssistantAction(name: $0.name, description: $0.description, params: $0.params, kind: .step,
                                                    destructive: destructiveNames.contains($0.name)) }
            + Operations.endpoints.filter { endpointNames.contains($0.name) }.map {
                // The assistant transcribes on this Mac: sending audio to a paid service is the user's own
                // choice in the transcript panel, with its sheet, never something a plan does.
                AssistantAction(name: $0.name, description: $0.description,
                                params: $0.params.filter { !["model", "allowPaid", "allowUnknownPrice"].contains($0.name) }.map { p in
                                    var p = p
                                    p.options = p.options?.filter { $0 != "openai" }
                                    return p
                                }, kind: .endpoint,
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
        "limit": ["limit", "ceiling", "begräns", "tak ", "taket", "true peak", "dbtp", "peaks under", "toppar under", "topparna under"],
        // The mixer's later parts (2026-11-16): each only when the request has its word.
        "set_master": ["master", "mastern"],
        "set_send": [" send ", "sends", " sänd ", " skicka "],
        "add_vca": ["vca"],
        "set_vca": ["vca"],
        "remove_vca": ["vca"],
        "freeze": ["freeze", "frys"],
        "unfreeze": ["unfreeze", "thaw", "tina", "frys upp", "avfrys"],
        "add_bus": ["bus", "buss", "submix", "undergrupp"],
        "set_bus": ["bus", "buss", "submix"],
        "remove_bus": ["bus", "buss", "submix"],
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
    /// The mixer's buses, so that a request can name one ("turn the Music bus down").
    public var buses: [(id: String, name: String)] = []
    /// A bus by its name (or its id); "master" and "output" stay words for the output.
    public func busID(_ ref: String) -> String? {
        let r = ref.trimmingCharacters(in: .whitespaces)
        if ["master", "output", "the output", "utgången", "ut"].contains(r.lowercased()) { return "master" }
        // "the Music bus", "bussen Music" and "Music" are the same bus.
        func plain(_ s: String) -> String {
            let dropped: Set<String> = ["the", "bus", "bussen", "buss", "submix"]
            return s.lowercased().split(separator: " ").filter { !dropped.contains(String($0)) }.joined(separator: " ")
        }
        let hits = buses.filter { $0.id == r || $0.name.caseInsensitiveCompare(r) == .orderedSame || plain($0.name) == plain(r) }
        return hits.count == 1 ? hits[0].id : nil
    }
    /// The mixer's VCA groups, so that a request can name one.
    public var vcas: [(id: String, name: String)] = []
    /// A VCA group by its name (or its id): "the Drums VCA", "gruppen Drums" and "Drums" are the same group.
    public func vcaID(_ ref: String) -> String? {
        func plain(_ s: String) -> String {
            let dropped: Set<String> = ["the", "vca", "group", "gruppen", "grupp", "vca-gruppen"]
            return s.lowercased().split(separator: " ").filter { !dropped.contains(String($0)) }.joined(separator: " ")
        }
        let r = ref.trimmingCharacters(in: .whitespaces)
        let hits = vcas.filter { $0.id == r || $0.name.caseInsensitiveCompare(r) == .orderedSame || plain($0.name) == plain(r) }
        return hits.count == 1 ? hits[0].id : nil
    }
    /// A strip, as a request names one: a track (by name or number) or a bus (by name). A name that a
    /// track and a bus share is neither, rather than a guess. "master" is not a strip here.
    public func stripID(_ ref: String) -> String? {
        func plain(_ s: String) -> String {
            let dropped: Set<String> = ["the", "track", "spåret", "spår"]
            return s.lowercased().split(separator: " ").filter { !dropped.contains(String($0)) }.joined(separator: " ")
        }
        let r = ref.trimmingCharacters(in: .whitespaces)
        let track = trackID(r) ?? tracks.first { plain($0.name) == plain(r) }?.id
        let bus = busID(r).flatMap { $0 == "master" ? nil : $0 }
        if track != nil, bus != nil { return nil }
        return track ?? bus
    }
    /// "Speaker 2" / "talare 2" / track 2 → its id.
    public func trackID(_ ref: String) -> String? {
        if let n = Int(ref.filter(\.isNumber)), (1...tracks.count).contains(n), ref.count <= 12 { return tracks[n - 1].id }
        if let t = tracks.first(where: { $0.name.caseInsensitiveCompare(ref) == .orderedSame || $0.id == ref }) { return t.id }
        return nil
    }
    /// The strips that are frozen, and the master limiter's ceiling when it is on: said to the model so
    /// that "unfreeze the music" and "is there a limiter?" have something to go by.
    public var frozenNames: [String] = []
    public var masterLimiter: Double?
    public var transcriptLanguage: String?
    public var transcriptExcerpt: String?
    public var fillerCount: Int

    public init(project: Project, selection: Range<Frame>?, playhead: Frame) {
        duration = project.duration
        self.selection = selection.map { (project.seconds($0.lowerBound), project.seconds($0.upperBound)) }
        self.playhead = project.seconds(playhead)
        tracks = project.tracks.map { ($0.id.uuidString, $0.name) }
        buses = project.buses.map { ($0.id.uuidString, $0.name) }
        vcas = project.vcas.map { ($0.id.uuidString, $0.name) }
        frozenNames = project.tracks.filter { $0.frozen != nil }.map(\.name) + project.buses.filter { $0.frozen != nil }.map(\.name)
        masterLimiter = project.master.limiter.map(\.ceilingDB)
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
        if !buses.isEmpty { lines.append("- buses, by name: " + buses.map(\.name).joined(separator: ", ")) }
        if !vcas.isEmpty { lines.append("- VCA groups, by name: " + vcas.map(\.name).joined(separator: ", ")) }
        if !frozenNames.isEmpty { lines.append("- frozen: " + frozenNames.joined(separator: ", ")) }
        if let c = masterLimiter { lines.append("- master limiter: on, ceiling \(t(c)) dBTP") }
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
    /// Sentences of the model's that were taken out of the reply because a figure in them had nothing
    /// behind it (`ReplyGuard`). The user is told that something was held back; the evaluation prints them.
    public var heldBack: [String] = []
    /// What Jämmer chose in the model's place (a preset for a named delivery target). A plan with any of
    /// these is shown, with these lines, before anything runs.
    public var shownFirst: [String] = []
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

    /// The steps that would change the document although the request doesn't name them. A model answers
    /// "write a poem about the sea" with `set_tempo` now and then; such a step is not run on its say-so.
    /// On the safe side: an action Jämmer has no words for counts as not named.
    public func unasked(goal: String, actions: [AssistantAction]) -> [PlannedStep] {
        let text = " " + goal.lowercased() + " "
        return steps.filter { s in
            if AssistantCatalog.changesNothing.contains(s.op) { return false }
            if case .sibling? = actions.first(where: { $0.name == s.op })?.kind { return false }   // offered only when the request names the app
            guard let words = AssistantCatalog.spokenAs[s.op] else { return true }
            return !words.contains { text.contains($0) }
        }
    }

    /// Shown with Run and Cancel instead of being run: it removes or replaces audio, or it changes the
    /// document in a way the request didn't ask for in so many words.
    public func needsConfirmation(goal: String, actions: [AssistantAction]) -> Bool {
        isDestructive(actions) || !unasked(goal: goal, actions: actions).isEmpty || !shownFirst.isEmpty
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
        // A model sometimes names a value after what it is instead of after the parameter ("bus": "Music"
        // for add_bus's `name`). When exactly one required value is missing and exactly one value was given
        // under a name the action doesn't have, that value is the missing one.
        let known = Set(action.params.map(\.name))
        var args = args
        // The small model names the argument after the bus itself: {"Music": "-6"} for "set the Music bus
        // to −6 dB", {"Music": "muted"}. An argument whose name is the name of exactly one bus is the target,
        // and its value is the level when it is a number, or the mute when it says so.
        if ["set_bus", "remove_bus"].contains(op), let context, !args.contains(where: { $0.0 == "bus" }),
           let i = args.firstIndex(where: { !known.contains($0.0) && context.busID($0.0).map { $0 != "master" } == true }) {
            let (busName, value) = args[i]
            let v = value.trimmingCharacters(in: .whitespaces).lowercased()
            args[i] = ("bus", busName)
            if op == "set_bus" {
                if ["muted", "mute", "true", "tyst", "tysta", "silent", "off"].contains(v), !args.contains(where: { $0.0 == "muted" }) { args.append(("muted", "true")) }
                else if ["unmuted", "unmute", "false", "on"].contains(v), !args.contains(where: { $0.0 == "muted" }) { args.append(("muted", "false")) }
                else if Double(v.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "−", with: "-")) != nil, !args.contains(where: { $0.0 == "gainDB" }) { args.append(("gainDB", v)) }
            }
        }
        let missing = action.params.filter { p in p.required && !args.contains { $0.0 == p.name && !$0.1.trimmingCharacters(in: .whitespaces).isEmpty } }
        let strays = args.filter { !known.contains($0.0) && !$0.1.trimmingCharacters(in: .whitespaces).isEmpty }
        // Kept narrow: never for an action that removes or replaces audio (there the right name is asked
        // for, and the step is left out without it), and only when the value is of the kind that is missing.
        func fits(_ value: String, _ kind: OperationSpec.Param.Kind) -> Bool {
            let v = value.trimmingCharacters(in: .whitespaces)
            switch kind {
            case .number, .seconds:
                return Double(v.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "−", with: "-")) != nil
                    || (kind == .seconds && v.contains(":") && v.split(separator: ":").allSatisfy { Double($0) != nil })
            case .boolean: return ["true", "false", "yes", "no", "ja", "nej", "0", "1"].contains(v.lowercased())
            case .numbers: return !v.isEmpty && v.split(separator: ",").allSatisfy { Double($0.trimmingCharacters(in: .whitespaces)) != nil }
            case .pairs: return false
            case .string, .list: return true
            }
        }
        if !action.destructive, missing.count == 1, strays.count == 1, fits(strays[0].1, missing[0].kind),
           let i = args.firstIndex(where: { $0.0 == strays[0].0 }) { args[i].0 = missing[0].name }
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
            case .pairs:
                continue   // (automation points: not an assistant action yet)
            case .list:
                var items = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if name == "tracks", let context { items = items.compactMap { context.trackID($0) } }
                // A VCA group's members are tracks and buses, by name.
                if ["members", "add", "remove"].contains(name), ["add_vca", "set_vca"].contains(op), let context { items = items.compactMap { context.stripID($0) } }
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
                // A bus is named by its name; the step wants its id.
                if ["bus", "output", "reroute"].contains(name), ["set_bus", "remove_bus", "add_bus"].contains(op), let context {
                    guard let id = context.busID(v) else { continue }
                    v = id
                }
                // The mixer's other names: a strip to freeze, the two ends of a send, a VCA group.
                if let context {
                    if name == "strip", ["freeze", "unfreeze"].contains(op) { guard let id = context.stripID(v) else { continue }; v = id }
                    if op == "set_send", name == "from" { guard let id = context.stripID(v) else { continue }; v = id }
                    if op == "set_send", name == "to" { guard let id = context.busID(v), id != "master" else { continue }; v = id }
                    if name == "vca", ["set_vca", "remove_vca"].contains(op) { guard let id = context.vcaID(v) else { continue }; v = id }
                }
                params[name] = .string(v)
            }
        }
        // A group or a strip that the model named under another name than the parameter's ("name": "Voices"
        // for remove_vca's `vca`): a value it gave that is the name of exactly one is the one meant.
        if let context {
            let given = args.map(\.1)
            if ["set_vca", "remove_vca"].contains(op), params["vca"] == nil, let id = Set(given.compactMap { context.vcaID($0) }).onlyOne {
                params["vca"] = .string(id)
                if case .string(let n)? = params["name"], context.vcaID(n) == id { params["name"] = nil }
            }
            if ["freeze", "unfreeze"].contains(op), params["strip"] == nil, let id = Set(given.compactMap { context.stripID($0) }).onlyOne { params["strip"] = .string(id) }
            // Freezing without knowing what: no step, so that the user is asked.
            if ["freeze", "unfreeze"].contains(op), params["strip"] == nil { return nil }
        }
        for (k, v) in AssistantCatalog.defaults[op] ?? [:] where params[k] == nil { params[k] = v }
        // "set the Music bus to −6 dB" often comes with the bus's name under `name`, which for set_bus means
        // "rename to". When no bus is given and `name` is the name of a bus that exists, that bus is the one meant.
        // A bus sent to itself is not a route anyone asked for; the rest of the step stands.
        if op == "set_bus", let b = params["bus"], params["output"] == b { params["output"] = nil }
        if ["set_bus", "remove_bus"].contains(op), params["bus"] == nil, let context, case .string(let n)? = params["name"], let id = context.busID(n), id != "master" {
            params["bus"] = .string(id)
            params["name"] = nil
        }
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
                           "klistra", "paste", "markera", "select", "mät", "measure", "loud", "högt", "tempo", "bpm", "radera", "delete", "ta bort", "remove",
                           // The mixer and the mastering steps (2026-11-16): without these a short request about them was
                           // answered "What should I change?" before the model was asked.
                           "bus", "buss", "submix", "pan", "mixer", "limit", "begräns", "ceiling", "duck",
                           "freez", "frys", "tina", "master", "vca", "send", "skicka", "sänd"]
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
        // `delete_words` given nothing but filler words ("eh, ehm, öh, um, uh") is `remove_fillers` said the
        // long way: the small model plans it so for "ta bort alla ehm". The macro is the one that works
        // (it transcribes first when there is no transcript, and finds the words in every clip).
        func said(_ v: JSONValue?) -> [String] {
            switch v {
            case .string(let t): Project.tokens(t)
            case .array(let a): a.flatMap { said($0) }
            default: []
            }
        }
        out.steps = out.steps.map { step in
            guard step.op == "delete_words" else { return step }
            let named = said(step.params["text"]) + said(step.params["words"])
            guard !named.isEmpty, named.allSatisfy(Project.fillerWords.contains) else { return step }
            return PlannedStep(op: "remove_fillers", why: step.why)
        }
        if out.steps.filter({ $0.op == "remove_fillers" }).count > 1 {
            var seen = false
            out.steps.removeAll { s in guard s.op == "remove_fillers" else { return false }; defer { seen = true }; return seen }
        }
        // A bus: "mute" and "tysta" mean mute. The small model answers them with a level of 0, which changes
        // nothing, or with nothing at all; and now and then with taking the bus away as well, which nobody
        // asked for when the request says mute and not remove.
        let muteWords: Set<String> = ["mute", "tysta", "tyst", "silence", "stäng"], unmuteWords: Set<String> = ["unmute", "avtysta"]
        let removeWords: Set<String> = ["remove", "delete", "radera", "bort"]
        if !words.isDisjoint(with: muteWords.union(unmuteWords)) {
            if words.isDisjoint(with: removeWords) { out.steps.removeAll { $0.op == "remove_bus" } }
            out.steps = out.steps.map { step in
                guard step.op == "set_bus", step.params["bus"] != nil, step.params["muted"] == nil else { return step }
                var s = step
                s.params["muted"] = .bool(words.isDisjoint(with: unmuteWords))
                if s.params["gainDB"] == .number(0) { s.params["gainDB"] = nil }
                return s
            }
        }
        // A VCA group is muted by the same words.
        if !words.isDisjoint(with: muteWords.union(unmuteWords)) {
            out.steps = out.steps.map { step in
                guard step.op == "set_vca", step.params["vca"] != nil, step.params["muted"] == nil else { return step }
                var s = step
                s.params["muted"] = .bool(words.isDisjoint(with: unmuteWords))
                if s.params["gainDB"] == .number(0) { s.params["gainDB"] = nil }
                return s
            }
        }
        // The master: the small model fills in every setting it is shown ("limiter": false and a ceiling for
        // "lower the master 3 dB"; a gain as well as a ceiling for "a limiter at −1 dBTP"). What the request
        // doesn't speak of is taken out, and a limiter that is asked for is switched on.
        let limiterWords: Set<String> = ["limiter", "limitern", "limit", "begränsare", "begränsaren", "ceiling", "tak", "taket", "dbtp"]
        let offWords: Set<String> = ["off", "av", "remove", "bort", "disable", "without", "utan", "stäng"]
        out.steps = out.steps.map { step in
            guard step.op == "set_master" else { return step }
            var s = step
            if words.isDisjoint(with: limiterWords) {
                for k in ["limiter", "ceiling", "release", "lookahead"] { s.params[k] = nil }
            } else {
                let off = !words.isDisjoint(with: offWords)
                s.params["limiter"] = .bool(!off)
                if off { for k in ["ceiling", "release", "lookahead"] { s.params[k] = nil } }
                // One figure in the request, and it is the limiter's: not the master's gain as well.
                if s.params["gainDB"] == s.params["ceiling"] || s.params["gainDB"] == .number(0) || off { s.params["gainDB"] = nil }
                // Settings nobody gave a figure for stay as they are in the document.
                let said = ReplyGuard.numbers(in: goal) + ReplyGuard.wordNumbers(in: goal)
                for k in ["ceiling", "release", "lookahead"] { if case .number(let d)? = s.params[k], !said.contains(where: { abs($0 - abs(d)) < 0.0005 }) { s.params[k] = nil } }
            }
            return s
        }
        if out.steps.contains(where: { $0.op == "set_master" && $0.params.isEmpty }) {
            out.steps.removeAll { $0.op == "set_master" && $0.params.isEmpty }
            out.dropped.append("set_master (nothing to change was given)")
        }
        // "Master the episode for Spotify" answered with a normalize to a level the request never gave (−16,
        // where Spotify's target is −14): a wrong target that runs is worse than a step left out. A delivery
        // target that the request names is that preset, unless the request gives the level itself.
        // The targets are the presets' own list: a word of a preset's name (apple, spotify, r128, …) names it.
        var targets: [String: String] = [:]
        for p in LoudnessPreset.allCases { for w in p.rawValue.split(separator: "_") where w != "podcasts" { targets[String(w)] = p.rawValue } }
        if let preset = Set(words.compactMap { targets[$0] }).onlyOne, !out.steps.contains(where: { $0.op == "loudness_preset" }) {
            let said = ReplyGuard.numbers(in: goal) + ReplyGuard.wordNumbers(in: goal)
            out.steps = out.steps.map { step in
                guard step.op == "normalize" else { return step }
                if case .number(let level)? = step.params["level"], said.contains(where: { abs($0 - abs(level)) < 0.0005 }) { return step }
                var params: [String: JSONValue] = ["preset": .string(preset)]
                for k in ["start", "end"] { params[k] = step.params[k] }
                // Jämmer's choice, not the request's words: the plan is shown with the preset and its targets before anything runs.
                out.shownFirst.append("\(LoudnessPreset(rawValue: preset)?.title ?? preset): the preset for the target you named, not a level of the assistant's own.")
                return PlannedStep(op: "loudness_preset", params: params, why: step.why)
            }
        }
        // "Mute the Voices group" answered with a new group called "muted": nobody asked for a new group.
        let makeWords: Set<String> = ["add", "create", "new", "make", "need", "want", "skapa", "lägg", "ny", "nytt", "gör", "behöver", "vill"]
        if words.isDisjoint(with: makeWords), out.steps.contains(where: { $0.op == "add_vca" || $0.op == "add_bus" }) {
            out.steps.removeAll { $0.op == "add_vca" || $0.op == "add_bus" }
            out.dropped.append("a new group or bus (the request doesn't ask for one to be made)")
        }
        // "Freeze the Music bus" answered with a change to the bus that changes nothing: the bus is the strip
        // to freeze. (The small model knows set_bus better than freeze.)
        let freezeWords: Set<String> = ["freeze", "frys", "frysa"], unfreezeWords: Set<String> = ["unfreeze", "thaw", "tina", "avfrys"]
        if !words.isDisjoint(with: freezeWords.union(unfreezeWords)), !out.steps.contains(where: { ["freeze", "unfreeze"].contains($0.op) }) {
            out.steps = out.steps.map { step in
                guard step.op == "set_bus", let bus = step.params["bus"], Set(step.params.keys).subtracting(["bus"]).isEmpty else { return step }
                return PlannedStep(op: words.isDisjoint(with: unfreezeWords) ? "freeze" : "unfreeze", params: ["strip": bus], why: step.why)
            }
        }
        // "Send Erik to the Music bus at −6 dB" answered with the bus's own level set to −6: not what was asked,
        // and it would change the whole bus. Left out, so that the user is asked.
        let sendWords: Set<String> = ["send", "sends", "skicka", "sänd"]
        if !words.isDisjoint(with: sendWords), !out.steps.contains(where: { $0.op == "set_send" }), out.steps.contains(where: { $0.op == "set_bus" }) {
            out.steps.removeAll { $0.op == "set_bus" }
            out.dropped.append("set_bus (the request is about a send, not the bus's own level)")
        }
        // A change to a bus that changes nothing is left out, so that the user is asked instead of told "done".
        let empty = out.steps.filter { $0.op == "set_bus" && Set($0.params.keys).subtracting(["bus"]).isEmpty }
        if !empty.isEmpty {
            out.steps.removeAll { $0.op == "set_bus" && Set($0.params.keys).subtracting(["bus"]).isEmpty }
            out.dropped.append("set_bus (nothing to change was given)")
        }
        let ops = Set(out.steps.map(\.op))
        if !words.isDisjoint(with: fillerKeys), !ops.contains("remove_fillers"), !ops.contains("delete_words") {
            out.steps.insert(PlannedStep(op: "remove_fillers", why: "The request mentions filler words."), at: 0)
        }
        // "Remove the pauses" planned as deleting from the start to somewhere the request never named
        // (the small model deletes the whole document): what was asked for is the pauses.
        if !words.isDisjoint(with: pauseKeys), !ops.contains("remove_silences") {
            let named = ReplyGuard.numbers(in: goal)
            func number(_ v: JSONValue?) -> Double? { if case .number(let d)? = v { return d }; return nil }
            out.steps = out.steps.map { step in
                guard step.op == "delete", (number(step.params["start"]) ?? 0) == 0, let end = number(step.params["end"]),
                      !named.contains(where: { abs($0 - end) < 0.0005 }) else { return step }
                return PlannedStep(op: "remove_silences", why: step.why)
            }
        }
        let after = Set(out.steps.map(\.op))
        // Putting silence in is not a request to take pauses out.
        if !words.isDisjoint(with: pauseKeys), !after.contains("remove_silences"), !after.contains("delete"), !after.contains("silence"), !after.contains("insert_silence") {
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
            } else if let unread = s.params.keys.sorted().first(where: { a.uncheckable.contains($0) }) {
                out.dropped.append("\(s.op) (\"\(unread)\" depends on a sort that its schema doesn't name, so it can't be checked and wasn't sent)")
                continue
            } else if let table = a.byType, let misplaced = s.params.keys.sorted().first(where: { name in
                table.names.values.contains { $0.contains(name) } && !(s.params[table.key]?.string.flatMap { table.names[$0] }?.contains(name) ?? false)
            }) {
                let sort = s.params[table.key]?.string
                out.dropped.append("\(s.op) (\"\(misplaced)\" doesn't go with \(sort.map { "\(table.key) \($0)" } ?? "no \(table.key)"))")
                continue
            } else if let strange = s.params.keys.sorted().first(where: { name in name != AgentAPI.rationale && !a.params.contains { $0.name == name } }) {
                // An endpoint of ours, or a sibling's operation: its schema is closed. A name it doesn't
                // have is not sent to see what happens; the call isn't made (SIBLINGS.md §3).
                out.dropped.append("\(s.op) (has no parameter \"\(strange)\"; it takes: \(a.params.map(\.name).sorted().joined(separator: ", ")))")
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
                guard !scratch.project.areTextOnly(Set(ids)) else { throw StepFailure("remove_fillers: " + SourceTranscript.textOnlyReason, reason: "text_only") }
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

extension Set {
    /// The element, when there is exactly one.
    var onlyOne: Element? { count == 1 ? first : nil }
}
