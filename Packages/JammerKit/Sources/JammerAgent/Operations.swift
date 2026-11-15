import Foundation
import JammerCore

/// One editing operation, as the menu, the command palette, App Intents and the
/// agent API all see it. The guide and `GET /api/v1/operations` are generated
/// from this list, so they can't drift from what the app actually does.
public struct OperationSpec: Sendable, Identifiable {
    public struct Param: Sendable {
        public enum Kind: String, Sendable { case seconds, number, string, boolean, list }
        public var name: String
        public var kind: Kind
        public var description: String
        public var required: Bool
        public var options: [String]?
        /// Allowed values for numbers, checked before a step runs and published in the schema.
        public var range: ClosedRange<Double>?
        /// For endpoints: where the value goes ("path" or "query"); nil is the body.
        public var location: String?

        public init(_ name: String, _ kind: Kind, _ description: String, required: Bool = false, options: [String]? = nil,
                    range: ClosedRange<Double>? = nil) {
            self.name = name
            self.kind = kind
            self.description = description
            self.required = required
            self.options = options
            self.range = range
        }

        /// JSON Schema for this parameter.
        public var schema: [String: Any] {
            var d: [String: Any] = ["description": description]
            switch kind {
            case .seconds: d["type"] = "number"; d["minimum"] = range?.lowerBound ?? 0
            case .number: d["type"] = "number"
            case .string: d["type"] = "string"
            case .boolean: d["type"] = "boolean"
            case .list: d["type"] = "array"; d["items"] = ["type": "string"]
            }
            if let range, kind != .seconds || range.lowerBound != 0 { d["minimum"] = range.lowerBound }
            if let range { d["maximum"] = range.upperBound }
            if let options { d["enum"] = options }
            if let location { d["x-in"] = location }
            return d
        }

        func at(_ location: String) -> Param { var p = self; p.location = location; return p }
    }

    public var name: String
    /// Menu / palette title.
    public var title: String
    public var description: String
    public var params: [Param]
    /// Calls a paid cloud service (none yet).
    public var paid: Bool
    /// Changes the document (and so lands in undo).
    public var edits: Bool
    /// An endpoint of its own rather than a step: how to call it, and whether it answers with a job.
    public var call: (method: String, path: String)?
    public var startsJob: Bool

    public var id: String { name }

    /// Every parameter including the document id in the path, for endpoints; GET parameters go in the query.
    public var allParams: [Param] {
        guard let call else { return params }
        let id = Param("id", .string, "The document id (GET /api/v1/documents lists them).", required: true).at("path")
        return [id] + (call.method == "GET" ? params.map { $0.at("query") } : params)
    }

    /// `params` as a JSON Schema object (SIBLINGS.md §3); `x-in` marks path and query values.
    public var schema: [String: Any] {
        var props: [String: Any] = [:]
        for p in allParams { props[p.name] = p.schema }
        return ["type": "object", "properties": props, "required": allParams.filter(\.required).map(\.name), "additionalProperties": false]
    }

    init(_ name: String, _ title: String, _ description: String, params: [Param] = [], paid: Bool = false, edits: Bool = true,
         call: (method: String, path: String)? = nil, startsJob: Bool = false) {
        self.name = name
        self.title = title
        self.description = description
        self.params = params
        self.paid = paid
        self.edits = edits
        self.call = call
        self.startsJob = startsJob
    }
}

public enum Operations {
    static let start = OperationSpec.Param("start", .seconds, "Range start in seconds. With `end`, overrides the selection.")
    static let end = OperationSpec.Param("end", .seconds, "Range end in seconds.")

