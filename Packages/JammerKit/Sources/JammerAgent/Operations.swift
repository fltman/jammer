import Foundation
import JammerCore

/// One editing operation, as the menu, the command palette, App Intents and the
/// agent API all see it. The guide and `GET /api/v1/operations` are generated
/// from this list, so they can't drift from what the app actually does.
public struct OperationSpec: Sendable, Identifiable {
    public struct Param: Sendable {
        public enum Kind: String, Sendable { case seconds, number, string, boolean, list, numbers }
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
            case .numbers: d["type"] = "array"; d["items"] = ["type": "number"]
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

    /// The operations an assistant with a small tool budget should get first ("core");
    /// the rest are "advanced" (SIBLINGS.md §3).
    public static let core: Set<String> = ["delete", "gain", "fade_in", "fade_out", "normalize", "loudness_preset", "delete_words",
                                           "echo", "transcribe", "get_transcript", "restore", "measure_loudness", "export", "diarize",
                                           "level_speakers"]
    public var tier: String { Self.core.contains(name) ? "core" : "advanced" }

    /// Every parameter including the document id in the path, for endpoints; GET parameters go in the query.
    public var allParams: [Param] {
        guard let call else { return params }
        let id = Param("id", .string, "The document id (GET /api/v1/documents lists them).", required: true).at("path")
        return [id] + (call.method == "GET" ? params.map { $0.location == nil ? $0.at("query") : $0 } : params)
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
        .init("align_tracks", "Line Up Tracks", "Lines up separately recorded tracks (double-enders) by their sound. Use the call recording (Zoom, Riverside, phone), where everyone is heard, as the reference; without one, the track that matches the others best is used. Tracks without a clear match don't move.",
              params: [.init("reference", .string, "Track id to line up with. Default: the best-matching track."),
                       .init("tracks", .list, "Track ids to move. Default: all the others."),
                       .init("window", .seconds, "Seconds from the start to compare. Default 120.", range: 10...600)]),
        .init("spectral_attenuate", "Attenuate Frequencies", "Lowers a frequency band inside the range (the selection without one), per track, rendered into a new file; the original audio is one undo away.",
              params: [.init("low", .number, "Lower edge in Hz.", required: true, range: 0...96_000),
                       .init("high", .number, "Upper edge in Hz.", required: true, range: 0...96_000),
                       .init("db", .number, "Change in dB, -80 to 0. Default -20.", range: -80...0),
                       start, end, .init("tracks", .list, "Track ids. Default: every track.")]),
        .init("correct_drift", "Correct Drift", "Resamples a separately recorded track whose recorder's clock ran fast or slow, so it stays in sync to the end. Without ppm the drift is measured against another track; an uncertain measurement fails with reason drift_uncertain instead of guessing.",
              params: [.init("track", .string, "The track to correct.", required: true),
                       .init("against", .string, "Track to measure against (the call recording is best). Default: the best-matching track."),
                       .init("ppm", .number, "The drift in parts per million (positive: it ran fast). Skips the measurement.", range: -2_000...2_000)]),
        .init("spectral_edit", "Edit Spectrum", "Changes an area of the spectrogram, per track, rendered into a new file (the original audio is one undo away). action attenuate lowers it by db; heal rebuilds it from the sound just before and after (for short sounds such as clicks, coughs, a phone ringing: at most 0.5 s, longer fails with reason too_long; use attenuate). shape box takes start, end, low, high; polygon takes points [t1, f1, t2, f2, …] (seconds, Hz; at least three corners); brush takes points along the stroke plus radius (Hz) and radiusTime (s). Bad shapes fail with reason bad_shape.",
              params: [.init("action", .string, "What to do.", required: true, options: ["attenuate", "heal"]),
                       .init("shape", .string, "The area's kind.", required: true, options: ["box", "polygon", "brush"]),
                       start, end,
                       .init("low", .number, "box: lower edge in Hz.", range: 0...96_000),
                       .init("high", .number, "box: upper edge in Hz.", range: 0...96_000),
                       .init("points", .numbers, "polygon, brush: time (s) and frequency (Hz) pairs, flattened."),
                       .init("radius", .number, "brush: Hz around the stroke. Default 200.", range: 1...20_000),
                       .init("radiusTime", .number, "brush: seconds around the stroke. Default 0.02.", range: 0.001...1),
                       .init("db", .number, "attenuate: change in dB, -80 to 0. Default -20.", range: -80...0),
                       .init("tracks", .list, "Track ids. Default: every track.")]),
        .init("debleed", "Remove Bleed", "Removes the other speakers from each track of a multitrack recording. gate lowers a track outside its own speaker's turns (needs diarize mode by_track; reason no_speakers otherwise); best when people don't talk over each other. cancel subtracts the other tracks' leak: the delay is found by cross-correlation up to about 1 s (a remote guest's voice coming back out of headphones arrives 50–500 ms late), and the leak is learnt where the track's own speaker is silent, so their voice is kept; needs two or more tracks that play together (reason needs_tracks). Each processed track plays from a new file; the original is one undo away. info: tracks, reductionDB.",
              params: [.init("method", .string, "How to remove it.", required: true, options: ["gate", "cancel"]),
                       .init("tracks", .list, "Track ids. Default: every track (gate: those with speakers)."),
                       .init("amount", .number, "gate: dB outside the turns. Default -18.", range: -40...0),
                       .init("maxDelay", .number, "cancel: ms of spread around the found delay (the room or codec). Default 30.", range: 5...100)]),
        .init("set_track", "Change Track", "Changes one track: its gain, mute or name.",
              params: [.init("track", .string, "Track id.", required: true),
                       .init("gainDB", .number, "The track's gain in dB.", range: -96...24),
                       .init("muted", .boolean, "True to mute."),
                       .init("name", .string, "A new name.")]),
        .init("set_group", "Change Group", "Moves the gain of every track in a group (the stems of one separated track) by the same amount, so their balance stays.",
              params: [.init("group", .string, "Group id (GET …/tracks shows it).", required: true),
                       .init("gainDB", .number, "Change in dB, added to each track's gain.", required: true, range: -48...48)]),
        .init("level_speakers", "Level Speakers", "Brings every speaker to the same loudness with one gain each, measured over their own turns (needs diarize first; fails with reason no_speakers otherwise). A track that is one speaker gets track gain; a track with several is split in the pauses where the speaker changes. Run loudness_preset afterwards for the mix. info: speakers, maxChangeDB, limitedByMaxGain.",
              params: [.init("mode", .string, "static: one gain per speaker (default). dynamic: rides each speaker's gain over time (3 s short-term loudness over their own speech, looking ahead so speech starts don't pump; pauses never lifted); bounces the tracks into new files. info then also has spreadBeforeLU and spreadAfterLU.", options: ["static", "dynamic"]),
                       .init("target", .number, "LUFS per speaker. Default -18.", range: -40 ... -10),
                       .init("maxGain", .number, "Largest change in dB, up or down. Default 12.", range: 0...30),
                       .init("speakers", .list, "Speaker ids as strings (\"0\", \"1\"). Default: everyone.")]),
        .init("rename_speaker", "Rename Speaker", "Gives a speaker a name, e.g. after diarize. Use it to pair up speakers found on different tracks.",
              params: [.init("speaker", .string, "The speaker's id as a string (\"0\", \"1\", …) or current name.", required: true),
                       .init("name", .string, "The new name.", required: true)]),
        .init("add_insert", "Add Plugin", "Puts an Audio Unit effect on a track, last in its chain unless position says otherwise; its latency is compensated. Plugins are third-party code running with Jämmer's rights. GET /api/v1/plugins lists what's installed. info has latencyMs; ids has the new insert's id.",
              params: [.init("track", .string, "Track id.", required: true),
                       .init("plugin", .string, "Plugin id from GET /api/v1/plugins (e.g. aufx/lmtr/appl) or its exact name.", required: true),
                       .init("position", .number, "Place in the chain, 0 first. Default: last.", range: 0...64),
                       .init("preset", .string, "A factory preset, by name.")]),
        .init("set_insert", "Change Plugin", "Changes a plugin on a track: bypass, a factory preset, or one parameter by identifier (GET …/tracks/{track}/inserts/{insert} lists them with their ranges). A value outside the range fails with reason out_of_range; nothing is clipped. Send several steps to change several parameters at once.",
              params: [.init("track", .string, "Track id.", required: true),
                       .init("insert", .string, "Insert id (or its name when that's unique on the track).", required: true),
                       .init("bypass", .boolean, "True to bypass, false to switch back on."),
                       .init("preset", .string, "A factory preset, by name."),
                       .init("parameter", .string, "Parameter identifier, e.g. global.0, or its exact name."),
                       .init("value", .number, "The parameter's new value, in its unit.")]),
        .init("remove_insert", "Remove Plugin", "Takes a plugin off a track.",
              params: [.init("track", .string, "Track id.", required: true),
                       .init("insert", .string, "Insert id (or its name when that's unique on the track).", required: true)]),
        .init("loudness_preset", "Loudness Preset", "Brings the range (the whole document without a range or selection) to a delivery target in one step. Without a limiter, the gain stops where the true peak would pass the ceiling; info.limitedByPeak is then 1 and integratedAfter shows what was reached.",
              params: [.init("preset", .string, "The target.", required: true, options: LoudnessPreset.allCases.map(\.rawValue)), start, end]),
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
    /// Computed each time: the formats depend on what the app registered (MP3).
    public static var endpoints: [OperationSpec] { [
        .init("transcribe", "Transcribe", "Transcribes the document on this Mac; words get ids and times. Answers with a job; the transcript lands as one undo step.",
              params: [.init("language", .string, "BCP 47, e.g. sv-SE or en-US. Default: the Mac's language."),
                       .init("engine", .string, "Recogniser. auto: KB-Whisper for Swedish when installed, else Parakeet (25 European languages) when installed, else Apple. A model that isn't installed fails with reason model_missing; the user installs models in Jämmer's Settings.", options: ["auto", "apple", "parakeet", "whisper"]),
                       .init("replace", .boolean, "Transcribe again even where there is a transcript.")],
              call: ("POST", "/api/v1/documents/{id}/transcribe"), startsJob: true),
        .init("get_transcript", "Read Transcript", "The words as they play now, with ids, times and confidence.",
              params: [start, end], edits: false, call: ("GET", "/api/v1/documents/{id}/transcript")),
        .init("get_insert", "Read Plugin", "One plugin on a track: its latency, factory presets and parameters (identifier, name, unit, min, max, value), for set_insert.",
              params: [OperationSpec.Param("trackId", .string, "Track id.", required: true).at("path"),
                       OperationSpec.Param("insert", .string, "Insert id.", required: true).at("path")],
              edits: false, call: ("GET", "/api/v1/documents/{id}/tracks/{trackId}/inserts/{insert}")),
        .init("diarize", "Find Speakers", "Works out who speaks when, as a job; the result is one undo step and labels the transcript's words. mode by_track (the default when several tracks play at once, as in a double-ender) makes each track its speaker, named after the track, counting speech only where the track is clearly above the other tracks' bleed. mode ml (the default otherwise) runs the diarisation model on each track; its speakers are per track.",
              params: [.init("mode", .string, "How to find speakers.", options: ["by_track", "ml"]),
                       .init("tracks", .list, "Track ids. Default: every track with audio."),
                       .init("speakers", .number, "ml: the exact number of speakers, if known.", range: 1...20),
                       .init("minSpeakers", .number, "ml: at least this many.", range: 1...20),
                       .init("maxSpeakers", .number, "ml: at most this many.", range: 1...20)],
              call: ("POST", "/api/v1/documents/{id}/diarize"), startsJob: true),
        .init("get_speakers", "Read Speakers", "The speakers (id, name, seconds) and their turns as they play now (speaker, track, start, end), optionally over start and end.",
              params: [start, end], edits: false, call: ("GET", "/api/v1/documents/{id}/speakers")),
        .init("get_history", "Read History", "The document's history as a tree: every change with its parent, action and time, which one is current, and whether a step lies on another branch (made before an undo). pruned counts old steps dropped to stay under limit.",
              params: [], edits: false, call: ("GET", "/api/v1/documents/{id}/history")),
        .init("goto_history", "Go to Step", "Makes a step from the history current, on any branch; itself one undo step back to where you were.",
              params: [OperationSpec.Param("node", .string, "Step id from get_history.", required: true).at("path")],
              call: ("POST", "/api/v1/documents/{id}/history/{node}")),
        .init("separate", "Separate Stems", "Splits tracks into stems as a job: model music4 gives vocals, drums, bass and other (Spleeter). Each track is replaced by one track per stem, in a group, playing from new files; together they sound exactly like the track did, so nothing changes until you change a stem. Sound above the model's 11 kHz goes to other. One undo step. The model is installed by the user in Settings › Models (reason model_missing otherwise); tracks with plugins are refused (has_inserts).",
              params: [.init("model", .string, "Which separation.", options: ["music4"]),
                       .init("tracks", .list, "Track ids. Default: every track with audio.")],
              call: ("POST", "/api/v1/documents/{id}/separate"), startsJob: true),
        .init("get_chapters", "Read Chapters", "The markers as Podcasting 2.0 chapters (JSON, version 1.2.0), optionally over start and end.",
              params: [start, end], edits: false, call: ("GET", "/api/v1/documents/{id}/chapters")),
        .init("measure_loudness", "Measure Loudness", "Integrated LUFS, loudness range, max momentary and short-term, sample and true peak.",
              params: [start, end], edits: false, call: ("GET", "/api/v1/documents/{id}/analysis")),
        .init("analyze_restoration", "Find Problems", "Looks for mains hum, clipping and clicks without changing anything.",
              params: [start, end, .init("tracks", .list, "Track ids (query: comma-separated).")], edits: false,
              call: ("GET", "/api/v1/documents/{id}/analysis/restoration")),
        .init("restore_preview", "Preview Repair", "The repaired audio of at most 30 s, without changing the document; with Accept: application/json the measurements before and after.",
              params: restoreParams, edits: false, call: ("POST", "/api/v1/documents/{id}/restore/preview")),
        .init("export", "Export Audio", "The rendered audio as bytes (at most 2 GB per response; export a range for more).",
              params: [.init("format", .string, "File format. Default wav.", options: ExportFormat.available.map(\.rawValue)),
                       .init("bitDepth", .number, "wav 16, 24 or 32 (float); aiff, flac and alac 16 or 24. Default 24.", options: nil, range: 16...32),
                       .init("bitRate", .number, "aac (64000–320000, default 192000), mp3 (64000–320000, default 160000) and opus (16000–256000, default 96000), bits per second.", range: 16_000...320_000),
                       start, end, .init("dither", .boolean, "TPDF dither when writing 16 or 24-bit wav."),
                       .init("chapters", .boolean, "mp3: write the markers as ID3 chapters (default true). wav keeps markers as cue points; other formats have no chapters yet.")],
              edits: false, call: ("POST", "/api/v1/documents/{id}/export")),
        .init("restore", "Repair", "Removes hum, repairs clipping, removes clicks or reduces noise. Answers with a job; one undo step brings the original back.",
              params: restoreParams, call: ("POST", "/api/v1/documents/{id}/restore"), startsJob: true),
    ] }

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

    public var numbers: [Double]? {
        guard case .array(let a) = self else { return nil }
        let n = a.compactMap { v -> Double? in if case .number(let d) = v { return d }; return nil }
        return n.count == a.count ? n : nil
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
    /// Ids the current step made; moved into its result.
    public var made: [String: String] = [:]

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
    /// Ids of things the step made, e.g. ["insert": "…"].
    public var ids: [String: String] = [:]
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
                state.made = [:]
                let info = try apply(step, to: &state, measure: measure)
                results.append(StepResult(op: step.op, status: .done, info: info, ids: state.made))
                state.made = [:]
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
            case .numbers:
                guard let n = value.numbers, n.allSatisfy(\.isFinite) else { throw StepFailure("\(step.op): \"\(key)\" must be a list of numbers.") }
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
        case "align_tracks":
            guard let pool = s.pool else { throw StepFailure("align_tracks needs the app.") }
            let ref: UUID
            if let r = p["reference"]?.string {
                guard let id = UUID(uuidString: r), project.tracks.contains(where: { $0.id == id }) else { throw StepFailure("align_tracks: no track with id \(r).", reason: "not_found") }
                ref = id
            } else {
                guard project.tracks.count > 1, let id = project.suggestedReference(pool: pool) else { throw StepFailure("align_tracks needs at least two tracks.") }
                ref = id
            }
            let ids = p["tracks"]?.strings?.compactMap(UUID.init(uuidString:))
            let results = s.project.alignTracks(to: ref, tracks: ids, pool: pool, window: p["window"]?.double ?? 120, minConfidence: 0.3)
            var info: [String: Double] = ["tracks": Double(results.count)]
            for (i, t) in s.project.tracks.enumerated() {
                guard let r = results[t.id] else { continue }
                info["track\(i + 1)OffsetSeconds"] = (project.seconds(r.offset) * 10_000).rounded() / 10_000
                info["track\(i + 1)Confidence"] = r.confidence
                info["track\(i + 1)Moved"] = r.confidence >= 0.3 && r.offset != 0 ? 1 : 0
            }
            if let refIndex = s.project.tracks.firstIndex(where: { $0.id == ref }) { info["referenceTrack"] = Double(refIndex + 1) }
            return info
        case "spectral_attenuate":
            guard let pool = s.pool, let media = s.media else { throw StepFailure("spectral_attenuate needs the app.") }
            let r = try range(); try checkInside(r)
            let lo = p["low"]?.double ?? 0, hi = p["high"]?.double ?? 0
            guard hi > lo else { throw StepFailure("spectral_attenuate: high must be above low.") }
            let ids = p["tracks"]?.strings.map { Set($0.compactMap(UUID.init(uuidString:))) }
            do {
                s.project = try s.project.applyingSpectralAttenuation(range: r, freq: lo...hi, gainDB: p["db"]?.double ?? -20, tracks: ids, pool: pool, media: media)
            } catch let e as EffectError { throw StepFailure("spectral_attenuate: \(e.localizedDescription)") }
        case "correct_drift":
            guard let pool = s.pool, let media = s.media else { throw StepFailure("correct_drift needs the app.") }
            guard let track = UUID(uuidString: p["track"]?.string ?? ""), project.tracks.contains(where: { $0.id == track }) else {
                throw StepFailure("correct_drift: no such track.", reason: "not_found")
            }
            var ppm = p["ppm"]?.double
            var confidence = 1.0
            if ppm == nil {
                let against = p["against"]?.string.flatMap(UUID.init(uuidString:))
                    ?? project.suggestedReference(pool: pool).flatMap { $0 == track ? nil : $0 }
                    ?? project.tracks.first { $0.id != track }?.id
                guard let against, let d = project.drift(of: track, against: against, pool: pool) else {
                    throw StepFailure("correct_drift: the tracks overlap too little to measure drift (at least 90 s).", reason: "too_short")
                }
                confidence = min(d.start.confidence, d.end.confidence)
                guard confidence >= 0.5 else {
                    throw StepFailure(String(format: "correct_drift: the measurement is uncertain (confidence %.2f); pass ppm to correct anyway.", confidence),
                                      reason: "drift_uncertain", details: ["confidence": confidence])
                }
                ppm = d.partsPerMillion
            }
            s.project = try s.project.correctingDrift(of: track, ppm: ppm!, pool: pool, media: media)
            return ["ppm": (ppm! * 10).rounded() / 10, "msPerHour": (ppm! * 3.6 * 10).rounded() / 10, "confidence": (confidence * 1_000).rounded() / 1_000]
        case "spectral_edit":
            guard let pool = s.pool, let media = s.media else { throw StepFailure("spectral_edit needs the app.") }
            func pts() throws -> [SpectralPoint] {
                let n = p["points"]?.numbers ?? []
                guard n.count >= 2, n.count % 2 == 0 else { throw StepFailure("spectral_edit: points must be time and frequency pairs.", reason: "bad_shape") }
                return stride(from: 0, to: n.count, by: 2).map { SpectralPoint(t: n[$0], f: n[$0 + 1]) }
            }
            let shape: SpectralShape
            switch p["shape"]?.string {
            case "box":
                guard let a = p["start"]?.double, let b = p["end"]?.double, let lo = p["low"]?.double, let hi = p["high"]?.double else {
                    throw StepFailure("spectral_edit: a box needs start, end, low and high.", reason: "bad_shape")
                }
                shape = .box(start: a, end: b, low: lo, high: hi)
            case "polygon": shape = .polygon(try pts())
            default: shape = .brush(try pts(), radius: p["radius"]?.double ?? 200, radiusTime: p["radiusTime"]?.double ?? 0.02)
            }
            let ids = p["tracks"]?.strings.map { Set($0.compactMap(UUID.init(uuidString:))) }
            do {
                s.project = try s.project.applyingSpectralEdit(shape, action: p["action"]?.string == "heal" ? .heal : .attenuate,
                                                               gainDB: p["db"]?.double ?? -20, tracks: ids, pool: pool, media: media)
            } catch let e as SpectralEditError {
                throw StepFailure("spectral_edit: \(e.localizedDescription)", reason: e.reason)
            } catch let e as EffectError {
                throw StepFailure("spectral_edit: \(e.localizedDescription)", reason: "nothing_in_range")
            }
        case "debleed":
            guard let pool = s.pool, let media = s.media else { throw StepFailure("debleed needs the app.") }
            let ids = p["tracks"]?.strings.map { $0.compactMap(UUID.init(uuidString:)) }
            do {
                let (q, report) = try s.project.debleeding(method: p["method"]?.string ?? "gate", tracks: ids, amountDB: p["amount"]?.double ?? -18,
                                                           windowMs: p["maxDelay"]?.double ?? 30, pool: pool, media: media)
                s.project = q
                return ["tracks": Double(report.tracks), "reductionDB": report.reductionDB]
            } catch let e as DebleedError {
                throw StepFailure("debleed: \(e.localizedDescription)", reason: e.reason)
            }
        case "set_track":
            guard let id = UUID(uuidString: p["track"]?.string ?? ""), let t = project.tracks.firstIndex(where: { $0.id == id }) else {
                throw StepFailure("set_track: no such track.", reason: "not_found")
            }
            if let g = p["gainDB"]?.double { s.project.tracks[t].gainDB = g }
            if let m = p["muted"], case .bool(let v) = m { s.project.tracks[t].isMuted = v }
            if let n = p["name"]?.string, !n.trimmingCharacters(in: .whitespaces).isEmpty { s.project.tracks[t].name = n }
        case "set_group":
            guard let id = UUID(uuidString: p["group"]?.string ?? ""), project.tracks.contains(where: { $0.group == id }) else {
                throw StepFailure("set_group: no such group.", reason: "not_found")
            }
            for t in s.project.tracks.indices where s.project.tracks[t].group == id {
                s.project.tracks[t].gainDB = ((s.project.tracks[t].gainDB + (p["gainDB"]?.double ?? 0)) * 100).rounded() / 100
            }
        case "level_speakers":
            guard let pool = s.pool else { throw StepFailure("level_speakers needs the app.") }
            let only = p["speakers"]?.strings.map { Set($0.compactMap(Int.init)) }
            if p["mode"]?.string == "dynamic" {
                guard let media = s.media else { throw StepFailure("level_speakers needs the app.") }
                do {
                    let (q, r) = try s.project.levellingSpeakersDynamically(target: p["target"]?.double ?? -18, maxGain: p["maxGain"]?.double ?? 12,
                                                                            only: only, pool: pool, media: media)
                    s.project = q
                    return ["speakers": Double(r.speakers), "maxChangeDB": r.maxChangeDB, "spreadBeforeLU": r.spreadBefore, "spreadAfterLU": r.spreadAfter]
                } catch let e as LevelError {
                    throw StepFailure("level_speakers: \(e.localizedDescription)", reason: e.reason)
                }
            }
            do {
                let (q, report) = try s.project.levellingSpeakers(target: p["target"]?.double ?? -18, maxGain: p["maxGain"]?.double ?? 12,
                                                                  only: only, pool: pool)
                s.project = q
                return ["speakers": Double(report.gains.count), "maxChangeDB": (report.maxChangeDB * 100).rounded() / 100,
                        "limitedByMaxGain": report.limited ? 1 : 0]
            } catch let e as LevelError {
                throw StepFailure("level_speakers: \(e.localizedDescription)", reason: e.reason)
            }
        case "rename_speaker":
            do {
                try s.project.renameSpeaker(p["speaker"]?.string ?? "", to: p["name"]?.string ?? "")
            } catch SpeakerError.unknown(let k) {
                throw StepFailure("rename_speaker: there's no speaker \(k) (GET …/speakers lists them).", reason: "not_found")
            }
        case "add_insert", "set_insert", "remove_insert":
            return try applyInsert(step, to: &s)
        case "loudness_preset":
            let r = try range(wholeIfNone: true); try checkInside(r)
            guard let preset = LoudnessPreset(rawValue: p["preset"]?.string ?? "") else { throw StepFailure("loudness_preset: unknown preset.") }
            let m = measure(s.project, r)
            guard let plan = preset.plan(for: m) else { throw StepFailure("loudness_preset: the range is silent, so there's nothing to match.") }
            try s.project.changeGain(r, by: plan.gainDB)
            func r2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
            return ["gainDB": plan.gainDB, "integratedBefore": r2(m.integrated ?? 0), "integratedAfter": r2(plan.integratedAfter),
                    "truePeakAfter": r2(plan.truePeakAfter), "target": preset.integrated, "limitedByPeak": plan.limitedByPeak ? 1 : 0]
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

extension StepRunner {
    /// add_insert, set_insert, remove_insert. Settings are worked out on a unit of their
    /// own and stored in the project; playback picks them up from there.
    static func applyInsert(_ step: Step, to s: inout EditState) throws -> [String: Double] {
        let p = step.params
        let project = s.project
        guard let id = UUID(uuidString: p["track"]?.string ?? ""), let t = project.tracks.firstIndex(where: { $0.id == id }) else {
            throw StepFailure("\(step.op): no track with id \(p["track"]?.string ?? "").", reason: "not_found")
        }
        func failure(_ e: Error) -> StepFailure {
            if let e = e as? PluginError { return StepFailure("\(step.op): \(e.localizedDescription)", reason: e.reason) }
            return StepFailure("\(step.op): \(e.localizedDescription)", reason: "plugin_failed")
        }
        func latencyMs(_ i: PluginInstance) -> Double { (Double(i.latency) / project.sampleRate * 100_000).rounded() / 100 }
        func insertIndex() throws -> Int {
            let key = p["insert"]?.string ?? ""
            let inserts = project.tracks[t].inserts
            if let u = UUID(uuidString: key), let i = inserts.firstIndex(where: { $0.id == u }) { return i }
            let named = inserts.indices.filter { inserts[$0].name.caseInsensitiveCompare(key) == .orderedSame }
            if named.count == 1 { return named[0] }
            if named.count > 1 { throw StepFailure("\(step.op): \(named.count) plugins on the track are called \(key); use the id.", reason: "ambiguous", details: ["matches": Double(named.count)]) }
            throw StepFailure("\(step.op): the track has no plugin \(key).", reason: "not_found")
        }
        switch step.op {
        case "add_insert":
            let name = p["plugin"]?.string ?? ""
            guard let info = PluginCatalog.find(name) else {
                throw StepFailure("add_insert: no Audio Unit effect \(name) is installed (GET /api/v1/plugins lists them).", reason: "plugin_not_found")
            }
            do {
                let unit = try PluginInstance.makeBlocking(info.id, channels: project.channels, sampleRate: project.sampleRate)
                var insert = Insert(plugin: info.id, name: info.name)
                if let preset = p["preset"]?.string {
                    try unit.loadPreset(preset)
                    insert.state = unit.captureState()
                }
                let at = min(project.tracks[t].inserts.count, p["position"]?.double.map { Int($0) } ?? .max)
                s.project.tracks[t].inserts.insert(insert, at: at)
                s.made["insert"] = insert.id.uuidString
                return ["latencyMs": latencyMs(unit), "position": Double(at)]
            } catch let f as StepFailure { throw f } catch { throw failure(error) }
        case "set_insert":
            let i = try insertIndex()
            var insert = project.tracks[t].inserts[i]
            if let b = p["bypass"], case .bool(let v) = b { insert.bypass = v }
            if p["value"] != nil, p["parameter"] == nil { throw StepFailure("set_insert: value needs parameter.") }
            if p["parameter"] != nil, p["value"] == nil { throw StepFailure("set_insert: parameter needs value.") }
            var info: [String: Double] = [:]
            if p["preset"] != nil || p["parameter"] != nil {
                do {
                    let unit = try PluginInstance.makeBlocking(insert.plugin, channels: project.channels, sampleRate: project.sampleRate, state: insert.state)
                    if let preset = p["preset"]?.string { try unit.loadPreset(preset) }
                    if let name = p["parameter"]?.string, let v = p["value"]?.double { try unit.set(name, to: v) }
                    insert.state = unit.captureState()
                    info["latencyMs"] = latencyMs(unit)
                } catch { throw failure(error) }
            }
            s.project.tracks[t].inserts[i] = insert
            return info
        default:
            let i = try insertIndex()
            s.project.tracks[t].inserts.remove(at: i)
            return [:]
        }
    }
}