    public static let all: [OperationSpec] = [
        .init("select", "Select Range", "Selects a range. Later steps without `start`/`end` act on it.",
              params: [.init("start", .seconds, "Start in seconds.", required: true), .init("end", .seconds, "End in seconds.", required: true)], edits: false),
        .init("select_all", "Select All", "Selects the whole document.", edits: false),
        .init("deselect", "Deselect", "Clears the selection.", edits: false),
        .init("set_playhead", "Move Playhead", "Moves the playhead (where paste and markers go by default).",
              params: [.init("at", .seconds, "Position in seconds.", required: true)], edits: false),
        .init("delete", "Delete", "Removes the range and closes the gap (everything after moves left).", params: [start, end]),
        .init("silence", "Silence", "Replaces the range with silence without moving anything.", params: [start, end]),
        .init("cut", "Cut", "Copies the range to Jammer's clipboard and removes it, closing the gap.", params: [start, end]),
        .init("copy", "Copy", "Copies the range to Jammer's clipboard.", params: [start, end], edits: false),
        .init("paste", "Paste", "Inserts the clipboard, pushing what follows to the right.",
              params: [.init("at", .seconds, "Where to insert. Defaults to the selection start, else the playhead.")]),
        .init("crop", "Crop to Selection", "Keeps only the range.", params: [start, end]),
        .init("insert_silence", "Insert Silence", "Opens a silent gap.",
              params: [.init("at", .seconds, "Position in seconds. Defaults to the playhead."),
                       .init("duration", .seconds, "Length of the gap in seconds.", required: true)]),
        .init("gain", "Change Gain", "Changes the level of the range (the whole document without a range or selection).",
              params: [.init("db", .number, "Change in dB, e.g. -3 or 2.5.", required: true), start, end]),
        .init("fade_in", "Fade In", "Fades in over the range. The range must lie inside one clip per track.",
              params: [start, end, .init("shape", .string, "Fade curve.", options: ["equal_power", "linear"])]),
        .init("fade_out", "Fade Out", "Fades out over the range. The range must lie inside one clip per track.",
              params: [start, end, .init("shape", .string, "Fade curve.", options: ["equal_power", "linear"])]),
        .init("normalize", "Normalize", "Sets the level of the range (the whole document without a range or selection) to a target.",
              params: [.init("target", .string, "What to match.", required: true, options: ["loudness", "peak", "true_peak"]),
                       .init("level", .number, "Target: LUFS for loudness, dBFS for peak, dBTP for true_peak. E.g. -16 or -1.", required: true),
                       start, end]),
        .init("add_marker", "Add Marker", "Adds a marker, or a region when `duration` is given.",
              params: [.init("at", .seconds, "Position in seconds. Defaults to the selection start, else the playhead."),
                       .init("name", .string, "Marker name.", required: true),
                       .init("duration", .seconds, "Region length in seconds.")]),
        .init("remove_marker", "Remove Marker", "Removes the markers with this name.",
              params: [.init("name", .string, "Marker name.", required: true)]),
        .init("set_tempo", "Set Tempo", "Sets the tempo, and the time signature when given, from `at` on. Tempo changes move with the audio in ripple edits.",
              params: [.init("bpm", .number, "Quarter notes per minute, 10–999.", required: true),
                       .init("at", .seconds, "Where the tempo starts. Defaults to 0, the start of the document."),
                       .init("beats", .number, "Beats per bar (1–64). Give it with `unit`; without both, the time signature in effect at `at` is kept."),
                       .init("unit", .number, "Note value of a beat: 1, 2, 4, 8, 16 or 32 (4 is a quarter note).")]),
        .init("delete_words", "Delete Words", "Removes words from the audio by their transcript, closing the gaps (ripple). Give word ids (best: they stay valid across edits, undo and saving) or the text to find. Text must match in exactly one place, unless you pass `occurrence` or `all`.",
              params: [.init("words", .list, "Word ids from GET /api/v1/documents/{id}/transcript."),
                       .init("text", .string, "A word or phrase as it reads in the transcript; case and punctuation don't count."),
                       .init("occurrence", .number, "With `text`: which match, counting from 1."),
                       .init("all", .boolean, "With `text`: every match."),
                       .init("bridge", .seconds, "Also remove pauses up to this long between the deleted words. Default 0.")]),
        .init("correct_word", "Correct Word", "Changes how a word is spelled in the transcript. The audio doesn't change.",
              params: [.init("word", .string, "The word's id.", required: true),
                       .init("text", .string, "The corrected text.", required: true)]),
        .init("echo", "Echo", "Adds a feedback echo to the range (the whole document without a range or selection), bounced into a new file per track; the original audio is untouched and one undo brings it back. With `tail`, the document grows after the range so the echoes ring out.",
              params: [.init("delay", .seconds, "Time between repeats in seconds, 0.02–2.", required: true, range: 0.02...2),
                       .init("feedback", .number, "How much of each repeat comes back, 0–0.95. Default 0.4.", range: 0...0.95),
                       .init("mix", .number, "Level of the echoes against the original, 0–1. Default 0.35; 0 changes nothing.", range: 0...1),
                       start, end,
                       .init("tracks", .list, "Track ids to change. Default: every track."),
                       .init("tail", .boolean, "Make room after the range for the echoes to ring out. Default false.")]),
        .init("remove_tempo_change", "Remove Tempo Change", "Removes the tempo change at exactly `at` (see `tempo.changes` in the document). The first one can't be removed, only changed with `set_tempo`.",
              params: [.init("at", .seconds, "Position of the change in seconds.", required: true)]),
    ]

    /// Work that has an endpoint of its own (jobs, analysis, listening), described the same
    /// way so agents and assistants see one list. Not valid in `steps`.
    static let restoreParams: [OperationSpec.Param] = [
        .init("kind", .string, "The repair.", required: true, options: Restoration.Kind.allCases.map(\.rawValue)),
        .init("amount", .number, "Blend between the original (0) and the full repair (1). Default 1.", range: 0...1),
        start, end,
        .init("tracks", .list, "Track ids to repair. Default: every track."),
        .init("humFrequency", .number, "dehum: the mains frequency; without it 50 or 60 Hz is found.", range: 20...400),
        .init("sensitivity", .number, "declick: higher finds quieter clicks. Default 1.", range: 0.1...10),
    ]
    public static let endpoints: [OperationSpec] = [
        .init("transcribe", "Transcribe", "Transcribes the document on this Mac; words get ids and times. Answers with a job; the transcript lands as one undo step.",
              params: [.init("language", .string, "BCP 47, e.g. sv-SE or en-US. Default: the Mac's language."),
                       .init("engine", .string, "Recogniser.", options: ["auto", "apple"]),
                       .init("replace", .boolean, "Transcribe again even where there is a transcript.")],
              call: ("POST", "/api/v1/documents/{id}/transcribe"), startsJob: true),
        .init("get_transcript", "Read Transcript", "The words as they play now, with ids, times and confidence.",
              params: [start, end], edits: false, call: ("GET", "/api/v1/documents/{id}/transcript")),
        .init("measure_loudness", "Measure Loudness", "Integrated LUFS, loudness range, max momentary and short-term, sample and true peak.",
              params: [start, end], edits: false, call: ("GET", "/api/v1/documents/{id}/analysis")),
        .init("analyze_restoration", "Find Problems", "Looks for mains hum, clipping and clicks without changing anything.",
              params: [start, end, .init("tracks", .list, "Track ids (query: comma-separated).")], edits: false,
              call: ("GET", "/api/v1/documents/{id}/analysis/restoration")),
        .init("restore_preview", "Preview Repair", "The repaired audio of at most 30 s, without changing the document; with Accept: application/json the measurements before and after.",
              params: restoreParams, edits: false, call: ("POST", "/api/v1/documents/{id}/restore/preview")),
        .init("export", "Export Audio", "The rendered audio as bytes (at most 2 GB per response; export a range for more).",
              params: [.init("format", .string, "File format. Default wav.", options: ExportFormat.allCases.map(\.rawValue)),
                       .init("bitDepth", .number, "wav 16, 24 or 32 (float); aiff, flac and alac 16 or 24. Default 24.", options: nil, range: 16...32),
                       .init("bitRate", .number, "aac only, bits per second. Default 192000.", range: 64_000...320_000),
                       start, end, .init("dither", .boolean, "TPDF dither when writing 16 or 24-bit wav.")],
              edits: false, call: ("POST", "/api/v1/documents/{id}/export")),
        .init("restore", "Repair", "Removes hum, repairs clipping, removes clicks or reduces noise. Answers with a job; one undo step brings the original back.",
              params: restoreParams, call: ("POST", "/api/v1/documents/{id}/restore"), startsJob: true),
    ]

    public static func named(_ name: String) -> OperationSpec? { all.first { $0.name == name } }
    public static var paidNames: Set<String> { Set(all.filter(\.paid).map(\.name)) }
}

// MARK: Running steps

public struct Step: Sendable {
    public var op: String
    public var params: [String: JSONValue]

    public init(op: String, params: [String: JSONValue] = [:]) {
        self.op = op
        self.params = params
    }
}

/// A JSON value from a request body, so steps stay Sendable.
public enum JSONValue: Sendable, Equatable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case array([JSONValue])
    case null

    public init?(_ any: Any) {
        if let n = any as? NSNumber {
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        } else if let s = any as? String {
            self = .string(s)
        } else if let a = any as? [Any] {
            var items: [JSONValue] = []
            for x in a { guard let v = JSONValue(x) else { return nil }; items.append(v) }
            self = .array(items)
        } else if any is NSNull {
            self = .null
        } else {
            return nil
        }
    }

    public var double: Double? {
        switch self {
        case .number(let d): d
        case .string(let s): Double(s)
        default: nil
        }
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var strings: [String]? {
        guard case .array(let a) = self else { return nil }
        let s = a.compactMap(\.string)
        return s.count == a.count ? s : nil
    }
}

/// Everything a step can change: the document and the session around it.
public struct EditState: Sendable {
    public var project: Project
    public var selection: Range<Frame>?
    public var playhead: Frame
    public var clipboard: ClipboardContent?
    /// For steps that render audio (echo): where sources are read and new files written.
    public var pool: SourcePool?
    public var media: URL?

    public init(project: Project, selection: Range<Frame>? = nil, playhead: Frame = 0, clipboard: ClipboardContent? = nil,
                pool: SourcePool? = nil, media: URL? = nil) {
        self.project = project
        self.selection = selection
        self.playhead = playhead
        self.clipboard = clipboard
        self.pool = pool
        self.media = media
    }
}

public struct StepResult: Sendable, Equatable {
    public enum Status: String, Sendable { case done, failed, skipped, reverted }
    public var op: String
    public var status: Status
    public var error: String?
    /// Extra facts the step found (e.g. the gain normalize applied).
    public var info: [String: Double] = [:]
    /// Why it failed, for agents: e.g. "ambiguous", "not_found".
    public var reason: String?
    /// Numbers that go with the reason, e.g. ["matches": 3].
    public var details: [String: Double] = [:]
}

public struct StepFailure: Error, LocalizedError {
    public var message: String
    public var reason: String?
    public var details: [String: Double]
    public init(_ message: String, reason: String? = nil, details: [String: Double] = [:]) {
        self.message = message
        self.reason = reason
        self.details = details
    }
    public var errorDescription: String? { message }
}

public enum StepRunner {
    /// Measures loudness of a project range (the session renders; tests can fake it).
    public typealias Measure = @Sendable (Project, Range<Frame>) -> LoudnessResult

    /// Runs steps in order on a copy of `state`; stops at the first failure and
    /// marks the rest skipped. The caller commits `state` (one undo step) only if
    /// something changed.
    public static func run(_ steps: [Step], on state: inout EditState, measure: Measure) -> [StepResult] {
        var results: [StepResult] = []
        var failed = false
        for step in steps {
            if failed {
                results.append(StepResult(op: step.op, status: .skipped))
                continue
            }
            do {
                let info = try apply(step, to: &state, measure: measure)
                results.append(StepResult(op: step.op, status: .done, info: info))
            } catch {
                let f = error as? StepFailure
                results.append(StepResult(op: step.op, status: .failed, error: error.localizedDescription,
                                          reason: f?.reason, details: f?.details ?? [:]))
                failed = true
                // Nothing from a failed request is kept.
                for i in results.indices where results[i].status == .done { results[i].status = .reverted }
            }
        }
        return results
    }

    /// Checks names and required params before anything runs.
    public static func validate(_ step: Step) throws {
        guard let spec = Operations.named(step.op) else { throw StepFailure("Unknown op \"\(step.op)\".") }
        for p in spec.params where p.required && step.params[p.name] == nil {
            throw StepFailure("\(step.op) needs \"\(p.name)\".")
        }
        for (key, value) in step.params {
            guard let p = spec.params.first(where: { $0.name == key }) else {
                throw StepFailure("\(step.op) has no parameter \"\(key)\". It takes: \(spec.params.map(\.name).joined(separator: ", ")).")
            }
            switch p.kind {
            case .seconds, .number:
                guard let d = value.double, d.isFinite else { throw StepFailure("\(step.op): \"\(key)\" must be a number.") }
                if p.kind == .seconds, d < 0 { throw StepFailure("\(step.op): \"\(key)\" can't be negative.") }
                if let r = p.range, !r.contains(d) {
                    throw StepFailure("\(step.op): \"\(key)\" must be between \(r.lowerBound.formatted()) and \(r.upperBound.formatted()).")
                }
            case .string:
                guard let s = value.string else { throw StepFailure("\(step.op): \"\(key)\" must be a string.") }
                if let options = p.options, !options.contains(s) {
                    throw StepFailure("\(step.op): \"\(key)\" must be one of \(options.joined(separator: ", ")).")
                }
            case .boolean:
                guard case .bool = value else { throw StepFailure("\(step.op): \"\(key)\" must be true or false.") }
            case .list:
                guard value.strings != nil else { throw StepFailure("\(step.op): \"\(key)\" must be a list of strings.") }
            }
        }
    }

    static func apply(_ step: Step, to s: inout EditState, measure: Measure) throws -> [String: Double] {
        try validate(step)
        let p = step.params
        let project = s.project
        func frames(_ key: String) -> Frame? { p[key]?.double.map { project.frames($0) } }
        /// The explicit range, else the selection, else (when allowed) everything.
        func range(wholeIfNone: Bool = false) throws -> Range<Frame> {
            if let a = frames("start"), let b = frames("end") {
                guard b > a else { throw StepFailure("\(step.op): end must be after start.") }
                return a..<b
            }
            if p["start"] != nil || p["end"] != nil { throw StepFailure("\(step.op): give both start and end, or neither.") }
            if let sel = s.selection, !sel.isEmpty { return sel }
            if wholeIfNone, project.length > 0 { return 0..<project.length }
            throw StepFailure("\(step.op) needs a range: pass start and end, or select first.")
        }
        func checkInside(_ r: Range<Frame>) throws {
            guard r.lowerBound < project.length else {
                throw StepFailure("\(step.op): the range starts after the end of the audio (\(String(format: "%.3f", project.duration)) s).")
            }
        }

        switch step.op {
        case "select":
            let r = try range()
            try checkInside(r)
            s.selection = r.clamped(to: 0..<project.length)
        case "select_all":
            s.selection = project.length > 0 ? 0..<project.length : nil
        case "deselect":
            s.selection = nil
        case "set_playhead":
            s.playhead = min(max(0, frames("at") ?? 0), project.length)
        case "delete":
            let r = try range(); try checkInside(r)
            try s.project.delete(r)
            s.selection = nil
            s.playhead = r.lowerBound
        case "silence":
            let r = try range(); try checkInside(r)
            try s.project.silence(r)
        case "cut":
            let r = try range(); try checkInside(r)
            s.clipboard = try s.project.cut(r)
            s.selection = nil
            s.playhead = r.lowerBound
        case "copy":
            let r = try range(); try checkInside(r)
            s.clipboard = try s.project.copy(r)
        case "paste":
            guard let clip = s.clipboard else { throw StepFailure("The clipboard is empty. Copy or cut first.") }
            let at = min(frames("at") ?? s.selection?.lowerBound ?? s.playhead, project.length)
            try s.project.paste(clip, at: at)
            s.selection = at..<(at + clip.length)
        case "crop":
            let r = try range(); try checkInside(r)
            try s.project.crop(to: r)
            s.selection = nil
            s.playhead = 0
        case "insert_silence":
            let at = min(frames("at") ?? s.playhead, project.length)
            let n = frames("duration") ?? 0
            guard n > 0 else { throw StepFailure("insert_silence: duration must be more than 0.") }
            s.project.insertGap(at: at, length: n)
        case "gain":
            let r = try range(wholeIfNone: true); try checkInside(r)
            try s.project.changeGain(r, by: p["db"]?.double ?? 0)
        case "fade_in", "fade_out":
            let r = try range(); try checkInside(r)
            let shape: FadeShape = p["shape"]?.string == "linear" ? .linear : .equalPower
            try s.project.fade(step.op == "fade_in" ? .fadeIn : .fadeOut, r, shape: shape)
        case "normalize":
            let r = try range(wholeIfNone: true); try checkInside(r)
            let target = p["target"]?.string ?? "loudness"
            let level = p["level"]?.double ?? -16
            let m = measure(s.project, r)
            let current: Double?
            switch target {
            case "peak": current = m.samplePeak.isFinite ? m.samplePeak : nil
            case "true_peak": current = m.truePeak.isFinite ? m.truePeak : nil
            default: current = m.integrated
            }
            guard let current else { throw StepFailure("normalize: the range is silent, so there's nothing to match.") }
            let change = level - current
            try s.project.changeGain(r, by: change)
            return ["gainDB": (change * 100).rounded() / 100, "before": (current * 100).rounded() / 100]
        case "add_marker":
            let at = min(frames("at") ?? s.selection?.lowerBound ?? s.playhead, project.length)
            s.project.addMarker(at: at, length: frames("duration") ?? 0, name: p["name"]?.string ?? "Marker")
        case "remove_marker":
            let name = p["name"]?.string ?? ""
            let before = s.project.markers.count
            s.project.markers.removeAll { $0.name == name }
            guard s.project.markers.count < before else { throw StepFailure("remove_marker: no marker named \"\(name)\".") }
        case "delete_words":
            let bridge = frames("bridge") ?? 0
            let ids: Set<UUID>
            if let list = p["words"]?.strings {
                guard p["text"] == nil else { throw StepFailure("delete_words: give words or text, not both.") }
                var set = Set<UUID>()
                let known = Set(project.placedWords().map(\.word.id))
                for w in list {
                    guard let id = UUID(uuidString: w), known.contains(id) else {
                        throw StepFailure("delete_words: no word with id \(w) plays in the document.", reason: "not_found")
                    }
                    set.insert(id)
                }
                ids = set
            } else if let text = p["text"]?.string {
                let matches = project.findPhrase(text)
                guard !matches.isEmpty else { throw StepFailure("delete_words: \"\(text)\" isn't in the transcript.", reason: "not_found", details: ["matches": 0]) }
                if p["all"].map({ $0 == .bool(true) }) == true {
                    ids = Set(matches.flatMap { $0 })
                } else if let n = p["occurrence"]?.double {
                    guard n == n.rounded(), n >= 1, Int(n) <= matches.count else {
                        throw StepFailure("delete_words: occurrence must be 1–\(matches.count).", reason: "not_found", details: ["matches": Double(matches.count)])
                    }
                    ids = Set(matches[Int(n) - 1])
                } else {
                    guard matches.count == 1 else {
                        throw StepFailure("delete_words: \"\(text)\" occurs \(matches.count) times. Pass occurrence (1–\(matches.count)), all: true, or word ids.",
                                          reason: "ambiguous", details: ["matches": Double(matches.count)])
                    }
                    ids = Set(matches[0])
                }
            } else {
                throw StepFailure("delete_words needs words (ids) or text.")
            }
            let removed = project.ranges(ofWords: ids, bridge: bridge).reduce(Frame(0)) { $0 + Frame($1.count) }
            try s.project.deleteWords(ids, bridge: bridge)
            s.selection = nil
            return ["words": Double(ids.count), "removedSeconds": (project.seconds(removed) * 1_000).rounded() / 1_000]
        case "correct_word":
            guard let id = UUID(uuidString: p["word"]?.string ?? "") else { throw StepFailure("correct_word: word must be a word id.", reason: "not_found") }
            let text = (p["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw StepFailure("correct_word: text can't be empty. Use delete_words to remove a word.") }
            do { try s.project.correctWord(id, to: text) } catch {
                throw StepFailure("correct_word: no word with id \(id.uuidString).", reason: "not_found")
            }
        case "echo":
            guard let pool = s.pool, let media = s.media else { throw StepFailure("echo needs the app to render audio.") }
            let r = try range(wholeIfNone: true); try checkInside(r)
            var tracks: Set<UUID>?
            if let ids = p["tracks"]?.strings {
                var set = Set<UUID>()
                for t in ids {
                    guard let id = UUID(uuidString: t), project.tracks.contains(where: { $0.id == id }) else {
                        throw StepFailure("echo: no track with id \(t).", reason: "not_found")
                    }
                    set.insert(id)
                }
                tracks = set
            }
            let e = Echo(delay: p["delay"]?.double ?? 0.3, feedback: p["feedback"]?.double ?? 0.4, mix: p["mix"]?.double ?? 0.35)
            let tail = p["tail"].map { $0 == .bool(true) } ?? false
            s.project = try s.project.applyingEcho(e, range: r, tracks: tracks, tail: tail, pool: pool, media: media)
            return ["tailSeconds": tail ? (project.seconds(e.tail(sampleRate: project.sampleRate)) * 1_000).rounded() / 1_000 : 0]
        case "set_tempo":
            var meter: Meter?
            switch (p["beats"]?.double, p["unit"]?.double) {
            case (nil, nil): meter = nil
            case let (b?, u?):
                guard b == b.rounded(), u == u.rounded(), abs(b) < 1_000, abs(u) < 1_000 else {
                    throw StepFailure("set_tempo: beats and unit must be whole numbers.")
                }
                meter = Meter(Int(b), Int(u))
            default: throw StepFailure("set_tempo: give both beats and unit, or neither.")
            }
            do {
                try s.project.tempo.set(bpm: p["bpm"]?.double ?? 0, meter: meter, at: frames("at") ?? 0)
            } catch { throw StepFailure("set_tempo: \(error.localizedDescription)") }
        case "remove_tempo_change":
            let at = frames("at") ?? 0
            do { try s.project.tempo.removeChange(at: at) } catch {
                let list = s.project.tempo.changes.dropFirst().map { String(format: "%.6g", project.seconds($0.position)) }
                throw StepFailure("remove_tempo_change: \(error.localizedDescription)" + (list.isEmpty ? "" : " Changes are at: \(list.joined(separator: ", ")) s."))
            }
        default:
            throw StepFailure("Unknown op \"\(step.op)\".")
        }
        return [:]
    }
}
