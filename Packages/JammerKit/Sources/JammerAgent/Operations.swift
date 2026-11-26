import Foundation
import JammerCore

/// One editing operation, as the menu, the command palette, App Intents and the
/// agent API all see it. The guide and `GET /api/v1/operations` are generated
/// from this list, so they can't drift from what the app actually does.
public struct OperationSpec: Sendable, Identifiable {
    public struct Param: Sendable {
        /// `pairs`: a list of [a, b] pairs of numbers (automation points: seconds and value).
        public enum Kind: String, Sendable { case seconds, number, string, boolean, list, numbers, pairs }
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
            case .pairs: d["type"] = "array"; d["items"] = ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2] as [String: Any]
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
    /// At most 15: when `duck` came in (2026-11-16), `measure_loudness` went to advanced. A sibling
    /// needs it least: normalize, loudness_preset and export each report the loudness they reached.
    /// `gain` and `echo` stay core: they are the series' own example of one app asking another.
    public static let core: Set<String> = ["delete", "gain", "fade_in", "fade_out", "normalize", "loudness_preset", "delete_words",
                                           "echo", "transcribe", "get_transcript", "restore", "export", "diarize",
                                           "level_speakers", "duck"]
    public var tier: String { Self.core.contains(name) ? "core" : "advanced" }

    /// Every parameter including the document id in the path, for endpoints; GET parameters go in the query.
    public var allParams: [Param] {
        guard let call else { return params }
        let id = Param("id", .string, "The document id (GET /api/v1/documents lists them).", required: true).at("path")
        if !call.path.contains("{id}") { return params }
        return [id] + (call.method == "GET" ? params.map { $0.location == nil ? $0.at("query") : $0 } : params)
    }

    /// `params` as a JSON Schema object (SIBLINGS.md §3); `x-in` marks path and query values.
    public var schema: [String: Any] {
        var props: [String: Any] = [:]
        for p in allParams { props[p.name] = p.schema }
        // Settings that depend on a sort are published per sort on the property that carries the sort
        // (SIBLINGS.md §3): a closed schema each, with ranges and defaults. An extension key, not oneOf,
        // which tool-calling services reject; it is not part of what a model is given as a tool.
        // Accepted on everything and used for nothing: where a model says why it makes the call.
        props[AgentAPI.rationale] = ["type": "string", "description": "Optional: why you are making this call. Accepted and ignored."]
        // The table sits on the schema whose properties depend on the sort (here: this one, the settings
        // are beside `kind`), and `x-byTypeKey` names the property that chooses.
        if params.contains(where: { $0.name == "kind" }), params.contains(where: { $0.name == "humFrequency" }) {
            return ["type": "object", "properties": props, "required": allParams.filter(\.required).map(\.name), "additionalProperties": false,
                    "x-byTypeKey": "kind", "x-byType": Operations.restoreByType]
        }
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

    /// Drawing freeform areas in the spectrogram (lasso, brush; `spectral_edit` shapes polygon
    /// and brush) can be left out of a build (docs/RELEASING.md): the app sets this at launch.
    /// The code stays; only the box is offered then.
    nonisolated(unsafe) public static var spectralFreeform = true

    /// The steps this build offers.
    /// Sidechain keys (`set_insert` `key`). On in every build since 2026-11-17 (docs/RELEASING.md, item 7);
    /// a build that has it switched off doesn't offer the parameter and refuses it.
    nonisolated(unsafe) public static var sidechain = true
    /// For a test that tries the keyed path without switching it on for every other test in the process.
    @TaskLocal public static var sidechainForThisTask: Bool?
    static var sidechainOn: Bool { sidechainForThisTask ?? sidechain }
    static let keyParam = OperationSpec.Param("key", .string, "A sidechain key: the id of the track or bus the plugin listens to (its signal after the fader, in step with the audio), or \"none\" to take the key away. Only for a plugin with a sidechain input (reason no_key_input otherwise); a key that would be fed by what it controls is refused (routing_loop).")

    /// Automation (`set_automation`, `clear_automation`). On in every build since 2026-11-18: lanes are shown and
    /// drawn in the window, and Anders tried drawing them ("funkar"). A build with it switched off (a test, through
    /// `automationForThisTask`) doesn't know the steps; a project that has lanes is still played as it was saved.
    nonisolated(unsafe) public static var automation = true
    /// Dialogue-gated loudness is in debug builds only until its numbers have been set beside a reference
    /// meter's on the test files (docs/MASTERING.md): a number isn't shown before it has a known-good
    /// reference. A build with it off answers not_available.
    nonisolated(unsafe) public static var dialogueLoudness = false
    @TaskLocal public static var automationForThisTask: Bool?
    public static var automationOn: Bool { automationForThisTask ?? automation }
    static let automationSteps: [OperationSpec] = [
        .init("set_automation", "Write Automation", "Writes automation: points on the timeline that a strip's level, pan or mute follows (before the first point the value is the first point's, after the last the last's). `gain`: a straight line in dB from point to point, added to the fader, which stays where it is (0 dB is no change). `pan`: a straight line from point to point, −1 left to 1 right, in the place of the fixed pan while the lane is there (stereo documents). `mute`: 1 muted, 0 heard, each held until the next point; the sound closes and opens over 5 ms beginning at the point, so it never clicks, and sends before the fader are silenced too, as by the mute button. `send` with `to` (a bus id): the level of the strip's send to that bus, in dB, added to the send's own level. `strip` may also be a VCA group's id: its gain and mute lanes are added to those of every track and bus in the group, as its fader is. The master has a gain lane only. `points` replace the whole lane; with `start` and `end` they replace only the points inside that range and nothing outside it is touched. A point lands on its own sample, whatever plugins the strip has. Edits that close up or open the whole timeline (delete, paste, removed pauses) move the points with the sound; lining up or stretching one track doesn't, and the answer then carries a warning. Refused with the name of the field: a point after the document's end or outside `start`…`end`, a value outside what the lane takes (−96 to 24 dB, −1 to 1, 0 or 1), two points at one time. info has `points`, how many the lane now has.",
              params: [.init("strip", .string, "The id of the track, bus or VCA group, or \"master\".", required: true),
                       .init("param", .string, "What the lane moves. Default gain. plugin: one parameter of a plugin on the strip (`insert` and `parameter` say which), in the parameter's own unit, a straight line between points, set once every 512 frames; for now only where the plugin is an Audio Unit (another kind answers not_available).", options: ["gain", "pan", "mute", "send", "plugin", "azimuth", "elevation", "yaw", "pitch", "roll"]),
                       .init("to", .string, "For param send: the id of the bus the send goes to. The send must be there (set_send)."),
                       .init("insert", .string, "For param plugin: the plugin on the strip, by its id or its name."),
                       .init("parameter", .string, "For param plugin: the parameter, by its identifier or its name (GET …/tracks/{id}/inserts/{insert} lists them with their ranges)."),
                       .init("points", .pairs, "The points: [[seconds, value], …]; the value is dB for gain (−96 to 24), −1 to 1 for pan, 1 or 0 for mute, and for a plugin's parameter a value in that parameter's own range; for azimuth degrees −360 to 360 (positive to the left, past ±180 on round behind) and for elevation 0 to 90: a track's place in a document wider than stereo, moving in a straight line between points, worked out every 512 frames and glided in between; for yaw (−360 to 360), pitch (−90 to 90) and roll (−180 to 180) degrees: a track's sound field turned (set_track field), worked out every 512 frames and glided in between along a curve through the next two. An empty list with `start` and `end` takes the points in that range away.", required: true),
                       .init("start", .seconds, "Start of the range to replace, in seconds. With `end`."),
                       .init("end", .seconds, "End of the range to replace, in seconds. With `start`."),
                       .init("enabled", .boolean, "False keeps the lane but stops it being heard; true brings it back.")]),
        .init("clear_automation", "Clear Automation", "Takes the points of one lane away: all of them, or with `start` and `end` those inside that range. One strip and one lane at a time; nothing clears a whole project. info has `removed`.",
              params: [.init("strip", .string, "The id of the track, bus or VCA group, or \"master\".", required: true),
                       .init("param", .string, "Which lane.", required: true, options: ["gain", "pan", "mute", "send", "plugin", "azimuth", "elevation", "yaw", "pitch", "roll"]),
                       .init("to", .string, "For param send: the id of the bus the send goes to."),
                       .init("insert", .string, "For param plugin: the plugin on the strip, by its id or its name."),
                       .init("parameter", .string, "For param plugin: the parameter, by its identifier or its name."),
                       .init("start", .seconds, "Start of the range to clear, in seconds. With `end`."),
                       .init("end", .seconds, "End of the range to clear, in seconds. With `start`.")]),
    ]

    public static var all: [OperationSpec] {
        withKeys(all(freeform: spectralFreeform, clap: InsertUnits.external != nil)) + (automationOn ? automationSteps : [])
    }
    /// A list of steps with `key` on `set_insert` where the build has sidechain keys: what the guide for a
    /// set of features describes, and what `all` offers.
    public static func withKeys(_ list: [OperationSpec]) -> [OperationSpec] {
        guard sidechainOn else { return list }
        return list.map { op in
            guard op.name == "set_insert" else { return op }
            var o = op
            o.params.append(keyParam)
            return o
        }
    }
    public static func all(freeform: Bool, clap: Bool = true) -> [OperationSpec] {
        let list = freeform ? everything : boxOnly
        guard !clap else { return list }
        // Without CLAP the plugins are Audio Units, which run inside Jämmer.
        return list.map { op in
            guard op.name == "add_insert" else { return op }
            var o = op
            o.description = "Puts an Audio Unit effect on a track, last in its chain unless position says otherwise; its latency is compensated. Plugins are third-party code running with Jämmer's rights. GET /api/v1/plugins lists what's installed. info has latencyMs; ids has the new insert's id."
            return o
        }
    }
    private static let boxOnly: [OperationSpec] = everything.map { op in
        guard op.name == "spectral_edit" else { return op }
        var o = op
        o.description = "Changes a box in the spectrogram, per track, rendered into a new file (the original audio is one undo away). action attenuate lowers it by db; heal rebuilds it from the sound just before and after (for short sounds such as clicks, coughs, a phone ringing: at most 0.5 s, longer fails with reason too_long; use attenuate). shape box takes start, end, low, high. Bad shapes fail with reason bad_shape."
        o.params = op.params.filter { !["points", "radius", "radiusTime"].contains($0.name) }.map { p in
            var p = p
            if p.name == "shape" { p.options = ["box"] }
            return p
        }
        return o
    }
    private static let everything: [OperationSpec] = [
        .init("select", "Select Range", "Selects a range. Later steps without `start`/`end` act on it.",
              params: [.init("start", .seconds, "Start in seconds.", required: true), .init("end", .seconds, "End in seconds.", required: true)], edits: false),
        .init("select_all", "Select All", "Selects the whole document.", edits: false),
        .init("deselect", "Deselect", "Clears the selection.", edits: false),
        .init("select_track", "Select Track", "Makes a track the selected one (the one the Track menu acts on) and brings it into view in the window.",
              params: [.init("track", .string, "Track id.", required: true)], edits: false),
        .init("set_playhead", "Move Playhead", "Moves the playhead (where paste and markers go by default).",
              params: [.init("at", .seconds, "Position in seconds.", required: true)], edits: false),
        .init("set_video_reference", "Set Film", "Gives the document a film to look at while the sound is worked on: a file on this Mac, shown in the Picture window and following the playhead. The film is only pointed at: it is not read into the project, not changed, and its own sound is not played. info has `at`.",
              params: [.init("path", .string, "The film's file (a QuickTime or MPEG-4 film: .mov, .mp4, .m4v), as a full path.", required: true),
                       .init("at", .seconds, "The place on the timeline where the film's first picture is. Default 0.")]),
        .init("remove_video_reference", "Remove Film", "Takes the film away from the document. The file is left as it is."),
        .init("go_to_timecode", "Go to Timecode", "Moves the playhead to a timecode of the picture: to the audio frame where that picture frame begins. The document must have a timecode (set_timecode, or an imported film timeline). info has `at`, the place in seconds.",
              params: [.init("timecode", .string, "The timecode, as hh:mm:ss:ff (hh:mm:ss;ff for drop-frame), at the document's frame rate.", required: true)], edits: false),
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
        .init("normalize", "Normalize", "Sets the level of the range (the whole document without a range or selection) to a target. The change is a gain on the clips in the range (it shows as gainDB on each clip), not on the track. info has before and gainDB.",
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
        .init("duck", "Duck Under Speech", "Lowers tracks (music, atmosphere) while there is speech on other tracks and lets them up in the pauses. Where the speech is comes from the speakers' turns when the controlling tracks have them (diarize first for the surest result), otherwise from their level (threshold). Each ducked track plays from a new file; outside the ducked stretches and their ramps the sound is untouched, and the original is one undo away. It isn't live: if the speech is moved or cut afterwards, run it again. Run again on a track that still plays its ducked file, it replaces the earlier ducking (it starts from the sound before it); stack: true ducks on top instead. A track that was edited after it was ducked is ducked as it is. info: tracks, regions (stretches held down), duckedSeconds, replaced (tracks whose earlier ducking was replaced), trigger (turns or level).",
              params: [.init("tracks", .list, "Track ids to lower.", required: true),
                       .init("under", .list, "Track ids whose speech decides. Default: every other unmuted track. Must not name a track that is in tracks."),
                       .init("amount", .number, "dB while there is speech. Default -12.", range: -40...0),
                       .init("threshold", .number, "LUFS (momentary) over which the deciding tracks count as speech, when they have no speaker turns. Default -40.", range: -70 ... -10),
                       .init("attack", .number, "ms to go down. Default 150.", range: 5...2_000),
                       .init("release", .number, "ms to come up. Default 600.", range: 50...5_000),
                       .init("hold", .number, "ms to stay down after the speech stops, so short pauses don't pump. Default 400.", range: 0...5_000),
                       .init("lookahead", .number, "ms before the speech that it starts going down. Default: the attack, so it is down when the first word comes.", range: 0...2_000),
                       .init("stack", .boolean, "True to duck on top of an earlier ducking instead of replacing it."),
                       start, end]),
        .init("remove_track", "Delete Track", "Removes a track with its clips and automation; a plugin elsewhere keyed by it loses the key. Its files are not touched. A document keeps at least one track; a locked track can't be removed. One undo step.",
              params: [.init("track", .string, "Track id.", required: true)]),
        .init("duplicate_track", "Duplicate Track", "Puts a copy of a track right under it: the same clips, level, pan, plugins, sends and automation, with ids of its own; not locked and not frozen. Returns the copy's id as ids.track. One undo step.",
              params: [.init("track", .string, "Track id.", required: true), .init("name", .string, "The copy's name. Default: the track's name and \"copy\".")]),
        .init("move_track", "Move Track", "Moves a track in the order of the lanes and the mixer: to a place (index, 0 the top) or up or down by some places (by, e.g. -1 for up). One undo step.",
              params: [.init("track", .string, "Track id.", required: true), .init("index", .number, "Its new place, 0 the top."), .init("by", .number, "Places to move: negative up, positive down.")]),
        .init("set_track", "Change Track", "Changes one track: its gain, mute, name, pan, its place in a surround layout, or the bus it goes to.",
              params: [.init("track", .string, "Track id.", required: true),
                       .init("gainDB", .number, "The track's gain in dB: the new value, not a change to the old one.", range: -96...24),
                       .init("muted", .boolean, "True to mute."),
                       .init("locked", .boolean, "True to lock the track: no step may then change its clips (or remove it) until it is unlocked. Level, pan, mute and the mixer stay free."),
                       .init("name", .string, "A new name."),
                       .init("pan", .number, "−1 (left) to 1 (right), 0 the center. Stereo documents only.", range: -1...1),
                       .init("azimuth", .number, "Documents wider than stereo: where the track's mono or stereo sound comes from, in degrees, positive to the left (0 the center, 90 the left side, ±180 behind; ITU-R BS.2051's convention). Placing a track this way uses the surround panner (pairwise vector base amplitude panning at constant power). A source of more than two channels on the track stays on its own loudspeakers.", range: -180...180),
                       .init("elevation", .number, "Documents with height loudspeakers (7.1.4): degrees up, 0 to 90; the height layer is at 30, and above it the sound stays there.", range: 0...90),
                       .init("width", .number, "For a stereo source: the angle between its two sides, centered on azimuth. Default 60 (at azimuth 0, exactly L and R).", range: 0...180),
                       .init("placed", .boolean, "false takes the track out of the surround panner again: each source back on its own loudspeakers (a voice in C, a pair in L and R)."),
                       .init("field", .number, "The track's files are a sound field (AmbiX) of this order, 1–3 (a file of 4, 9 or 16 channels); 0: they are not. Into loudspeakers a field is decoded (AllRAD), into mono or stereo by way of 5.1. Making a document Ambisonics marks its files of that size already.", range: 0...3),
                       .init("yaw", .number, "A track that plays a sound field: the field turned round the listener, degrees, positive to the left.", range: -360...360),
                       .init("pitch", .number, "The field's front lifted (positive) or lowered, degrees.", range: -90...90),
                       .init("roll", .number, "The field's left side lifted (positive) or lowered, degrees.", range: -180...180),
                       .init("turned", .boolean, "false takes the field's turn away (yaw, pitch and roll back to 0)."),
                       .init("output", .string, "The id of the bus the track goes to, or \"master\" for the output.")]),
        .init("add_bus", "Add Bus", "Adds a bus to the mixer: tracks routed to it (set_track output) are summed, given the bus's gain and pan, and passed on to the output or to another bus. The answer's `bus` is its number in `GET …/mixer`, where its id is.",
              params: [.init("name", .string, "What the bus is called.", required: true),
                       .init("output", .string, "The id of the bus this one feeds. Default: the output.")]),
        .init("set_bus", "Change Bus", "Changes one bus: its name, gain, pan, mute, or where it goes. A route that would send a bus back into itself is refused (reason routing_loop).",
              params: [.init("bus", .string, "Bus id (GET …/mixer shows it).", required: true),
                       .init("name", .string, "A new name."),
                       .init("gainDB", .number, "The bus's gain in dB: the new value.", range: -96...24),
                       .init("pan", .number, "−1 (left) to 1 (right), 0 the center. Stereo documents only.", range: -1...1),
                       .init("muted", .boolean, "True to mute everything that goes through the bus."),
                       .init("output", .string, "The id of the bus this one feeds, or \"master\" for the output."),
                       .init("azimuth", .number, "In a loudspeaker layout wider than stereo: the bus's whole image turned round the listener, in degrees, positive to the left (each channel re-panned from its loudspeaker's direction plus the turn; the LFE as it is). Not in mono, stereo or Ambisonics.", range: -180...180),
                       .init("turned", .boolean, "false takes the turn away.")]),
        .init("set_send", "Set Send", "Sends a copy of a track or a bus to a bus, at a level of its own: for a shared reverb, a parallel compressor, a headphone mix. One send per pair; giving it again changes it, and `remove` takes it away. After the fader by default (the copy follows the strip's level and pan); with `pre` it is taken before them. A send that would lead a bus back into itself is refused (reason routing_loop).",
              params: [.init("from", .string, "The id of the track or bus the copy is taken from.", required: true),
                       .init("to", .string, "The id of the bus it goes to.", required: true),
                       .init("gainDB", .number, "The send's level in dB. Default 0 for a new send.", range: -96...24),
                       .init("pre", .boolean, "True: before the fader and pan. Default false."),
                       .init("remove", .boolean, "True takes the send away.")]),
        .init("add_vca", "Add VCA", "Adds a VCA group: no audio goes through it; its level is added to the fader of every track and bus that belongs to it and its mute mutes them, so they move together while each keeps its own level, plugins and route. The answer's `ids.vca` is the new group's id.",
              params: [.init("name", .string, "What the group is called.", required: true),
                       .init("members", .list, "The ids of the tracks and buses to put in it. A strip is in one VCA at most; it leaves the one it was in.")]),
        .init("set_vca", "Change VCA", "Changes a VCA group: its name, its level, its mute, or which strips belong to it. Sends taken before the fader don't follow a VCA, as they don't follow the fader. A strip that leaves a group loses what the group added to its level.",
              params: [.init("vca", .string, "VCA id (GET …/mixer shows it).", required: true),
                       .init("name", .string, "A new name."),
                       .init("gainDB", .number, "The group's level in dB, added to each member's own: the new value.", range: -96...24),
                       .init("muted", .boolean, "True mutes every member."),
                       .init("members", .list, "The ids of the tracks and buses that belong to it, in place of the ones that did."),
                       .init("add", .list, "Ids of tracks and buses to put in the group."),
                       .init("remove", .list, "Ids of tracks and buses to take out of the group.")]),
        .init("remove_vca", "Remove VCA", "Takes a VCA group away and leaves the sound as it was: the group's level goes into each member's own, and members of a muted group stay muted.",
              params: [.init("vca", .string, "VCA id.", required: true)]),
        .init("set_master", "Change Master", "Changes the master, which everything goes through last: its gain, and a true-peak limiter after everything else (every track, bus and plugin). With the limiter on, an export is measured as written and rendered again further under the ceiling until the file holds it; playback has one pass and aims 0.1 dB under. Plugins go on the master with `add_insert` and `track: \"master\"`.",
              params: [.init("gainDB", .number, "The master's gain in dB.", range: -96...24),
                       .init("limiter", .boolean, "True puts the limiter on (with the values given, else the ones it had, else the defaults); false takes it off."),
                       .init("ceiling", .number, "The true peak to stay at or under, in dBTP, −20 to 0. Default −1.", range: -20...0),
                       .init("release", .number, "How fast the gain comes back, in milliseconds, 1–2000. Default 100.", range: 1...2_000),
                       .init("lookahead", .number, "How far ahead a peak is seen, in milliseconds, 0.5–20. Default 5.", range: 0.5...20)]),
        .init("remove_bus", "Remove Bus", "Takes a bus away. Refused while tracks or buses are routed to it (reason in_use), unless `reroute` says where they go instead.",
              params: [.init("bus", .string, "Bus id.", required: true),
                       .init("reroute", .string, "Where what was routed to the bus goes: a bus id, or \"master\".")]),
        .init("set_group", "Change Group", "Moves the gain of every track in a group (the stems of one separated track) by the same amount, so their balance stays.",
              params: [.init("group", .string, "Group id (GET …/tracks shows it).", required: true),
                       .init("gainDB", .number, "Change in dB, added to each track's gain.", required: true, range: -48...48)]),
        .init("level_speakers", "Level Speakers", "Brings every speaker to the same loudness with one gain each, measured over their own turns (needs diarize first; fails with reason no_speakers otherwise). A track that is one speaker gets track gain; a track with several is split in the pauses where the speaker changes. Run loudness_preset afterwards for the mix. info: speakers, maxChangeDB, limitedByMaxGain.",
              params: [.init("mode", .string, "static: one gain per speaker (default). dynamic: rides each speaker's gain over time (3 s short-term loudness over their own speech, looking ahead so speech starts don't pump; pauses never lifted); bounces the tracks into new files. info then also has spreadBeforeLU and spreadAfterLU.", options: ["static", "dynamic"]),
                       .init("target", .number, "LUFS per speaker. Default -18.", range: -40 ... -10),
                       .init("maxGain", .number, "Largest change in dB, up or down. Default 12.", range: 0...30),
                       .init("speakers", .list, "Speaker ids as strings (\"0\", \"1\"). Default: everyone.")]),
        .init("split_speakers", "Split Speakers onto Tracks", "One track per speaker found on a track (diarize first), named after them. Together they play exactly what the track did (overlaps go to the longer turn, pauses to the nearer speaker); the original is muted and kept unless keepOriginal is false.",
              params: [.init("track", .string, "The track's id or name.", required: true),
                       .init("keepOriginal", .boolean, "Keep the original track, muted. Default true.")]),
        .init("rename_speaker", "Rename Speaker", "Gives a speaker a name, e.g. after diarize. Use it to pair up speakers found on different tracks.",
              params: [.init("speaker", .string, "The speaker's id as a string (\"0\", \"1\", …) or current name.", required: true),
                       .init("name", .string, "The new name.", required: true)]),
        .init("add_insert", "Add Plugin", "Puts an effect (an Audio Unit or a CLAP plugin) on a track, last in its chain unless position says otherwise; its latency is compensated. Plugins are third-party code; a CLAP plugin runs in a helper process of its own. GET /api/v1/plugins lists what's installed. info has latencyMs; ids has the new insert's id.",
              params: [.init("track", .string, "The id of the track, or of the bus, the plugin goes on.", required: true),
                       .init("plugin", .string, "Plugin id from GET /api/v1/plugins (e.g. aufx/lmtr/appl) or its exact name.", required: true),
                       .init("position", .number, "Place in the chain, 0 first. Default: last.", range: 0...64),
                       .init("preset", .string, "A factory preset, by name.")]),
        .init("set_insert", "Change Plugin", "Changes a plugin on a track: bypass, a factory preset, or one parameter by identifier (GET …/tracks/{track}/inserts/{insert} lists them with their ranges). A value outside the range fails with reason out_of_range; nothing is clipped. Send several steps to change several parameters at once.",
              params: [.init("track", .string, "The id of the track or bus the plugin is on.", required: true),
                       .init("insert", .string, "Insert id (or its name when that's unique on the track).", required: true),
                       .init("bypass", .boolean, "True to bypass, false to switch back on."),
                       .init("preset", .string, "A factory preset, by name."),
                       .init("parameter", .string, "Parameter identifier, e.g. global.0, or its exact name."),
                       .init("value", .number, "The parameter's new value, in its unit.")]),
        .init("remove_insert", "Remove Plugin", "Takes a plugin off a track or a bus.",
              params: [.init("track", .string, "The id of the track or bus the plugin is on.", required: true),
                       .init("insert", .string, "Insert id (or its name when that's unique on the track).", required: true)]),
        .init("loudness_preset", "Loudness Preset", "Brings the range (the whole document without a range or selection) to a delivery target in one step. Without `limit`, it is one gain that stops where the true peak would pass the ceiling; info.limitedByPeak is then 1 and integratedAfter shows what was reached. With `limit`, the limiter holds the peaks at the ceiling so the target is reached, and the answer says what that took.",
              params: [.init("preset", .string, "The target.", required: true, options: LoudnessPreset.allCases.map(\.rawValue)), start, end,
                       .init("limit", .boolean, "Use the limiter to reach the target when the peaks would stop the gain short of it. Default false: one gain, never over the ceiling. With it, the answer says what the limiter took (`reductionMaxDB`, `limitedSeconds`, `rangeBeforeLU`, `rangeAfterLU`).")]),
        .init("acx_match", "Match ACX Requirements", "Brings the range (the whole document without a range or selection) within ACX's loudness and peaks, as one undo step: the RMS into −23…−18 dB (to −20 when it is outside), the sample and true peak at or under −3 dB, by the limiter at −3.5 dBTP where a gain alone can't. A file already within both is left as it is (info.unchanged 1). The noise floor is measured and said, never changed: info.noiseFloorAfter is the floor after the gain, and info.noiseFloorTooHigh 1 means it is over ACX's −60 dB, for which Reduce Noise (restore, kind denoise) is a choice of its own. Only ACX approves a file; GET …/analysis/acx checks one.",
              params: [start, end]),
        .init("add_marker", "Add Marker", "Adds a marker, or a region when `duration` is given.",
              params: [.init("at", .seconds, "Position in seconds. Defaults to the selection start, else the playhead."),
                       .init("name", .string, "Marker name.", required: true),
                       .init("duration", .seconds, "Region length in seconds.")]),
        .init("set_layout", "Set Layout", "Sets the document's loudspeaker layout. Nothing is converted: every source keeps its own channels and goes into the new layout by its loudspeakers (a voice to the center, a stereo pair to L and R; a wider source folded down by ITU-R BS.775 and the steps docs/IMMERSIVE.md names). A layout wider than stereo has no stereo pan yet: pan values and pan lanes are not used in it, and pan lanes are not saved while the document is wider than stereo. Exports are in the layout. `order` says how a 7.1 or 7.1.4 file that names no loudspeakers (no channel mask, no ADM chna) is heard; a file that names them is always heard by them. info has `channels`, `fields` and `unmaskedFiles` (how many files the order is a choice for).",
              params: [.init("layout", .string, "The layout. Leave it out to change only the order.", options: ChannelLayout.allCases.map(\.rawValue)),
                       .init("order", .string, "How a 7.1 or 7.1.4 file without a channel mask or ADM is heard: bs2051 (ITU-R BS.2051, the sides before the rears: L R C LFE Lss Rss Lrs Rrs; what a file opened now gets) or wav (the WAV mask's, the rears first: L R C LFE Lrs Rrs Lss Rss). Only the hearing changes, not the file.",
                             options: ChannelOrder.allCases.map(\.rawValue))]),
        .init("set_timecode", "Set Timecode", "Gives the document the picture's timecode (SMPTE): the frame rate, and the timecode at the start of the timeline. The document then says where the playhead is in timecode (`timecode` in GET …/documents/{id}), and nothing about the sound changes. rate none takes it away. info has `startFrames`.",
              params: [.init("rate", .string, "The picture's frame rate. The two ending in df count drop-frame (the clock keeps real time; written with a semicolon before the frames).", required: true,
                             options: Timecode.Rate.allCases.map(\.rawValue) + ["none"]),
                       .init("start", .string, "The timecode of the timeline's first frame, as hh:mm:ss:ff (hh:mm:ss;ff for drop-frame). Default 00:00:00:00. A film's sound often starts at 01:00:00:00.")]),
        .init("remove_marker", "Remove Marker", "Removes the markers with this name, or the one marker with this id.",
              params: [.init("name", .string, "Marker name."), .init("marker", .string, "Marker id (from the document's markers).")]),
        .init("split", "Split", "Splits the clips under a point in two, on every track or only on the tracks given. Nothing moves and nothing is heard differently; the halves can then be trimmed, faded or moved on their own.",
              params: [.init("at", .seconds, "Where to split, in seconds. Defaults to the playhead."), .init("tracks", .list, "Track ids. Default: every track.")]),
        .init("set_marker", "Change Marker", "Moves, renames or resizes one marker, by its id (the document's markers list them). What isn't given stays.",
              params: [.init("marker", .string, "Marker id.", required: true), .init("at", .seconds, "New position in seconds."),
                       .init("name", .string, "New name."), .init("duration", .seconds, "Region length in seconds; 0 for a point.")]),
        .init("move_clip", "Move Clip", "Moves clips on the timeline, sound and all (their words and fades go with them): `clip` to `at`, or `clip` or `clips` by `by` seconds. Refused, with nothing moved, when one would start before 0 or lie over a clip on its track that isn't moved (reason overlaps, before_start). One undo step.",
              params: [.init("clip", .string, "Clip id."), .init("clips", .list, "Clip ids, moved together by `by`."),
                       .init("at", .seconds, "The new start of `clip`."), .init("by", .seconds, "How far to move, in seconds; negative is earlier.")]),
        .init("set_take", "Choose Take", "Plays another take of a stretch recorded more than once (a track's `takes` list them: each group's id, its takes with their ids and numbers, and which is chosen). The stretch is laid again from what lay under it before it was recorded, with that take over it; if the takes were moved since, they go with the chosen take's clip. Takes are recorded and deleted only in the window. One undo step.",
              params: [.init("track", .string, "Track id.", required: true), .init("group", .string, "The takes' group id (the track's takes list).", required: true),
                       .init("take", .string, "The take to play.", required: true)]),
        .init("set_clip", "Change Clip", "Changes one clip by its id (the tracks' clips list them): trims its start or end on the timeline (the sound stays where it is; a clip can't reach over the next one or past its file), sets its fades and their shape, or its gain. What isn't given stays.",
              params: [.init("clip", .string, "Clip id.", required: true), .init("start", .seconds, "New start of the clip on the timeline."),
                       .init("end", .seconds, "New end of the clip on the timeline."), .init("fadeIn", .seconds, "Fade-in length in seconds; 0 removes it."),
                       .init("fadeOut", .seconds, "Fade-out length in seconds; 0 removes it."),
                       .init("shape", .string, "Fade curve.", options: ["equal_power", "linear"]), .init("gainDB", .number, "The clip's gain in dB (the new value).", range: -96...24)]),
        .init("set_tempo", "Set Tempo", "Sets the tempo, and the time signature when given, from `at` on. Tempo changes move with the audio in ripple edits.",
              params: [.init("bpm", .number, "Quarter notes per minute, 10–999.", required: true),
                       .init("at", .seconds, "Where the tempo starts. Defaults to 0, the start of the document."),
                       .init("beats", .number, "Beats per bar (1–64). Give it with `unit`; without both, the time signature in effect at `at` is kept."),
                       .init("unit", .number, "Note value of a beat: 1, 2, 4, 8, 16 or 32 (4 is a quarter note).")]),
        .init("detect_tempo", "Detect Tempo", "Finds the tempo of music and sets the document's tempo map from it, so the ruler's beats fall on the music's beats (one tempo for the whole document; changes of tempo aren't followed). Changes no audio. Only music with a steady beat has a tempo: for speech, noise, silence, or music whose tempo changes it fails with reason no_steady_tempo and nothing is changed. A fast tempo can come back at half speed (174 as 87) or a slow one doubled: GET …/analysis/rhythm lists the alternatives; give multiply 2 or 0.5, or the bpm you know. Where bars begin is not detected: bar numbers on the ruler count from the first beat and say nothing about the music's bars. info: bpm, firstBeat (seconds on the timeline of the first beat the grid is set from), pulse (how strongly the sound repeats at the beat, 0 to 1), beats (how many were found).",
              params: [.init("tracks", .list, "Only these tracks' sound. Default: the mix."),
                       start, end,
                       .init("multiply", .number, "0.5 or 2: the tempo found, halved or doubled.", options: nil, range: 0.5...2),
                       .init("bpm", .number, "The tempo, when you know it (10–999): it has to fit the beat found (or half or double it); only where the beats fall is then taken from the sound.", range: 10...999)]),
        .init("delete_words", "Delete Words", "Removes words from the audio by their transcript, closing the gaps (ripple). Give word ids (best: they stay valid across edits, undo and saving) or the text to find. Text must match in exactly one place, unless you pass `occurrence` or `all`. Words follow each other without gaps, so a pause sits inside a neighboring word (usually the one after it) and goes with that word. info has words and removedSeconds.",
              params: [.init("words", .list, "Word ids from GET /api/v1/documents/{id}/transcript."),
                       .init("text", .string, "A word or phrase as it reads in the transcript; case and punctuation don't count."),
                       .init("occurrence", .number, "With `text`: which match, counting from 1."),
                       .init("all", .boolean, "With `text`: every match."),
                       .init("bridge", .seconds, "Also remove pauses up to this long between the deleted words. Default 0.")]),
        .init("correct_word", "Correct Word", "Changes how a word is spelled in the transcript. The audio doesn't change.",
              params: [.init("word", .string, "The word's id.", required: true),
                       .init("text", .string, "The corrected text.", required: true)]),
        .init("limit", "Limit", "A true-peak limiter on the range (the whole document without a range or selection): the peaks of the chosen tracks together are held at or under the ceiling, with one gain for all of them so their balance stays. Bounced into a new file per track, sample for sample where the old audio was; where nothing needed limiting the audio is the same bit for bit, the original files are untouched and one undo brings them back. Refused when the peak is already under the ceiling. The answer says the ceiling used, the true peak before and after, the largest reduction and for how long it limited.",
              params: [.init("ceiling", .number, "The true peak to stay at or under, in dBTP, −20 to 0. Default −1.", range: -20...0),
                       .init("release", .number, "How fast the gain comes back, in milliseconds, 1–2000. Default 100.", range: 1...2_000),
                       .init("lookahead", .number, "How far ahead a peak is seen, in milliseconds, 0.5–20. Default 5.", range: 0.5...20),
                       start, end,
                       .init("tracks", .list, "Track ids to limit together. Default: every track.")]),
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
    /// Computed: the kinds depend on what the app registered (reverb reduction can be left out of a build).
    /// The settings that belong to one repair alone (the parser refuses them with any other kind). A
    /// repair that has none is there with an empty, closed schema. What every repair takes (`amount`,
    /// the range, the tracks) is in the ordinary schema.
    static var restoreByType: [String: Any] {
        var out: [String: Any] = [:]
        for kind in Restoration.availableKinds {
            var props: [String: Any] = [:]
            if kind == .dehum { props["humFrequency"] = ["type": "number", "minimum": 20, "maximum": 400, "description": "Without it 50 or 60 Hz is found."] as [String: Any] }
            if kind == .declick { props["sensitivity"] = ["type": "number", "minimum": 0.1, "maximum": 10, "default": 1] as [String: Any] }
            out[kind.rawValue] = ["type": "object", "properties": props, "additionalProperties": false] as [String: Any]
        }
        return out
    }
    static var restoreParams: [OperationSpec.Param] { [
        .init("kind", .string, "The repair.", required: true, options: Restoration.availableKinds.map(\.rawValue)),
        .init("amount", .number, "Blend between the original (0) and the full repair (1). Default 1" + (Restoration.dereverber != nil ? "; for dereverb 0.7." : "."), range: 0...1),
        start, end,
        .init("tracks", .list, "Track ids to repair. Default: every track."),
        .init("humFrequency", .number, "dehum: the mains frequency; without it 50 or 60 Hz is found.", range: 20...400),
        .init("sensitivity", .number, "declick: higher finds quieter clicks. Default 1.", range: 0.1...10),
    ] }
    /// Computed each time: the formats depend on what the app registered (MP3).
    /// Only in builds that run CLAP plugins.
    static var scanEndpoint: OperationSpec {
        .init("scan_plugins", "Scan for Plugins", "Looks for CLAP plugins again, as a job: each bundle is loaded in a helper process with a time limit, so one that crashes or hangs is noted (GET /api/v1/plugins, scan.failed) and the scan goes on.",
              params: [OperationSpec.Param("force", .boolean, "Load every bundle again, not only new and changed ones. Default false.")],
              call: ("POST", "/api/v1/plugins/scan"), startsJob: true)
    }
    public static var endpoints: [OperationSpec] { fixedEndpoints + (InsertUnits.external != nil ? [scanEndpoint] : []) }
    static var fixedEndpoints: [OperationSpec] { [
        .init("transcribe_turn", "Transcribe a Short Turn", "Transcribes one short turn of speech on this Mac and answers at once, with no document and no window: for an app's live captions. The body is the WAV itself, 16 kHz mono 16-bit PCM, at most 15 s (else 413). Answers {text, words: [{text, start, end, confidence}], engine, model, ms}. One turn at a time (409 busy; 409 stopped when the user stops it in Jämmer's window). The audio is never written to disk or kept, and neither the audio nor the text is logged; Jämmer's window says while it works. 422 model_missing with requirement when the model isn't installed (the API never installs one), 503 model_unavailable when it is installed but doesn't answer, 403 sibling_transcription_off when the user has turned this off in Settings › Agents. A closed connection cancels the turn. Free.",
              params: [.init("language", .string, "BCP 47, e.g. sv-SE (the default).").at("query"),
                       .init("engine", .string, "auto (the default): local Pianissimo once its model is loaded (the first auto turn starts loading it, which takes some seconds), meanwhile KB-Whisper, else Whisper small; or whisper or pianissimo.", options: ["auto", "whisper", "pianissimo"]).at("query")],
              call: ("POST", "/api/v1/transcribe")),
        .init("transcribe_file", "Transcribe a File for Another App", "Transcribes a whole file of speech on this Mac as a job, with no document and no window: for an app that keeps the words itself, such as captions for a film. The body is the audio (Content-Type: audio/…; WAV, AIFF, m4a, MP3, FLAC or CAF), or {\"upload\": \"<id>\"} from POST /api/v1/uploads for a file over 256 MB; never a path. At most 2 hours (else 413). Answers 202 with the job; follow it at GET /api/v1/jobs/{id} and stop it with DELETE. The first GET of the finished job carries result {text, words: [{text, start, end, confidence}], engine, model, language}, times in seconds from the start of the file; Jämmer then forgets the words, so a later GET says result.gone (and so does one more than 10 minutes after the job finished). The audio lies in a private temporary folder only while the job runs, and neither it nor the text is logged; Jämmer's windows say while it works, with a Stop. One transcription for another app at a time, a file or a turn (409 busy). 422 model_missing with requirement when the model isn't installed (the API never installs one), 403 sibling_transcription_off when the user has turned this off in Settings › Agents. Free.",
              params: [.init("language", .string, "BCP 47, e.g. sv-SE (the default).").at("query"),
                       .init("engine", .string, "auto (the default): local Pianissimo when it is installed for the language, else KB-Whisper for Swedish, else Whisper small; or whisper or pianissimo.", options: ["auto", "whisper", "pianissimo"]).at("query")],
              call: ("POST", "/api/v1/transcribe/file"), startsJob: true),
        .init("list_voice_profiles", "List Voice Profiles", "The voice profiles saved on this Mac: id, name and createdAt, never the voiceprint; with recognize (on or off) and the threshold. Profiles are made and deleted only in the window, by the user. diarize (mode ml) names a speaker after a profile it is like (matchedProfile, matchScore, threshold in its result): that is a suggestion, so say \"is like Anna\", never \"is Anna\".",
              params: [], call: ("GET", "/api/v1/voice-profiles")),
        .init("request_voice_profile", "Ask to Save a Voice Profile", "Shows the sheet that saves a speaker as a voice profile in the document's window, if it is visible and in front; the user decides, consent first, and nothing is saved by this call. Answers 202 {shown: true}, not what the user chose: list the profiles afterwards. 409 sheet_open when a sheet is already shown; 422 not_visible, or no_speakers before diarize (mode ml).",
              params: [.init("speaker", .string, "The speaker's number (1, 2, …) or name; the first otherwise.")],
              call: ("POST", "/api/v1/documents/{id}/voice-profile/request")),
        .init("freeze", "Freeze", "Renders a track or a bus through its plugins into a file and plays it from that file, with the plugins idle: for a session with more plugins than the Mac plays. Its fader, pan, mute, sends and route come after the file and stay live. A step that would change what it was frozen from (its clips, its plugins; for a bus anything that feeds it; a track its plugins listen to) then fails with reason `frozen`; unfreeze first. Answers with a job; the freeze is one undo step.",
              params: [.init("strip", .string, "The id of the track or bus.", required: true)],
              call: ("POST", "/api/v1/documents/{id}/freeze"), startsJob: true),
        .init("unfreeze", "Unfreeze", "Thaws a frozen track or bus: it is worked out live again, from exactly what it was. One undo step.",
              params: [.init("strip", .string, "The id of the track or bus.", required: true)],
              call: ("POST", "/api/v1/documents/{id}/unfreeze")),
        .init("transcribe", "Transcribe", "Transcribes the document as a job and applies the transcript in one undo step. Local engines give word times. Berget AI and OpenAI return text only.",
              params: [.init("language", .string, "BCP 47, e.g. sv-SE or da-DK. Default: the Mac's language."),
                       .init("engine", .string, "auto: KB-Whisper for Swedish when installed, else Parakeet for supported languages when installed, else Apple. pianissimo: Klang Pianissimo on this Mac, for Swedish or Danish. Install the matching model in Settings › Models. berget_pianissimo: uploads whole source files to Berget AI for Swedish transcription using the user's Berget key. openai: uploads whole source files to OpenAI using the user's OpenAI key and model. Both paid engines are explicit choices only.", options: TranscriptionChoice.allCases.map(\.rawValue)),
                       .init("model", .string, "For engine openai: one of the transcription models OpenAI lists for the key."),
                       .init("allowPaid", .boolean, "Must be true for openai and berget_pianissimo (else 402 paid_not_allowed)."),
                       .init("allowUnknownPrice", .boolean, "Must also be true for openai (else 422 unknown_price)."),
                       .init("replace", .boolean, "Transcribe again even where there is a transcript.")],
              call: ("POST", "/api/v1/documents/{id}/transcribe"), startsJob: true),
        .init("transcribe_voice_tracks", "Transcribe Voice Tracks", "Transcribes each voice track independently on this Mac. The multilingual Whisper model is required; installed Pianissimo models refine Swedish or Danish. When speech cannot be assigned a language confidently, language is und. Explicit introductions can name tracks. A preceding speaker’s introduction is used only when a self-introduction is absent. Duplicate names get distinguishing details from the introductions, or numbers. The job reports each track’s language, name, engine and word count. All changes are one undo step.",
              params: [.init("tracks", .list, "Track IDs. By default, active tracks with detected speech, or all active audio tracks before diarization."),
                       .init("splitTrack", .string, "An already diarized track ID to split, then transcribe the resulting speaker tracks. Use this or tracks."),
                       .init("nameSpeakers", .boolean, "Name tracks from introductions. Default true.")],
              call: ("POST", "/api/v1/documents/{id}/transcribe-voice-tracks"), startsJob: true),
        .init("export_transcript", "Export Transcript", "Returns a document transcript as TXT, JSON, SRT or WebVTT. Exports one track or all audible tracks. JSON groups words by track and includes languages and recognizers. Subtitle exports need word timestamps.",
              params: [.init("format", .string, "File format. Default txt.", options: TranscriptExport.allCases.map(\.rawValue)),
                       .init("track", .string, "Export only this track ID.")], edits: false,
              call: ("GET", "/api/v1/documents/{id}/transcript/export")),
        .init("list_voices", "List Cloned Voices", "The voices cloned for this document (Overdub), each with whose it is by the user's attestation, where the consent sentence was heard, when it was made, and whether it was deleted at the provider.",
              edits: false, call: ("GET", "/api/v1/documents/{id}/voices")),
        .init("clone_voice", "Clone Voice", "Clones a speaker's voice at ElevenLabs with the user's own key, for Overdub. First, and before anything is uploaded: `attest` says the voice is the user's own (own) or that its owner has given explicit consent (owner_consent), `adult` that the person is 18 or older, and the person says the consent sentence in the recording itself, where `consent` points (the document must be transcribed: the sentence is heard in the transcript; GET …/voices says the sentence when it is missing). Then `samples` (at least 10 s of the speaker, pieces of at least 5 s, at most 3 minutes) are sent. The voice is kept in the document with that record; one undo step. Never clone a voice without its owner's consent.",
              params: [.init("name", .string, "Whose voice it is, as the user names it.", required: true),
                       .init("attest", .string, "own: the user's own voice. owner_consent: its owner has given the user explicit, informed consent.", required: true, options: VoiceAttestation.Kind.allCases.map(\.rawValue)),
                       .init("adult", .boolean, "The person whose voice it is is 18 or older.", required: true),
                       .init("consent", .numbers, "[start, end] in seconds: where the person says the consent sentence.", required: true),
                       .init("samples", .pairs, "[[start, end], …] in seconds: pieces of the speaker alone.", required: true),
                       .init("allowPaid", .boolean, "Must be true: the user's ElevenLabs account pays.", required: true),
                       .init("allowUnknownPrice", .boolean, "Must also be true: Jämmer doesn't know the user's plan's price.", required: true)],
              paid: true, call: ("POST", "/api/v1/documents/{id}/voices")),
        .init("overdub", "Overdub", "Says `text` in a cloned voice (ElevenLabs, the user's own key) and puts it in place of start…end on the track: what follows moves with the new length, as a cut does; one undo step. The new clip is marked as made with a cloned voice, in the document and in an exported WAV's metadata; ElevenLabs' own file is kept as it came, with its watermark.",
              params: [.init("voice", .string, "The cloned voice's id (list_voices).", required: true),
                       start, end,
                       .init("text", .string, "What the voice says (at most 10 000 characters).", required: true),
                       .init("track", .string, "The track's id; default: the first track with sound at start."),
                       .init("model", .string, "ElevenLabs' model.", options: Overdub.models),
                       .init("allowPaid", .boolean, "Must be true: the user's ElevenLabs account pays.", required: true),
                       .init("allowUnknownPrice", .boolean, "Must also be true: Jämmer doesn't know the user's plan's price.", required: true)],
              paid: true, call: ("POST", "/api/v1/documents/{id}/overdub")),
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
        .init("separate", "Separate Stems", "Splits tracks into stems as a job: model music4 gives vocals, drums, bass and other (Spleeter, for music); model dialog gives speech, music and effects (MRX, for film and video sound; slower). Each track is replaced by one track per stem, in a group, playing from new files; together they sound exactly like the track did, so nothing changes until you change a stem. With music4, sound above the model's 11 kHz goes to other; with dialog, what the model leaves is shared between music and effects. One undo step. The model is installed by the user in Settings › Models (reason model_missing otherwise); tracks with plugins are refused (has_inserts).",
              params: [.init("model", .string, "Which separation. Default music4.", options: ["music4", "dialog"]),
                       .init("tracks", .list, "Track ids. Default: every track with audio.")],
              call: ("POST", "/api/v1/documents/{id}/separate"), startsJob: true),
        .init("batch", "Batch", "Processes files without opening them, as a job: each file gets the steps, then the jobs (restore, transcribe, diarize, separate), and is exported into output as “name<suffix>.<format>”. Every path must lie in a folder the user allowed in Settings › Agents (reason folder_not_allowed otherwise; GET /api/v1/status has agentFolders, the count). Inputs are never written over (would_overwrite_source); existing results are skipped unless overwrite; one file failing doesn't stop the rest.",
              params: [OperationSpec.Param("files", .list, "Absolute paths of audio files."),
                       OperationSpec.Param("folder", .string, "Or a folder: every audio file directly in it."),
                       OperationSpec.Param("output", .string, "The folder results go in.", required: true),
                       OperationSpec.Param("suffix", .string, "Added to each name. Default “ (Jämmer)”."),
                       OperationSpec.Param("overwrite", .boolean, "Replace results that are already there. Default false."),
                       OperationSpec.Param("allowPaid", .boolean, "Must be true for jobs with a paid transcription engine."),
                       OperationSpec.Param("allowUnknownPrice", .boolean, "Must also be true when an OpenAI transcription job is present.")],
              call: ("POST", "/api/v1/batch"), startsJob: true),
        .init("import_fcpxml", "Import Final Cut Pro XML", "Opens the sound of a film timeline (FCPXML from Flimmer, Final Cut Pro or DaVinci Resolve) as a new document: one track per lane with each clip's position, trim, level, linear fades and mute; the pictures become shot markers (shown on the timeline, not chapters). The file and every media file it uses must lie in a folder the user allows in Jämmer's Settings (reason folder_not_allowed otherwise). Nothing in those files is changed.",
              params: [OperationSpec.Param("path", .string, "Absolute path of the .fcpxml file (or .fcpxmld bundle).", required: true)],
              call: ("POST", "/api/v1/import/fcpxml")),
        .init("import_timeline", "Import Timeline", "Opens a timeline's sound as a new document: FCPXML (as import_fcpxml), a CMX 3600 EDL (audio events A–A4 on tracks 1–4; each event's file from its SOURCE FILE, FROM FILE or FROM CLIP comment, else a file named as its clip or reel beside the list), OpenTimelineIO (.otio, audio tracks) or DAWproject (audio clips in seconds or beats). What a format holds that Jämmer doesn't read (video, transitions, warped clips) is left out and said in warnings.",
              params: [OperationSpec.Param("path", .string, "Absolute path of the .fcpxml, .edl, .otio or .dawproject file.", required: true),
                       OperationSpec.Param("rate", .string, "EDL only: the frame rate its times are at (an EDL doesn't say). Default 25, or 29.97df when its FCM says DROP FRAME.", options: Timecode.Rate.allCases.map(\.rawValue))],
              call: ("POST", "/api/v1/import/timeline")),
        .init("export_timeline", "Export Timeline", "The document's clips as a timeline file, as bytes; nothing is rendered, the file names the audio files the clips play. edl: CMX 3600, tracks 1–4, at the document's timecode (25 fps from 00:00:00:00 without one). otio: OpenTimelineIO JSON with Jämmer's gain and fades in its metadata. dawproject: DAWproject 1.0 (a ZIP), the audio referenced by path. What the format can't hold is said in X-Jammer-Warning headers.",
              params: [OperationSpec.Param("format", .string, "The timeline format.", required: true, options: TimelineFormat.allCases.map(\.rawValue))],
              edits: false, call: ("POST", "/api/v1/documents/{id}/export/timeline")),
        .init("get_chapters", "Read Chapters", "The markers as Podcasting 2.0 chapters (JSON, version 1.2.0), optionally over start and end.",
              params: [start, end], edits: false, call: ("GET", "/api/v1/documents/{id}/chapters")),
        .init("measure_loudness", "Measure Loudness", "Integrated LUFS, loudness range, max momentary and short-term, sample and true peak.",
              params: [start, end, .init("tracks", .list, "Only these tracks, as they sound without the others (query: comma-separated).")], edits: false, call: ("GET", "/api/v1/documents/{id}/analysis")),
        .init("analyze_rhythm", "Find Tempo and Beats", "The tempo and the beat times of music, without changing anything: bpm, firstBeat, beats (seconds), pulse, alternatives (half and double the tempo: a fast tempo can come back at half speed). bpm is null, with reason no_steady_tempo, for speech, noise, silence, or music without one steady tempo. Looks at up to 120 s from the start of the range.",
              params: [start, end, .init("tracks", .list, "Only these tracks' sound (query: comma-separated). Default: the mix.")], edits: false,
              call: ("GET", "/api/v1/documents/{id}/analysis/rhythm")),
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
                       .init("tracks", .list, "Only these tracks, as they sound without the others; the file still covers the whole timeline."),
                       .init("chapters", .boolean, "Write the markers as chapters (default true): ID3 chapters in mp3, a chapter track in aac and alac, CHAPTERxxx comments in opus. wav keeps markers as cue points; aiff and flac have no chapters."),
                       .init("targetLUFS", .number, "mp3, aac and opus: deliver the file at this integrated loudness. The file is measured as written and the gain before the encoder corrected (at most two more encodes, never past −1 dBTP). Without it, the target is the loudness preset the document was last brought to, if nothing changed since.", range: -40 ... -5),
                       .init("compensate", .boolean, "false: encode once and leave the loudness as it comes out. Default true when there is a target.")],
              edits: false, call: ("POST", "/api/v1/documents/{id}/export")),
        .init("restore", "Repair", "Removes hum, repairs clipping, removes clicks, reduces noise" + (Restoration.dereverber != nil ? " or reduces reverb" : "") + ". Answers with a job; one undo step brings the original back.",
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

    /// A list of [a, b] pairs of finite numbers.
    public var pairs: [(Double, Double)]? {
        guard case .array(let a) = self else { return nil }
        var out: [(Double, Double)] = []
        for item in a {
            guard let n = item.numbers, n.count == 2, n[0].isFinite, n[1].isFinite else { return nil }
            out.append((n[0], n[1]))
        }
        return out
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
    /// The selected track (select_track), when a step chose one.
    public var currentTrack: UUID?
    public var clipboard: ClipboardContent?
    /// For steps that render audio (echo): where sources are read and new files written.
    public var pool: SourcePool?
    public var media: URL?
    /// Ids the current step made; moved into its result.
    public var made: [String: String] = [:]
    /// Things the current step wants said with its result (it was done, and this goes with it).
    public var warnings: [String] = []

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
    /// What goes with a step that was done: something that stayed as it was although one might think it
    /// followed (automation under a track that was moved).
    public var warnings: [String] = []
    /// Ids of things the step made, e.g. ["insert": "…"].
    public var ids: [String: String] = [:]
    /// Why it failed, by its key in the app's string catalogue (not part of the API's answer): for the
    /// window, which says it in its own language. nil when the words were made where the step failed.
    public var keyed: KeyedMessage?

    /// A step the window's Stop ended: nothing of it is taken in.
    public static func stopped(_ op: String) -> StepResult {
        StepResult(op: op, status: .failed, error: "Stopped in Jämmer's window.", reason: "stopped", keyed: KeyedMessage("job.stopped"))
    }

    /// The document changed in the same place while the steps ran (the user's edit, or another run's): the result
    /// isn't laid over it (COMFORT 77). It is kept in the history as a branch (`kept`, its node), to be chosen there.
    public static func changedMeanwhile(_ op: String, kept: UUID?) -> StepResult {
        let said: Said
        if kept != nil {
            said = Said("error.step.changedMeanwhile.kept", "The document changed in the same place while this ran, so it wasn't put in. The result is kept in History, marked (late): choose it there to use it.")
        } else {
            said = Said("error.step.changedMeanwhile", "The document changed in the same place while this ran, so it wasn't put in. Run it again on the document as it is now.")
        }
        var r = StepResult(op: op, status: .failed, error: said.text, reason: "changed_meanwhile", keyed: said.keyed)
        // For an agent: the kept result's node, which POST …/history/{node} uses.
        if let kept { r.ids["keptAs"] = kept.uuidString }
        return r
    }
}

public struct StepFailure: Error, LocalizedError {
    public var message: String
    public var reason: String?
    public var details: [String: Double]
    /// The reason by its key in the app's string catalogue, when the failure came from an error that has
    /// one: the window says it in its own language, the API says `message`.
    public var keyed: KeyedMessage?
    public init(_ message: String, reason: String? = nil, details: [String: Double] = [:], keyed: KeyedMessage? = nil) {
        self.message = message
        self.reason = reason
        self.details = details
        self.keyed = keyed
    }
    public var errorDescription: String? { message }
    /// A step's name and another error's reason ("set_tempo: …"): in the window by that error's own key when it
    /// has one; otherwise its words as they are (a plugin host's own words stay its own).
    public init(_ op: String, wrapping error: Error, reason: String? = nil) {
        let said = Said("step.any.wrapped", "%1$@: %2$@", op, error.localizedDescription)
        self.init(said.text, reason: reason, keyed: (error as? KeyedFailure)?.keyed ?? said.keyed)
    }
    /// A failure said by its key in the window and in its English to the API.
    public init(_ said: Said, reason: String? = nil, details: [String: Double] = [:]) {
        self.init(said.text, reason: reason, details: details, keyed: said.keyed)
    }
}

public enum StepRunner {
    /// Measures loudness of a project range (the session renders; tests can fake it).
    public typealias Measure = @Sendable (Project, Range<Frame>) -> LoudnessResult

    /// The parameters that name a track, bus or VCA group (alone or in a list).
    static let stripParams: Set<String> = ["track", "tracks", "under", "strip", "from", "to", "members", "add", "remove", "reference", "against", "output"]

    /// A strip given by its name instead of its id: the one strip whose name it is, ignoring case, takes its id.
    /// A value that names no strip, or several, isn't guessed at: the step fails with the strips' ids and names,
    /// so that whoever wrote it (often a model, which said "music" for the track called Music, 2026-11-19) can
    /// try again. Ids, "master" and anything that isn't a strip parameter pass as they are.
    public static func resolveStrips(_ step: Step, in project: Project) throws -> Step {
        let strips = project.tracks.map { ($0.id.uuidString, $0.name) } + project.buses.map { ($0.id.uuidString, $0.name) } + project.vcas.map { ($0.id.uuidString, $0.name) }
        return try resolveStrips(step, strips: strips)
    }

    /// The same against a list of the document's strips, as ids and names (what the assistant's context has).
    public static func resolveStrips(_ step: Step, strips: [(id: String, name: String)]) throws -> Step {
        let known = Set(strips.map { $0.id.uppercased() })
        func one(_ value: String, _ param: String) throws -> String {
            if known.contains(value.uppercased()) { return value }
            if value.lowercased() == "master" || UUID(uuidString: value) != nil { return value }
            let hits = strips.filter { $0.name.compare(value, options: [.caseInsensitive]) == .orderedSame }
            if hits.count == 1 { return hits[0].id }
            let list = strips.map { "\($0.id) (\($0.name))" }.joined(separator: ", ")
            if hits.isEmpty {
                throw StepFailure(Said("step.any.strip_unknown", "%1$@: %2$@ \"%3$@\" is neither the id nor the name of a track, bus or group. They are: %4$@.", step.op, param, value, list), reason: "not_found")
            }
            throw StepFailure(Said("step.any.strip_ambiguous", "%1$@: %2$@ \"%3$@\" is the name of more than one track, bus or group; give its id. They are: %4$@.", step.op, param, value, list), reason: "not_found")
        }
        var out = step
        // A number where a strip goes is no strip either (the on-device model wrote `"under": 10` for "by 10 dB").
        func text(_ v: JSONValue) -> String? {
            switch v {
            case .string(let s): s
            case .number(let d): d == d.rounded() ? String(Int(d)) : String(d)
            default: nil
            }
        }
        for (key, value) in step.params where stripParams.contains(key) {
            switch value {
            case .string, .number: if let s = text(value) { out.params[key] = .string(try one(s, key)) }
            case .array(let items): out.params[key] = .array(try items.map { v in if let s = text(v) { return .string(try one(s, key)) }; return v })
            default: break
            }
        }
        return out
    }

    /// Runs steps in order on a copy of `state`; stops at the first failure and
    /// marks the rest skipped. The caller commits `state` (one undo step) only if
    /// something changed.
    /// `stopped` is asked before each step: once it says yes, the rest are skipped and the first of them fails with
    /// the reason "stopped" (the window's Stop; the caller then applies nothing).
    public static func run(_ steps: [Step], on state: inout EditState, measure: Measure, stopped: () -> Bool = { false }) -> [StepResult] {
        var results: [StepResult] = []
        var failed = false
        for step in steps {
            if failed {
                results.append(StepResult(op: step.op, status: .skipped))
                continue
            }
            if stopped() {
                results.append(.stopped(step.op))
                failed = true
                continue
            }
            do {
                state.made = [:]
                state.warnings = []
                let before = state.project
                // BS.1770 has no loudness for a sound field: in an Ambisonics document no step acts on a loudness number.
                if state.project.layout.isAmbisonic, ["loudness_preset", "limit"].contains(step.op)
                    || (step.op == "normalize" && (step.params["target"]?.string ?? "loudness") == "loudness") {
                    throw StepFailure(Said("step.any.loudness_isn_t_measured", "%@: loudness isn't measured in an Ambisonics document (ITU-R BS.1770 has no weighting for a sound field). Export it for loudspeakers or headphones and measure that.", "\(step.op)"), reason: "not_available")
                }
                let info = try apply(try resolveStrips(step, in: state.project), to: &state, measure: measure)
                // A mark of speech made with a cloned voice follows the audio into what a step rendered.
                state.project.inheritSyntheticMarks(from: before)
        state.project.inheritOrigins(from: before)
                // A track moved by itself (lined up, stretched) under automation that stays on the timeline:
                // done, and said, so that nobody thinks the lane followed.
                if movesOneTrack.contains(step.op) {
                    for t in state.project.tracks {
                        guard let was = before.tracks.first(where: { $0.id == t.id }), was.clips != t.clips else { continue }
                        let points = state.project.lanes(of: t.id).reduce(0) { $0 + $1.points.count }
                        if points > 0 { state.warnings.append("The automation on \(t.name) stays where it is on the timeline (\(points) point\(points == 1 ? "" : "s")): the track's sound moved under it, the lane didn't.") }
                    }
                }
                // A frozen strip is a file of what it was: nothing may change what that file was made from.
                if let name = before.frozenViolation(in: state.project) {
                    state.project = before
                    throw StepFailure(step.op, wrapping: FreezeError.frozen(name), reason: "frozen")
                }
                // A locked track keeps its clips: a step that would change them (or remove the track) changes nothing.
                if let name = state.project.lockedTrackChanged(since: before) {
                    state.project = before
                    throw StepFailure(step.op, wrapping: TrackEditError.locked(name), reason: "locked")
                }
                var result = StepResult(op: step.op, status: .done, info: info, ids: state.made)
                result.warnings = state.warnings
                results.append(result)
                state.made = [:]
                state.warnings = []
            } catch {
                let f = error as? StepFailure
                var result = StepResult(op: step.op, status: .failed, error: error.localizedDescription,
                                        reason: f?.reason, details: f?.details ?? [:])
                result.keyed = f?.keyed ?? (error as? any KeyedFailure)?.keyed
                results.append(result)
                failed = true
                // Nothing from a failed request is kept.
                for i in results.indices where results[i].status == .done { results[i].status = .reverted }
            }
        }
        return results
    }

    /// Steps that move one track's sound by itself, without closing or opening the whole timeline.
    static let movesOneTrack: Set<String> = ["align_tracks", "correct_drift"]

    /// What can only be checked against the document, before anything runs: for an agent's request this
    /// is a 400 with the field's name, not a failed step. (Automation: a strip that is there, points
    /// inside the document and inside the range given.)
    public static func check(_ step: Step, against project: Project) throws {
        guard ["set_automation", "clear_automation"].contains(step.op) else { return }
        let p = step.params
        let name = p["strip"]?.string ?? ""
        guard name == "master" || UUID(uuidString: name).map({ id in project.tracks.contains { $0.id == id } || project.bus(id) != nil || project.vca(id) != nil }) == true else {
            throw StepFailure(Said("step.any.strip_id_track_bus", "%1$@: \"strip\" is the id of a track, a bus or a VCA group, or \"master\"; there is none with id %2$@.", "\(step.op)", "\(name)"), reason: "not_found")
        }
        guard (p["start"] == nil) == (p["end"] == nil) else { throw StepFailure(Said("step.any.start_end_go_together", "%@: \"start\" and \"end\" go together.", "\(step.op)")) }
        let end = project.seconds(project.length)
        if let a = p["start"]?.double, let b = p["end"]?.double {
            guard a <= b else { throw StepFailure(Said("step.any.start_after_end", "%@: \"start\" is after \"end\".", "\(step.op)")) }
            guard b <= end + 1e-9 else { throw StepFailure(Said("step.any.end_2_s_after", "%1$@: \"end\" is at %2$@ s, after the document's end (%3$@ s).", values: ["\(step.op)", Said.n(b), Said.n(end)])) }
        }
        let param = AutomationLane.Param(rawValue: p["param"]?.string ?? "gain") ?? .gain
        if name == "master", param != .gain, param != .plugin, param != .azimuth, param != .elevation { throw StepFailure(Said("step.any.param_gain_plugin_master", "%@: \"param\" is gain or plugin for the master; it has no pan, mute or send to automate.", "\(step.op)")) }
        if param == .plugin {
            guard p["insert"]?.string?.isEmpty == false, p["parameter"]?.string?.isEmpty == false else {
                throw StepFailure(Said("step.any.insert_parameter_needed_param", "%@: \"insert\" and \"parameter\" are needed with param plugin: the plugin on the strip and which of its parameters.", "\(step.op)"))
            }
        } else if p["insert"] != nil || p["parameter"] != nil {
            throw StepFailure(Said("step.any.insert_parameter_go_param", "%@: \"insert\" and \"parameter\" go with param plugin only.", "\(step.op)"))
        }
        let stripID = UUID(uuidString: name)
        if let id = stripID, project.vca(id) != nil, param == .pan || param == .send { throw StepFailure(Said("step.any.param_gain_mute_vca", "%@: \"param\" is gain or mute for a VCA group; it has no pan or send.", "\(step.op)")) }
        if param == .send {
            guard let to = p["to"]?.string else { throw StepFailure(Said("step.any.needed_param_send_id", "%@: \"to\" is needed with param send: the id of the bus the send goes to.", "\(step.op)")) }
            guard let toID = UUID(uuidString: to), let from = stripID, project.hasSend(from: from, to: toID) else {
                throw StepFailure(Said("step.any.strip_has_send_2", "%1$@: \"to\": that strip has no send to %2$@. Make the send first (set_send).", "\(step.op)", "\(to)"), reason: "not_found")
            }
        } else if p["to"] != nil {
            throw StepFailure(Said("step.any.goes_param_send_only", "%@: \"to\" goes with param send only.", "\(step.op)"))
        }
        if param == .pan, project.channels != 2 {
            throw StepFailure(project.channels > 2
                ? Said("step.any.pan_wide", "%1$@: \"param\" can't be pan in a %2$@ document; a track's place is azimuth and elevation there.", "\(step.op)", project.layout.rawValue)
                : Said("step.any.pan_mono", "%@: \"param\" can't be pan in a mono document.", "\(step.op)"), reason: "needs_stereo")
        }
        if param == .azimuth || param == .elevation {
            guard project.channels > 2 else {
                throw StepFailure(Said("step.any.azimuth_elevation_track_s", "%1$@: azimuth and elevation are a track's place in a document wider than stereo; this one is %2$@. Use pan.", "\(step.op)", "\(project.layout.rawValue)"), reason: "needs_surround")
            }
            let onBus = param == .azimuth && stripID.map { project.bus($0) != nil } == true && !project.layout.isAmbisonic
            guard let id = stripID, project.tracks.contains(where: { $0.id == id }) || onBus else {
                throw StepFailure(name == "master"
                    ? Said("step.any.place_master", "%@: azimuth and elevation are a track's place, and azimuth a bus's turn in a loudspeaker layout; the master has neither.", "\(step.op)")
                    : Said("step.any.place_strip", "%@: azimuth and elevation are a track's place, and azimuth a bus's turn in a loudspeaker layout; this strip has neither.", "\(step.op)"), reason: "needs_surround")
            }
        }
        let allowed = Automation.range(of: param)
        for (i, pair) in (p["points"]?.pairs ?? []).enumerated() {
            guard allowed.contains(pair.1), param != .mute || pair.1 == 0 || pair.1 == 1 else {
                throw StepFailure(param == .gain || param == .send ? Said("step.any.point_gain", "%1$@: points[%2$@] has the value %3$@; a gain is −96 to 24 dB.", values: ["\(step.op)", "\(i)", Said.n(pair.1)])
                                  : param == .pan ? Said("step.any.point_pan", "%1$@: points[%2$@] has the value %3$@; a pan is −1 (left) to 1 (right).", values: ["\(step.op)", "\(i)", Said.n(pair.1)])
                                  : Said("step.any.point_mute", "%1$@: points[%2$@] has the value %3$@; a mute is 1 (muted) or 0 (heard).", values: ["\(step.op)", "\(i)", Said.n(pair.1)]))
            }
            guard pair.0 <= end + 1e-9 else { throw StepFailure(Said("step.any.points_2_3_s", "%1$@: points[%2$@] is at %3$@ s, after the document's end (%4$@ s).", values: ["\(step.op)", "\(i)", Said.n(pair.0), Said.n(end)])) }
            if let a = p["start"]?.double, let b = p["end"]?.double, pair.0 < a - 1e-9 || pair.0 > b + 1e-9 {
                throw StepFailure(Said("step.any.points_2_3_s2", "%1$@: points[%2$@] is at %3$@ s, outside \"start\"…\"end\" (%4$@ to %5$@ s).", values: ["\(step.op)", "\(i)", Said.n(pair.0), Said.n(a), Said.n(b)]))
            }
        }
    }

    /// Checks names and required params before anything runs.
    public static func validate(_ step: Step) throws {
        guard let spec = Operations.named(step.op) else { throw StepFailure(Said("step.step.unknown_op", "Unknown op \"%@\".", "\(step.op)")) }
        for p in spec.params where p.required && step.params[p.name] == nil {
            throw StepFailure(Said("step.any.2", "%1$@ needs \"%2$@\".", "\(step.op)", "\(p.name)"))
        }
        for (key, value) in step.params where key != AgentAPI.rationale {
            guard let p = spec.params.first(where: { $0.name == key }) else {
                throw StepFailure(Said("step.any.parameter_2_takes_3", "%1$@ has no parameter \"%2$@\". It takes: %3$@.", "\(step.op)", "\(key)", "\(spec.params.map(\.name).joined(separator: ", "))"))
            }
            switch p.kind {
            case .seconds, .number:
                guard let d = value.double, d.isFinite else { throw StepFailure(Said("step.any.2_number", "%1$@: \"%2$@\" must be a number.", "\(step.op)", "\(key)")) }
                if p.kind == .seconds, d < 0 { throw StepFailure(Said("step.any.2_can_t_negative", "%1$@: \"%2$@\" can't be negative.", "\(step.op)", "\(key)")) }
                if let r = p.range, !r.contains(d) {
                    throw StepFailure(Said("step.any.2_between_3_4", "%1$@: \"%2$@\" must be between %3$@ and %4$@.", values: ["\(step.op)", "\(key)", Said.n(r.lowerBound), Said.n(r.upperBound)]))
                }
            case .string:
                guard let s = value.string else { throw StepFailure(Said("step.any.2_string", "%1$@: \"%2$@\" must be a string.", "\(step.op)", "\(key)")) }
                if let options = p.options, !options.contains(s) {
                    throw StepFailure(Said("step.any.2_one_3", "%1$@: \"%2$@\" must be one of %3$@.", "\(step.op)", "\(key)", "\(options.joined(separator: ", "))"))
                }
            case .boolean:
                guard case .bool = value else { throw StepFailure(Said("step.any.2_true_false", "%1$@: \"%2$@\" must be true or false.", "\(step.op)", "\(key)")) }
            case .list:
                guard value.strings != nil else { throw StepFailure(Said("step.any.2_list_strings", "%1$@: \"%2$@\" must be a list of strings.", "\(step.op)", "\(key)")) }
            case .numbers:
                guard let n = value.numbers, n.allSatisfy(\.isFinite) else { throw StepFailure(Said("step.any.2_list_numbers", "%1$@: \"%2$@\" must be a list of numbers.", "\(step.op)", "\(key)")) }
            case .pairs:
                guard let pairs = value.pairs else { throw StepFailure(Said("step.any.2_list_seconds_value", "%1$@: \"%2$@\" must be a list of [seconds, value] pairs of numbers.", "\(step.op)", "\(key)")) }
                for (i, pair) in pairs.enumerated() {
                    if pair.0 < 0 { throw StepFailure(Said("step.any.2_3_4_s", "%1$@: %2$@[%3$@] is at %4$@ s; a point can't be before the start.", values: ["\(step.op)", "\(key)", "\(i)", Said.n(pair.0)])) }
                    if let r = p.range, !r.contains(pair.1) {
                        throw StepFailure(Said("step.any.2_3_has_value", "%1$@: %2$@[%3$@] has the value %4$@; it must be between %5$@ and %6$@.", values: ["\(step.op)", "\(key)", "\(i)", Said.n(pair.1), Said.n(r.lowerBound), Said.n(r.upperBound)]))
                    }
                }
            }
        }
    }

    static func apply(_ step: Step, to s: inout EditState, measure: Measure) throws -> [String: Double] {
        try validate(step)
        let p = step.params
        let project = s.project
        func frames(_ key: String) -> Frame? { p[key]?.double.map { project.frames($0) } }
        /// The explicit range, else the selection, else (when allowed) everything.
        /// A route given as a bus id or "master": nil when the parameter isn't there, `.some(nil)` for the output.
        func route(_ v: JSONValue?, _ op: String) throws -> UUID?? {
            guard let text = v?.string else { return nil }
            if text == "master" { return .some(nil) }
            guard let id = UUID(uuidString: text) else { throw StepFailure(Said("step.any.route_bus_id_master", "%@: a route is a bus id or \"master\".", "\(op)"), reason: "not_found") }
            return .some(id)
        }
        func range(wholeIfNone: Bool = false) throws -> Range<Frame> {
            if let a = frames("start"), let b = frames("end") {
                guard b > a else { throw StepFailure(Said("step.any.end_after_start", "%@: end must be after start.", "\(step.op)")) }
                return a..<b
            }
            if p["start"] != nil || p["end"] != nil { throw StepFailure(Said("step.any.give_both_start_end", "%@: give both start and end, or neither.", "\(step.op)")) }
            if let sel = s.selection, !sel.isEmpty { return sel }
            if wholeIfNone, project.length > 0 { return 0..<project.length }
            throw StepFailure(Said("step.any.range_pass_start_end", "%@ needs a range: pass start and end, or select first.", "\(step.op)"))
        }
        func checkInside(_ r: Range<Frame>) throws {
            guard r.lowerBound < project.length else {
                throw StepFailure(Said("step.any.range_starts_after_end", "%1$@: the range starts after the end of the audio (%2$@ s).", values: ["\(step.op)", Said.n(project.duration, 3)]))
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
        case "select_track":
            guard let id = UUID(uuidString: p["track"]?.string ?? ""), project.tracks.contains(where: { $0.id == id }) else {
                throw StepFailure(Said("step.set_track.such_track", "set_track: no such track."), reason: "not_found")
            }
            s.currentTrack = id
        case "set_playhead":
            s.playhead = min(max(0, frames("at") ?? 0), project.length)
        case "set_video_reference":
            let path = p["path"]?.string ?? ""
            guard path.hasPrefix("/"), path.utf8.count <= 4_096 else { throw StepFailure(Said("step.set_video_reference.path_film_s_full", "set_video_reference: \"path\" is the film's full path, starting with a slash.")) }
            guard ["mov", "mp4", "m4v"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else {
                throw StepFailure(Said("step.set_video_reference.film_app_shows_mov", "set_video_reference: %@ is not a film this app shows (.mov, .mp4 or .m4v).", "\(URL(fileURLWithPath: path).lastPathComponent)"), reason: "not_a_film")
            }
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), !isFolder.boolValue else {
                throw StepFailure(Said("step.set_video_reference.there_file", "set_video_reference: there is no file at %@.", "\(path)"), reason: "not_found")
            }
            let at = min(max(0, frames("at") ?? 0), project.length)
            s.project.video = VideoReference(path: URL(fileURLWithPath: path).standardizedFileURL.path, start: at)
            return ["at": project.seconds(at)]
        case "remove_video_reference":
            guard project.video != nil else { throw StepFailure(Said("step.remove_video_reference.document_has_film", "remove_video_reference: the document has no film."), reason: "not_found") }
            s.project.video = nil
        case "go_to_timecode":
            guard let settings = project.timecode else { throw StepFailure(Said("step.go_to_timecode.document_has_timecode_give", "go_to_timecode: the document has no timecode. Give it one with set_timecode."), reason: "no_timecode") }
            let text = p["timecode"]?.string ?? ""
            guard let wanted = Timecode(text, rate: settings.rate) else { throw StepFailure(Said("step.go_to_timecode.1_timecode_2_hh", "go_to_timecode: %1$@ is not a timecode at %2$@ (hh:mm:ss:ff, each two digits).", "\(text)", "\(settings.rate.rawValue)")) }
            guard let at = settings.frame(of: wanted, sampleRate: project.sampleRate), at <= project.length else {
                throw StepFailure(Said("step.go_to_timecode.1_outside_document_which", "go_to_timecode: %1$@ is outside the document, which runs from %2$@ to %3$@.", "\(wanted.text)", "\(settings.start.text)", "\(settings.timecode(at: project.length, sampleRate: project.sampleRate).text)"), reason: "outside")
            }
            s.playhead = at
            return ["at": project.seconds(at)]
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
            guard let clip = s.clipboard else { throw StepFailure(Said("step.step.clipboard_empty_copy_cut", "The clipboard is empty. Copy or cut first.")) }
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
            guard n > 0 else { throw StepFailure(Said("step.insert_silence.duration_more_than_0", "insert_silence: duration must be more than 0.")) }
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
            guard let current else { throw StepFailure(Said("step.normalize.range_silent_so_there", "normalize: the range is silent, so there's nothing to match.")) }
            let change = level - current
            try s.project.changeGain(r, by: change)
            return ["gainDB": (change * 100).rounded() / 100, "before": (current * 100).rounded() / 100]
        case "align_tracks":
            guard let pool = s.pool else { throw StepFailure(Said("step.align_tracks.app", "align_tracks needs the app.")) }
            let ref: UUID
            if let r = p["reference"]?.string {
                guard let id = UUID(uuidString: r), project.tracks.contains(where: { $0.id == id }) else { throw StepFailure(Said("step.align_tracks.track_id", "align_tracks: no track with id %@.", "\(r)"), reason: "not_found") }
                ref = id
            } else {
                guard project.tracks.count > 1, let id = project.suggestedReference(pool: pool) else { throw StepFailure(Said("step.align_tracks.least_two_tracks", "align_tracks needs at least two tracks.")) }
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
            guard let pool = s.pool, let media = s.media else { throw StepFailure(Said("step.spectral_attenuate.app", "spectral_attenuate needs the app.")) }
            let r = try range(); try checkInside(r)
            let lo = p["low"]?.double ?? 0, hi = p["high"]?.double ?? 0
            guard hi > lo else { throw StepFailure(Said("step.spectral_attenuate.high_above_low", "spectral_attenuate: high must be above low.")) }
            let ids = p["tracks"]?.strings.map { Set($0.compactMap(UUID.init(uuidString:))) }
            do {
                s.project = try s.project.applyingSpectralAttenuation(range: r, freq: lo...hi, gainDB: p["db"]?.double ?? -20, tracks: ids, pool: pool, media: media)
            } catch let e as EffectError { throw StepFailure("spectral_attenuate: \(e.localizedDescription)", keyed: e.keyed) }
        case "correct_drift":
            guard let pool = s.pool, let media = s.media else { throw StepFailure(Said("step.correct_drift.app", "correct_drift needs the app.")) }
            guard let track = UUID(uuidString: p["track"]?.string ?? ""), project.tracks.contains(where: { $0.id == track }) else {
                throw StepFailure(Said("step.correct_drift.such_track", "correct_drift: no such track."), reason: "not_found")
            }
            var ppm = p["ppm"]?.double
            var confidence = 1.0
            if ppm == nil {
                let against = p["against"]?.string.flatMap(UUID.init(uuidString:))
                    ?? project.suggestedReference(pool: pool).flatMap { $0 == track ? nil : $0 }
                    ?? project.tracks.first { $0.id != track }?.id
                guard let against, let d = project.drift(of: track, against: against, pool: pool) else {
                    throw StepFailure(Said("step.correct_drift.tracks_overlap_too_little", "correct_drift: the tracks overlap too little to measure drift (at least 90 s)."), reason: "too_short")
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
            guard let pool = s.pool, let media = s.media else { throw StepFailure(Said("step.spectral_edit.app", "spectral_edit needs the app.")) }
            func pts() throws -> [SpectralPoint] {
                let n = p["points"]?.numbers ?? []
                guard n.count >= 2, n.count % 2 == 0 else { throw StepFailure(Said("step.spectral_edit.points_time_frequency_pairs", "spectral_edit: points must be time and frequency pairs."), reason: "bad_shape") }
                return stride(from: 0, to: n.count, by: 2).map { SpectralPoint(t: n[$0], f: n[$0 + 1]) }
            }
            let shape: SpectralShape
            switch p["shape"]?.string {
            case "box":
                guard let a = p["start"]?.double, let b = p["end"]?.double, let lo = p["low"]?.double, let hi = p["high"]?.double else {
                    throw StepFailure(Said("step.spectral_edit.box_needs_start_end", "spectral_edit: a box needs start, end, low and high."), reason: "bad_shape")
                }
                shape = .box(start: a, end: b, low: lo, high: hi)
            // (A where clause belongs to one pattern only, so each has its own.)
            case "polygon" where !Operations.spectralFreeform, "brush" where !Operations.spectralFreeform:
                throw StepFailure(Said("step.spectral_edit.only_shape_box_available", "spectral_edit: only shape box is available in this build."), reason: "not_available")
            case "polygon": shape = .polygon(try pts())
            default: shape = .brush(try pts(), radius: p["radius"]?.double ?? 200, radiusTime: p["radiusTime"]?.double ?? 0.02)
            }
            let ids = p["tracks"]?.strings.map { Set($0.compactMap(UUID.init(uuidString:))) }
            do {
                s.project = try s.project.applyingSpectralEdit(shape, action: p["action"]?.string == "heal" ? .heal : .attenuate,
                                                               gainDB: p["db"]?.double ?? -20, tracks: ids, pool: pool, media: media)
            } catch let e as SpectralEditError {
                throw StepFailure("spectral_edit: \(e.localizedDescription)", reason: e.reason, keyed: e.keyed)
            } catch let e as EffectError {
                throw StepFailure("spectral_edit: \(e.localizedDescription)", reason: "nothing_in_range", keyed: e.keyed)
            }
        case "debleed":
            guard let pool = s.pool, let media = s.media else { throw StepFailure(Said("step.debleed.app", "debleed needs the app.")) }
            let ids = p["tracks"]?.strings.map { $0.compactMap(UUID.init(uuidString:)) }
            do {
                let (q, report) = try s.project.debleeding(method: p["method"]?.string ?? "gate", tracks: ids, amountDB: p["amount"]?.double ?? -18,
                                                           windowMs: p["maxDelay"]?.double ?? 30, pool: pool, media: media)
                s.project = q
                return ["tracks": Double(report.tracks), "reductionDB": report.reductionDB]
            } catch let e as DebleedError {
                throw StepFailure("debleed: \(e.localizedDescription)", reason: e.reason, keyed: e.keyed)
            }
        case "duck":
            guard let pool = s.pool, let media = s.media else { throw StepFailure(Said("step.duck.app", "duck needs the app.")) }
            func ids(_ key: String) throws -> [UUID]? {
                guard let raw = p[key]?.strings else { return nil }
                return try raw.map {
                    guard let id = UUID(uuidString: $0) else { throw StepFailure(Said("step.duck.track_id", "duck: no track with id %@.", "\($0)"), reason: "not_found") }
                    return id
                }
            }
            guard let wanted = try ids("tracks"), !wanted.isEmpty else { throw StepFailure(Said("step.duck.tracks_name_least_one", "duck: tracks must name at least one track.")) }
            var settings = Ducking.Settings()
            settings.amountDB = p["amount"]?.double ?? settings.amountDB
            settings.threshold = p["threshold"]?.double ?? settings.threshold
            settings.attackMs = p["attack"]?.double ?? settings.attackMs
            settings.releaseMs = p["release"]?.double ?? settings.releaseMs
            settings.holdMs = p["hold"]?.double ?? settings.holdMs
            settings.lookaheadMs = p["lookahead"]?.double
            if case .bool(let v)? = p["stack"] { settings.stack = v }
            // The given range, else the selection, else everything.
            let limit: Range<Frame>? = (p["start"] != nil || p["end"] != nil || !(s.selection?.isEmpty ?? true)) ? try range(wholeIfNone: true) : nil
            do {
                let (q, report) = try s.project.ducking(tracks: wanted, under: try ids("under"), settings: settings, range: limit, pool: pool, media: media)
                s.project = q
                s.made["trigger"] = report.trigger
                return ["tracks": Double(report.tracks), "regions": Double(report.regions), "duckedSeconds": report.duckedSeconds, "replaced": Double(report.replaced)]
            } catch let e as DuckError {
                throw StepFailure("duck: \(e.localizedDescription)", reason: e.reason, keyed: e.keyed)
            }
        case "remove_track", "duplicate_track", "move_track":
            guard let id = UUID(uuidString: p["track"]?.string ?? ""), let t = project.tracks.firstIndex(where: { $0.id == id }) else {
                throw StepFailure(Said("step.set_track.such_track", "set_track: no such track."), reason: "not_found")
            }
            do {
                switch step.op {
                case "remove_track": try s.project.removeTrack(id)
                case "duplicate_track": s.made["track"] = try s.project.duplicateTrack(id, name: p["name"]?.string ?? project.tracks[t].name + " copy").uuidString
                default:
                    guard p["index"] != nil || p["by"] != nil else { throw StepFailure("move_track: give index or by.", reason: "bad_request") }
                    let to = p["index"]?.double.map { Int($0) } ?? (t + Int(p["by"]?.double ?? 0))
                    try s.project.moveTrack(id, to: to)
                }
            } catch let e as TrackEditError {
                throw StepFailure(step.op, wrapping: e, reason: e == .lastTrack ? "last_track" : "not_found")
            }
        case "set_track":
            guard let id = UUID(uuidString: p["track"]?.string ?? ""), let t = project.tracks.firstIndex(where: { $0.id == id }) else {
                throw StepFailure(Said("step.set_track.such_track", "set_track: no such track."), reason: "not_found")
            }
            if let l = p["locked"], case .bool(let v) = l { s.project.tracks[t].locked = v }
            if let g = p["gainDB"]?.double { s.project.tracks[t].gainDB = g }
            if let m = p["muted"], case .bool(let v) = m { s.project.tracks[t].isMuted = v }
            if let n = p["name"]?.string, !n.trimmingCharacters(in: .whitespaces).isEmpty { s.project.tracks[t].name = n }
            if p["pan"] != nil || p["output"] != nil {
                do { try s.project.setTrackRoute(id, pan: p["pan"]?.double, output: try route(p["output"], "set_track")) }
                catch let e as Mixer.Failure { throw StepFailure("set_track: " + (e.errorDescription ?? ""), reason: e.reason, keyed: e.keyed) }
            }
            var placed: Bool?
            if let v = p["placed"], case .bool(let b) = v { placed = b }
            if p["azimuth"] != nil || p["elevation"] != nil || p["width"] != nil || placed != nil {
                do { try s.project.setTrackPosition(id, azimuth: p["azimuth"]?.double, elevation: p["elevation"]?.double, width: p["width"]?.double, placed: placed) }
                catch let e as Mixer.Failure { throw StepFailure("set_track: " + (e.errorDescription ?? ""), reason: e.reason, keyed: e.keyed) }
            }
            if let f = p["field"]?.double {
                let order = Int(f)
                let used = Set(s.project.tracks[t].clips.map(\.sourceID))
                for i in s.project.sources.indices where used.contains(s.project.sources[i].id) {
                    if order == 0 { s.project.sources[i].fieldOrder = nil; continue }
                    guard s.project.sources[i].info.channels == (order + 1) * (order + 1) else {
                        throw StepFailure(Said("step.set_track.fieldSize", "set_track: a field of order %1$@ has %2$@ channels; %3$@ has %4$@.",
                                               "\(order)", "\((order + 1) * (order + 1))", s.project.sources[i].name, "\(s.project.sources[i].info.channels)"), reason: "bad_request")
                    }
                    s.project.sources[i].fieldOrder = order
                }
                if order == 0 { s.project.tracks[t].rotation = nil }
            }
            var turned: Bool?
            if let v = p["turned"], case .bool(let b) = v { turned = b }
            if turned == false { s.project.tracks[t].rotation = nil }
            if p["yaw"] != nil || p["pitch"] != nil || p["roll"] != nil {
                guard s.project.playsField(s.project.tracks[t]) else { throw StepFailure("set_track", wrapping: Automation.Failure.noField, reason: "no_field") }
                var r = s.project.tracks[t].rotation ?? FieldRotation()
                if let v = p["yaw"]?.double { r.yaw = v }
                if let v = p["pitch"]?.double { r.pitch = v }
                if let v = p["roll"]?.double { r.roll = v }
                s.project.tracks[t].rotation = r.isNone ? nil : r
            }
        case "add_bus":
            do {
                let out = try route(p["output"], "add_bus")
                try s.project.addBus(name: p["name"]?.string ?? "", output: out ?? nil)
                return ["bus": Double(s.project.buses.count), "buses": Double(s.project.buses.count)]
            } catch let e as Mixer.Failure { throw StepFailure("add_bus: " + (e.errorDescription ?? ""), reason: e.reason, keyed: e.keyed) }
        case "set_bus":
            guard let id = UUID(uuidString: p["bus"]?.string ?? "") else { throw StepFailure(Said("step.set_bus.such_bus", "set_bus: no such bus."), reason: "not_found") }
            var muted: Bool?
            if let m = p["muted"], case .bool(let v) = m { muted = v }
            do { try s.project.setBus(id, name: p["name"]?.string, gainDB: p["gainDB"]?.double, pan: p["pan"]?.double, muted: muted, output: try route(p["output"], "set_bus")) }
            catch let e as Mixer.Failure { throw StepFailure("set_bus: " + (e.errorDescription ?? ""), reason: e.reason, keyed: e.keyed) }
            var turned: Bool?
            if let v = p["turned"], case .bool(let b) = v { turned = b }
            if p["azimuth"] != nil || turned != nil {
                do { try s.project.setBusTurn(id, azimuth: p["azimuth"]?.double, turned: turned) }
                catch let e as Mixer.Failure { throw StepFailure("set_bus: " + (e.errorDescription ?? ""), reason: e.reason, keyed: e.keyed) }
            }
        case "set_send":
            guard let from = UUID(uuidString: p["from"]?.string ?? ""), let to = UUID(uuidString: p["to"]?.string ?? "") else {
                throw StepFailure(Said("step.set_send.from_track_bus_id", "set_send: from is a track or bus id and to is a bus id."), reason: "not_found")
            }
            var pre: Bool?, remove = false
            if let v = p["pre"], case .bool(let b) = v { pre = b }
            if let v = p["remove"], case .bool(let b) = v { remove = b }
            do { try s.project.setSend(from: from, to: to, gainDB: p["gainDB"]?.double, pre: pre, remove: remove) }
            catch let e as Mixer.Failure { throw StepFailure("set_send: " + (e.errorDescription ?? ""), reason: e.reason, keyed: e.keyed) }
        case "add_vca", "set_vca", "remove_vca":
            func strips(_ key: String) throws -> [UUID]? {
                guard let names = p[key]?.strings else { return nil }
                return try names.map { n in
                    guard let id = UUID(uuidString: n), project.tracks.contains(where: { $0.id == id }) || project.bus(id) != nil else {
                        throw StepFailure(Said("step.any.track_bus_id_2", "%1$@: no track or bus with id %2$@.", "\(step.op)", "\(n)"), reason: "not_found")
                    }
                    return id
                }
            }
            do {
                if step.op == "add_vca" {
                    let members = try strips("members") ?? []
                    let v = try s.project.addVCA(name: p["name"]?.string ?? "")
                    for m in members { try s.project.setMember(m, vca: v.id) }
                    s.made["vca"] = v.id.uuidString
                    return ["vcas": Double(s.project.vcas.count), "members": Double(members.count)]
                }
                guard let id = UUID(uuidString: p["vca"]?.string ?? ""), project.vca(id) != nil else {
                    throw StepFailure(Said("step.any.vca_id_2", "%1$@: no VCA with id %2$@.", "\(step.op)", "\(p["vca"]?.string ?? "")"), reason: "not_found")
                }
                if step.op == "remove_vca" { try s.project.removeVCA(id); return [:] }
                var muted: Bool?
                if let m = p["muted"], case .bool(let v) = m { muted = v }
                let members = try strips("members"), add = try strips("add"), remove = try strips("remove")
                guard p["name"] != nil || p["gainDB"] != nil || muted != nil || members != nil || add != nil || remove != nil else {
                    throw StepFailure(Said("step.set_vca.give_name_gaindb_muted", "set_vca: give name, gainDB, muted, members, add or remove."))
                }
                try s.project.setVCA(id, name: p["name"]?.string, gainDB: p["gainDB"]?.double, muted: muted)
                if let members {
                    for t in s.project.tracks where t.vca == id && !members.contains(t.id) { try s.project.setMember(t.id, vca: nil) }
                    for b in s.project.buses where b.vca == id && !members.contains(b.id) { try s.project.setMember(b.id, vca: nil) }
                    for m in members { try s.project.setMember(m, vca: id) }
                }
                for m in add ?? [] { try s.project.setMember(m, vca: id) }
                // Only what is in this group is taken out of it.
                for m in remove ?? [] where s.project.tracks.contains(where: { $0.id == m && $0.vca == id }) || s.project.buses.contains(where: { $0.id == m && $0.vca == id }) {
                    try s.project.setMember(m, vca: nil)
                }
                let count = s.project.tracks.filter { $0.vca == id }.count + s.project.buses.filter { $0.vca == id }.count
                return ["members": Double(count), "gainDB": s.project.vca(id)?.gainDB ?? 0]
            } catch let e as Mixer.Failure { throw StepFailure("\(step.op): " + (e.errorDescription ?? ""), reason: e.reason, keyed: e.keyed) }
        case "set_automation", "clear_automation":
            guard Operations.automationOn else { throw StepFailure(Said("step.any.build_has_automation", "%@: this build has no automation.", "\(step.op)"), reason: "not_available") }
            do { try check(step, against: project) }
            let strip = p["strip"]?.string == "master" ? Master.id : UUID(uuidString: p["strip"]?.string ?? "") ?? UUID()
            let range: ClosedRange<Frame>? = frames("start").flatMap { a in frames("end").map { a...max(a, $0) } }
            let param = AutomationLane.Param(rawValue: p["param"]?.string ?? "gain") ?? .gain
            let to = p["to"]?.string.flatMap(UUID.init(uuidString:))
            // A plugin's parameter: which plugin on the strip (by id or name), which parameter (by identifier
            // or name, kept as the plugin's own identifier), and the range the plugin gives it.
            var insert: UUID?, parameter: String?, values: ClosedRange<Double>?
            if param == .plugin {
                let on = s.project.inserts(of: strip), key = p["insert"]?.string ?? "", wanted = p["parameter"]?.string ?? ""
                let found = on.first { $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame } ?? {
                    let named = on.filter { $0.name.caseInsensitiveCompare(key) == .orderedSame }
                    return named.count == 1 ? named[0] : nil
                }()
                guard let found else { throw StepFailure(Said("step.any.insert_strip_has_plugin", "%1$@: \"insert\": that strip has no plugin %2$@ (or several by that name: use the id).", "\(step.op)", "\(key)"), reason: "not_found") }
                insert = found.id
                // A lane that is there already is found by its plugin and the parameter's name as it was written.
                if let lane = s.project.automation.first(where: { $0.strip == strip && $0.param == .plugin && $0.insert == found.id && $0.parameter?.caseInsensitiveCompare(wanted) == .orderedSame }) {
                    parameter = lane.parameter
                }
                // The plugin is asked when points are written (for the parameter's range), and whenever the
                // lane isn't found by the name given (which may be the parameter's display name).
                if parameter == nil || (step.op == "set_automation" && !(p["points"]?.pairs ?? []).isEmpty) {
                    let unit: any InsertUnit
                    do { unit = try InsertUnits.makeBlocking(found.plugin, channels: project.channels, sampleRate: project.sampleRate, state: found.state) }
                    catch { throw StepFailure(step.op, wrapping: error, reason: (error as? PluginError)?.reason ?? "plugin_failed") }
                    guard let known = unit.parameters.first(where: { $0.identifier == wanted }) ?? unit.parameters.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) else {
                        throw StepFailure(Said("step.any.parameter_2_has_parameter", "%1$@: \"parameter\": %2$@ has no parameter %3$@.", "\(step.op)", "\(found.name)", "\(wanted)"), reason: "not_found")
                    }
                    guard unit.address(of: known.identifier) != nil else {
                        throw StepFailure(Said("step.any.2_s_parameters_can", "%1$@: %2$@'s parameters can't be automated yet: for now only an Audio Unit's can.", "\(step.op)", "\(found.name)"), reason: "not_available")
                    }
                    parameter = known.identifier
                    values = known.min...known.max
                }
                if parameter == nil { parameter = wanted }
            }
            do {
                if step.op == "clear_automation" {
                    return ["removed": Double(try s.project.clearAutomation(strip: strip, param: param, to: to, insert: insert, parameter: parameter, range: range))]
                }
                var enabled: Bool?
                if let v = p["enabled"], case .bool(let b) = v { enabled = b }
                let points = (p["points"]?.pairs ?? []).map { AutomationPoint(frame: min(project.frames($0.0), project.length), value: $0.1) }
                guard !points.isEmpty || range != nil || enabled != nil else { throw StepFailure(Said("step.set_automation.points_were_given_take", "set_automation: no points were given. To take a lane away, use clear_automation.")) }
                if points.isEmpty, range == nil, let enabled {
                    // Only switching the lane on or off.
                    guard let lane = s.project.lane(strip: strip, param: param, to: to, insert: insert, parameter: parameter) else { throw StepFailure((enabled ? Said("step.set_automation.noLaneOn", "set_automation: there is no %@ lane on that strip to switch on.", param.rawValue) : Said("step.set_automation.noLaneOff", "set_automation: there is no %@ lane on that strip to switch off.", param.rawValue)), reason: "not_found") }
                    try s.project.setAutomation(strip: strip, param: param, to: to, insert: insert, parameter: parameter, points: lane.points, enabled: enabled)
                } else {
                    try s.project.setAutomation(strip: strip, param: param, to: to, insert: insert, parameter: parameter, values: values, points: points, range: range, enabled: enabled)
                }
                return ["points": Double(s.project.lane(strip: strip, param: param, to: to, insert: insert, parameter: parameter)?.points.count ?? 0)]
            } catch let e as Automation.Failure { throw StepFailure("\(step.op): " + (e.errorDescription ?? ""), reason: e.reason, keyed: e.keyed) }
        case "set_master":
            var limiter: MasterLimiter?? = nil
            var on: Bool?
            if let v = p["limiter"], case .bool(let b) = v { on = b }
            let values = p["ceiling"] != nil || p["release"] != nil || p["lookahead"] != nil
            if on == false {
                guard !values else { throw StepFailure(Said("step.set_master.limiter_false_takes_limiter", "set_master: limiter false takes the limiter off; ceiling, release and lookahead mean nothing then.")) }
                limiter = .some(nil)
            } else if on == true || values {
                // Values without `limiter` change a limiter that is on, and put one on that isn't.
                var l = project.master.limiter ?? MasterLimiter()
                if let c = p["ceiling"]?.double { l.ceilingDB = c }
                if let r = p["release"]?.double { l.releaseMs = r }
                if let a = p["lookahead"]?.double { l.lookaheadMs = a }
                limiter = .some(l)
            }
            guard p["gainDB"] != nil || limiter != nil else { throw StepFailure(Said("step.set_master.give_gaindb_limiter_value", "set_master: give gainDB, limiter, or a value for the limiter.")) }
            do { try s.project.setMaster(gainDB: p["gainDB"]?.double, limiter: limiter) }
            catch let e as Mixer.Failure { throw StepFailure("set_master: " + (e.errorDescription ?? ""), reason: e.reason, keyed: e.keyed) }
            if let l = s.project.master.limiter { return ["gainDB": s.project.master.gainDB, "limiter": 1, "ceilingDB": l.ceilingDB] }
            return ["gainDB": s.project.master.gainDB, "limiter": 0]
        case "remove_bus":
            guard let id = UUID(uuidString: p["bus"]?.string ?? "") else { throw StepFailure(Said("step.remove_bus.such_bus", "remove_bus: no such bus."), reason: "not_found") }
            do { try s.project.removeBus(id, reroute: try route(p["reroute"], "remove_bus")) }
            catch let e as Mixer.Failure { throw StepFailure("remove_bus: " + (e.errorDescription ?? ""), reason: e.reason, keyed: e.keyed) }
        case "set_group":
            guard let id = UUID(uuidString: p["group"]?.string ?? ""), project.tracks.contains(where: { $0.group == id }) else {
                throw StepFailure(Said("step.set_group.such_group", "set_group: no such group."), reason: "not_found")
            }
            for t in s.project.tracks.indices where s.project.tracks[t].group == id {
                s.project.tracks[t].gainDB = ((s.project.tracks[t].gainDB + (p["gainDB"]?.double ?? 0)) * 100).rounded() / 100
            }
        case "level_speakers":
            guard let pool = s.pool else { throw StepFailure(Said("step.level_speakers.app", "level_speakers needs the app.")) }
            let only = p["speakers"]?.strings.map { Set($0.compactMap(Int.init)) }
            if p["mode"]?.string == "dynamic" {
                guard let media = s.media else { throw StepFailure(Said("step.level_speakers.app", "level_speakers needs the app.")) }
                do {
                    let (q, r) = try s.project.levellingSpeakersDynamically(target: p["target"]?.double ?? -18, maxGain: p["maxGain"]?.double ?? 12,
                                                                            only: only, pool: pool, media: media)
                    s.project = q
                    return ["speakers": Double(r.speakers), "maxChangeDB": r.maxChangeDB, "spreadBeforeLU": r.spreadBefore, "spreadAfterLU": r.spreadAfter]
                } catch let e as LevelError {
                    throw StepFailure("level_speakers: \(e.localizedDescription)", reason: e.reason, keyed: e.keyed)
                }
            }
            do {
                let (q, report) = try s.project.levellingSpeakers(target: p["target"]?.double ?? -18, maxGain: p["maxGain"]?.double ?? 12,
                                                                  only: only, pool: pool)
                s.project = q
                return ["speakers": Double(report.gains.count), "maxChangeDB": (report.maxChangeDB * 100).rounded() / 100,
                        "limitedByMaxGain": report.limited ? 1 : 0]
            } catch let e as LevelError {
                throw StepFailure("level_speakers: \(e.localizedDescription)", reason: e.reason, keyed: e.keyed)
            }
        case "split_speakers":
            guard let t = p["track"]?.string, let id = UUID(uuidString: t) else { throw StepFailure(Said("step.split_speakers.track", "split_speakers: give the track's id or name.")) }
            do {
                let made = try s.project.splitSpeakers(track: id, keepOriginal: p["keepOriginal"].map { $0 == .bool(true) } ?? true)
                for (i, m) in made.enumerated() { s.made["track\(i + 1)"] = m.uuidString }
                return ["tracks": Double(made.count)]
            } catch let e as SplitSpeakersError {
                throw StepFailure(step.op, wrapping: e, reason: e.reason)
            }
        case "rename_speaker":
            do {
                try s.project.renameSpeaker(p["speaker"]?.string ?? "", to: p["name"]?.string ?? "")
            } catch SpeakerError.unknown(let k) {
                throw StepFailure(Said("step.rename_speaker.there_s_speaker_get", "rename_speaker: there's no speaker %@ (GET …/speakers lists them).", "\(k)"), reason: "not_found")
            }
        case "add_insert", "set_insert", "remove_insert":
            return try applyInsert(step, to: &s)
        case "loudness_preset":
            let r = try range(wholeIfNone: true); try checkInside(r)
            guard let preset = LoudnessPreset(rawValue: p["preset"]?.string ?? "") else { throw StepFailure(Said("step.loudness_preset.unknown_preset", "loudness_preset: unknown preset.")) }
            let limit = p["limit"].map { $0 == .bool(true) } ?? false
            if limit, s.pool == nil || s.media == nil { throw StepFailure(Said("step.loudness_preset.limit_needs_app", "loudness_preset with limit needs the app to render audio.")) }
            let matched: (Project, LoudnessMatch)?
            do { matched = try s.project.matching(preset, range: r, limit: limit, pool: s.pool, media: s.media, measure: measure) } catch let e as LimiterError {
                throw StepFailure("loudness_preset", wrapping: e, reason: "ceiling_not_met")
            }
            guard let (project, m) = matched else { throw StepFailure(Said("step.loudness_preset.range_silent_so_there", "loudness_preset: the range is silent, so there's nothing to match.")) }
            s.project = project
            func r2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
            var info = ["gainDB": m.gainDB, "integratedBefore": r2(m.integratedBefore), "integratedAfter": r2(m.integratedAfter),
                        "truePeakAfter": r2(m.truePeakAfter), "target": preset.integrated, "limitedByPeak": m.limitedByPeak ? 1 : 0, "limited": m.limited ? 1 : 0]
            if m.limited {
                // What reaching the target cost: how much the limiter took off, and the loudness range before and after.
                info["reductionMaxDB"] = r2(m.reductionMaxDB)
                info["limitedSeconds"] = r2(m.limitedSeconds)
                if let a = m.rangeBefore { info["rangeBeforeLU"] = r2(a) }
                if let b = m.rangeAfter { info["rangeAfterLU"] = r2(b) }
            }
            return info
        case "acx_match":
            let r = try range(wholeIfNone: true); try checkInside(r)
            let floor = s.pool.flatMap { Restoration.analyze(s.project, range: r, pool: $0).noiseFloor?.level }
            let matched: (Project, ACXMatch)?
            do { matched = try s.project.matchingACX(range: r, noiseFloorBefore: floor, pool: s.pool, media: s.media, measure: measure) } catch let e as LimiterError {
                throw StepFailure("acx_match", wrapping: e, reason: "ceiling_not_met")
            } catch let e as ACXMatchError {
                throw StepFailure(Said.of(e), reason: "needs_render")
            }
            guard let (project, m) = matched else { throw StepFailure(Said("step.acx_match.silent", "acx_match: the range is silent, so there's nothing to match.")) }
            s.project = project
            func r2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
            var info = ["unchanged": m.unchanged ? 1 : 0, "gainDB": m.gainDB, "rmsBefore": r2(m.rmsBefore), "rmsAfter": r2(m.rmsAfter),
                        "samplePeakAfter": r2(m.samplePeakAfter), "truePeakAfter": r2(m.truePeakAfter), "limited": m.limited ? 1 : 0,
                        "noiseFloorTooHigh": m.noiseFloorTooHigh ? 1 : 0]
            if m.limited { info["reductionMaxDB"] = r2(m.reductionMaxDB) }
            if let f = m.noiseFloorAfter { info["noiseFloorAfter"] = r2(f) }
            return info
        case "add_marker":
            let at = min(frames("at") ?? s.selection?.lowerBound ?? s.playhead, project.length)
            s.project.addMarker(at: at, length: frames("duration") ?? 0, name: p["name"]?.string ?? "Marker")
        case "set_layout":
            guard p["layout"] != nil || p["order"] != nil else {
                throw StepFailure(Said("step.set_layout.nothing", "set_layout: give \"layout\", \"order\" or both."))
            }
            if let name = p["order"]?.string {
                guard let order = ChannelOrder(rawValue: name) else {
                    throw StepFailure(Said("step.set_layout.order_one", "set_layout: \"order\" is one of %@.", ChannelOrder.allCases.map(\.rawValue).joined(separator: ", ")))
                }
                guard s.project.unmaskedOrder != nil else {
                    throw StepFailure(Said("step.set_layout.no_unmasked", "set_layout: no file in this document leaves its loudspeakers' order open (a 7.1 or 7.1.4 file without a channel mask or ADM); a file that names them is heard by them."))
                }
                s.project.setUnmaskedOrder(order)
            }
            if let name = p["layout"]?.string {
                guard let layout = ChannelLayout(rawValue: name) else {
                    throw StepFailure(Said("step.set_layout.layout_one", "set_layout: \"layout\" is one of %@.", "\(ChannelLayout.allCases.map(\.rawValue).joined(separator: ", "))"))
                }
                s.project.channels = layout.channels
                // A document made Ambisonics says what its files of that size are: sound fields of its order.
                if let order = layout.ambisonicOrder { s.project.markFields(order: order) }
            }
            return ["channels": Double(s.project.channels), "fields": Double(s.project.sources.filter { $0.fieldOrder != nil }.count),
                    "unmaskedFiles": Double(s.project.sources.filter(\.needsOrder).count)]
        case "set_timecode":
            let named = p["rate"]?.string ?? ""
            if named == "none" {
                guard p["start"] == nil else { throw StepFailure(Said("step.set_timecode.start_means_nothing_rate", "set_timecode: \"start\" means nothing with rate none.")) }
                s.project.timecode = nil
                return [:]
            }
            guard let rate = Timecode.Rate(rawValue: named) else { throw StepFailure(Said("step.set_timecode.rate_one_none", "set_timecode: \"rate\" is one of %@, or none.", "\(Timecode.Rate.allCases.map(\.rawValue).joined(separator: ", "))")) }
            var start = 0
            if let text = p["start"]?.string {
                guard let t = Timecode(text, rate: rate) else {
                    throw StepFailure(rate.dropsFrames
                        ? Said("step.set_timecode.start_drop", "set_timecode: \"start\": %1$@ is not a timecode at %2$@ (hh:mm:ss:ff, each two digits; at this rate the first %3$@ frame numbers of a minute that isn't a tenth minute don't exist).", "\(text)", rate.rawValue, "\(rate.base / 15)")
                        : Said("step.set_timecode.start_bad", "set_timecode: \"start\": %1$@ is not a timecode at %2$@ (hh:mm:ss:ff, each two digits).", "\(text)", rate.rawValue))
                }
                start = t.pictureFrames
            }
            s.project.timecode = TimecodeSettings(rate: rate, startFrames: start)
            return ["startFrames": Double(start)]
        case "split":
            let at = frames("at") ?? s.playhead
            let ids = p["tracks"]?.strings.map { Set($0.compactMap(UUID.init(uuidString:))) }
            s.project.split(at: at, onTracks: ids)
        case "set_marker":
            guard let id = p["marker"]?.string.flatMap(UUID.init(uuidString:)) else { throw StepFailure(Said("step.set_marker.id", "set_marker: \"marker\" must be a marker id.")) }
            try s.project.setMarker(id, position: frames("at"), name: p["name"]?.string, length: frames("duration"))
        case "move_clip":
            let one = p["clip"]?.string.flatMap(UUID.init(uuidString:))
            let many = (p["clips"]?.strings ?? []).compactMap(UUID.init(uuidString:))
            let ids = Set(many + (one.map { [$0] } ?? []))
            guard !ids.isEmpty else { throw StepFailure(Said("step.move_clip.ids", "move_clip: give \"clip\" or \"clips\" (clip ids).")) }
            let delta: Frame
            if let at = frames("at") {
                guard ids.count == 1, let id = ids.first, let c = s.project.tracks.flatMap(\.clips).first(where: { $0.id == id }) else {
                    throw StepFailure(Said("step.move_clip.at", "move_clip: \"at\" moves one clip; use \"by\" for several."))
                }
                delta = at - c.start
            } else if let by = p["by"]?.double {
                delta = Frame((by * s.project.sampleRate).rounded())
            } else {
                throw StepFailure(Said("step.move_clip.where", "move_clip: give \"at\" (seconds) or \"by\" (seconds)."))
            }
            do { try s.project.moveClips(ids, by: delta) } catch let e as ClipEditError {
                throw StepFailure(Said.of(e), reason: e == .overlaps ? "overlaps" : e == .beforeStart ? "before_start" : "no_clip")
            }
        case "set_take":
            guard let track = p["track"]?.string.flatMap(UUID.init(uuidString:)), let group = p["group"]?.string.flatMap(UUID.init(uuidString:)),
                  let take = p["take"]?.string.flatMap(UUID.init(uuidString:)) else {
                throw StepFailure(Said("step.set_take.ids", "set_take: \"track\", \"group\" and \"take\" must be ids (a track's takes list them)."))
            }
            do { try s.project.chooseTake(take, of: group, onTrack: track) } catch let e as TakeError {
                throw StepFailure(Said.of(e), reason: e.reason)
            }
        case "set_clip":
            guard let id = p["clip"]?.string.flatMap(UUID.init(uuidString:)) else { throw StepFailure(Said("step.set_clip.id", "set_clip: \"clip\" must be a clip id.")) }
            let shape = p["shape"]?.string.map { $0 == "linear" ? FadeShape.linear : .equalPower }
            try s.project.setClip(id, start: frames("start"), end: frames("end"), fadeIn: frames("fadeIn"), fadeOut: frames("fadeOut"), shape: shape, gainDB: p["gainDB"]?.double)
        case "remove_marker":
            if let id = p["marker"]?.string {
                guard let uuid = UUID(uuidString: id) else { throw StepFailure(Said("step.set_marker.id", "set_marker: \"marker\" must be a marker id.")) }
                try s.project.removeMarker(uuid)
                break
            }
            let name = p["name"]?.string ?? ""
            let before = s.project.markers.count
            s.project.markers.removeAll { $0.name == name }
            guard s.project.markers.count < before else { throw StepFailure(Said("step.remove_marker.marker_named", "remove_marker: no marker named \"%@\".", "\(name)")) }
        case "delete_words":
            let bridge = frames("bridge") ?? 0
            let ids: Set<UUID>
            if let list = p["words"]?.strings {
                guard p["text"] == nil else { throw StepFailure(Said("step.delete_words.give_words_text_both", "delete_words: give words or text, not both.")) }
                var set = Set<UUID>()
                let known = Set(project.placedWords().map(\.word.id))
                for w in list {
                    guard let id = UUID(uuidString: w), known.contains(id) else {
                        throw StepFailure(Said("step.delete_words.word_id_plays_document", "delete_words: no word with id %@ plays in the document.", "\(w)"), reason: "not_found")
                    }
                    set.insert(id)
                }
                ids = set
            } else if let text = p["text"]?.string {
                let matches = project.findPhrase(text)
                guard !matches.isEmpty else { throw StepFailure(Said("step.delete_words.isn_t_transcript", "delete_words: \"%@\" isn't in the transcript.", "\(text)"), reason: "not_found", details: ["matches": 0]) }
                if p["all"].map({ $0 == .bool(true) }) == true {
                    ids = Set(matches.flatMap { $0 })
                } else if let n = p["occurrence"]?.double {
                    guard n == n.rounded(), n >= 1, Int(n) <= matches.count else {
                        throw StepFailure(Said("step.delete_words.occurrence_1", "delete_words: occurrence must be 1–%@.", "\(matches.count)"), reason: "not_found", details: ["matches": Double(matches.count)])
                    }
                    ids = Set(matches[Int(n) - 1])
                } else {
                    guard matches.count == 1 else {
                        throw StepFailure(Said("step.delete_words.1_occurs_2_times", "delete_words: \"%1$@\" occurs %2$@ times. Pass occurrence (1–%3$@), all: true, or word ids.", "\(text)", "\(matches.count)", "\(matches.count)"),
                                          reason: "ambiguous", details: ["matches": Double(matches.count)])
                    }
                    ids = Set(matches[0])
                }
            } else {
                throw StepFailure(Said("step.delete_words.words_ids_text", "delete_words needs words (ids) or text."))
            }
            guard !project.areTextOnly(ids) else { throw StepFailure("delete_words: " + SourceTranscript.textOnlyReason, reason: "text_only", keyed: SourceTranscript.textOnly.keyed) }
            let removed = project.ranges(ofWords: ids, bridge: bridge).reduce(Frame(0)) { $0 + Frame($1.count) }
            try s.project.deleteWords(ids, bridge: bridge)
            s.selection = nil
            return ["words": Double(ids.count), "removedSeconds": (project.seconds(removed) * 1_000).rounded() / 1_000]
        case "correct_word":
            guard let id = UUID(uuidString: p["word"]?.string ?? "") else { throw StepFailure(Said("step.correct_word.word_word_id", "correct_word: word must be a word id."), reason: "not_found") }
            let text = (p["text"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw StepFailure(Said("step.correct_word.text_can_t_empty", "correct_word: text can't be empty. Use delete_words to remove a word.")) }
            do { try s.project.correctWord(id, to: text) } catch {
                throw StepFailure(Said("step.correct_word.word_id", "correct_word: no word with id %@.", "\(id.uuidString)"), reason: "not_found")
            }
        case "limit":
            guard let pool = s.pool, let media = s.media else { throw StepFailure(Said("step.limit.app_render_audio", "limit needs the app to render audio.")) }
            let r = try range(wholeIfNone: true); try checkInside(r)
            var tracks: Set<UUID>?
            if let ids = p["tracks"]?.strings {
                var set = Set<UUID>()
                for t in ids {
                    guard let id = UUID(uuidString: t), project.tracks.contains(where: { $0.id == id }) else {
                        throw StepFailure(Said("step.limit.track_id", "limit: no track with id %@.", "\(t)"), reason: "not_found")
                    }
                    set.insert(id)
                }
                tracks = set
            }
            let settings = Limiter(ceilingDB: p["ceiling"]?.double ?? -1, releaseMs: p["release"]?.double ?? 100, lookaheadMs: p["lookahead"]?.double ?? 5)
            do {
                let (limited, report) = try s.project.limiting(settings, range: r, tracks: tracks, pool: pool, media: media)
                s.project = limited
                func r2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
                // The limiter adds no delay: the new files lie sample for sample where the old audio was.
                return ["ceiling": report.ceilingDB, "truePeakBefore": r2(report.truePeakBeforeDB), "truePeakAfter": r2(report.truePeakAfterDB),
                        "reductionMaxDB": r2(report.reductionMaxDB), "limitedSeconds": r2(report.limitedSeconds), "tracks": Double(report.tracks),
                        "latencySamples": 0, "beforePlugins": report.beforePlugins ? 1 : 0]
            } catch let e as LimiterError {
                switch e {
                case .nothingToDo: throw StepFailure("limit", wrapping: e, reason: "nothing_to_do")
                case .badValue: throw StepFailure("limit", wrapping: e, reason: "bad_request")
                case .ceilingNotMet: throw StepFailure("limit", wrapping: e, reason: "ceiling_not_met")
                }
            }
        case "echo":
            guard let pool = s.pool, let media = s.media else { throw StepFailure(Said("step.echo.app_render_audio", "echo needs the app to render audio.")) }
            let r = try range(wholeIfNone: true); try checkInside(r)
            var tracks: Set<UUID>?
            if let ids = p["tracks"]?.strings {
                var set = Set<UUID>()
                for t in ids {
                    guard let id = UUID(uuidString: t), project.tracks.contains(where: { $0.id == id }) else {
                        throw StepFailure(Said("step.echo.track_id", "echo: no track with id %@.", "\(t)"), reason: "not_found")
                    }
                    set.insert(id)
                }
                tracks = set
            }
            let e = Echo(delay: p["delay"]?.double ?? 0.3, feedback: p["feedback"]?.double ?? 0.4, mix: p["mix"]?.double ?? 0.35)
            let tail = p["tail"].map { $0 == .bool(true) } ?? false
            s.project = try s.project.applyingEcho(e, range: r, tracks: tracks, tail: tail, pool: pool, media: media)
            return ["tailSeconds": tail ? (project.seconds(e.tail(sampleRate: project.sampleRate)) * 1_000).rounded() / 1_000 : 0]
        case "detect_tempo":
            guard let pool = s.pool else { throw StepFailure(Said("step.detect_tempo.app", "detect_tempo needs the app.")) }
            let multiply = p["multiply"]?.double ?? 1
            guard [0.5, 1, 2].contains(multiply) else { throw StepFailure(Said("step.detect_tempo.multiply_0_5_1", "detect_tempo: multiply must be 0.5, 1 or 2.")) }
            guard !(p["multiply"] != nil && p["bpm"] != nil) else { throw StepFailure(Said("step.detect_tempo.give_multiply_bpm_both", "detect_tempo: give multiply or bpm, not both.")) }
            var only: Set<UUID>?
            if let raw = p["tracks"]?.strings {
                only = []
                for r in raw {
                    guard let id = UUID(uuidString: r), project.tracks.contains(where: { $0.id == id }) else { throw StepFailure(Said("step.detect_tempo.track_id", "detect_tempo: no track with id %@.", "\(r)"), reason: "not_found") }
                    only?.insert(id)
                }
            }
            let r = try range(wholeIfNone: true)
            do {
                let e = try Rhythm.estimate(project, range: r, tracks: only, pool: pool, multiply: multiply, bpm: p["bpm"]?.double)
                let first = project.seconds(r.lowerBound) + e.firstBeat
                s.project.tempo = try Rhythm.tempoMap(bpm: e.bpm, firstBeat: first, sampleRate: project.sampleRate, meter: project.tempo.meter(at: 0))
                return ["bpm": e.bpm, "firstBeat": (first * 1_000).rounded() / 1_000, "pulse": e.pulse, "beats": Double(e.beats.count)]
            } catch let e as Rhythm.Failure {
                throw StepFailure("detect_tempo: \(e.localizedDescription)", reason: e.reason, keyed: e.keyed)
            }
        case "set_tempo":
            var meter: Meter?
            switch (p["beats"]?.double, p["unit"]?.double) {
            case (nil, nil): meter = nil
            case let (b?, u?):
                guard b == b.rounded(), u == u.rounded(), abs(b) < 1_000, abs(u) < 1_000 else {
                    throw StepFailure(Said("step.set_tempo.beats_unit_whole_numbers", "set_tempo: beats and unit must be whole numbers."))
                }
                meter = Meter(Int(b), Int(u))
            default: throw StepFailure(Said("step.set_tempo.give_both_beats_unit", "set_tempo: give both beats and unit, or neither."))
            }
            do {
                try s.project.tempo.set(bpm: p["bpm"]?.double ?? 0, meter: meter, at: frames("at") ?? 0)
            } catch { throw StepFailure("set_tempo", wrapping: error) }
        case "remove_tempo_change":
            let at = frames("at") ?? 0
            do { try s.project.tempo.removeChange(at: at) } catch {
                let list = s.project.tempo.changes.dropFirst().map { String(format: "%.6g", project.seconds($0.position)) }
                if list.isEmpty { throw StepFailure("remove_tempo_change", wrapping: error) }
                let said = Said("step.remove_tempo_change.where", "remove_tempo_change: %1$@ Changes are at: %2$@ s.", error.localizedDescription, list.joined(separator: ", "))
                // The window says the reason by its own key; the list of places is for an agent.
                throw StepFailure(said.text, keyed: (error as? KeyedFailure)?.keyed ?? said.keyed)
            }
        default:
            throw StepFailure(Said("step.step.unknown_op", "Unknown op \"%@\".", "\(step.op)"))
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
        // `track` is the id of a track, or of a bus, or "master": plugins sit on any of them.
        let named = p["track"]?.string ?? ""
        let id = named.lowercased() == "master" ? Master.id : UUID(uuidString: named)
        guard let id, let current = project.strip(id)?.inserts else {
            throw StepFailure(Said("step.any.track_bus_id_2", "%1$@: no track or bus with id %2$@.", "\(step.op)", "\(named)"), reason: "not_found")
        }
        func put(_ list: [Insert], _ s: inout EditState) { s.project.setInserts(list, on: id) }
        func failure(_ e: Error) -> StepFailure {
            if let e = e as? PluginError { return StepFailure("\(step.op): \(e.localizedDescription)", reason: e.reason, keyed: e.keyed) }
            return StepFailure(step.op, wrapping: e, reason: "plugin_failed")
        }
        func latencyMs(_ i: any InsertUnit) -> Double { (Double(i.latency) / project.sampleRate * 100_000).rounded() / 100 }
        func insertIndex() throws -> Int {
            let key = p["insert"]?.string ?? ""
            let inserts = current
            if let u = UUID(uuidString: key), let i = inserts.firstIndex(where: { $0.id == u }) { return i }
            let named = inserts.indices.filter { inserts[$0].name.caseInsensitiveCompare(key) == .orderedSame }
            if named.count == 1 { return named[0] }
            if named.count > 1 { throw StepFailure(Said("step.any.2_plugins_track_called", "%1$@: %2$@ plugins on the track are called %3$@; use the id.", "\(step.op)", "\(named.count)", "\(key)"), reason: "ambiguous", details: ["matches": Double(named.count)]) }
            throw StepFailure(Said("step.any.track_has_plugin_2", "%1$@: the track has no plugin %2$@.", "\(step.op)", "\(key)"), reason: "not_found")
        }
        switch step.op {
        case "add_insert":
            let name = p["plugin"]?.string ?? ""
            guard let info = PluginCatalog.find(name) else {
                if let why = PluginCatalog.whyUnavailable?(name) { throw StepFailure(Said("step.add_insert.failed", "add_insert: %@", "\(why)"), reason: "plugin_blocked") }
                throw StepFailure(Said("step.add_insert.effect_installed_get_api", "add_insert: no effect %@ is installed (GET /api/v1/plugins lists them).", "\(name)"), reason: "plugin_not_found")
            }
            do {
                let unit = try InsertUnits.makeBlocking(info.id, channels: project.channels, sampleRate: project.sampleRate)
                var insert = Insert(plugin: info.id, name: info.name)
                if let preset = p["preset"]?.string {
                    try unit.loadPreset(preset)
                    insert.state = unit.captureState()
                }
                let at = min(current.count, p["position"]?.double.map { Int($0) } ?? .max)
                var list = current
                list.insert(insert, at: at)
                put(list, &s)
                s.made["insert"] = insert.id.uuidString
                return ["latencyMs": latencyMs(unit), "position": Double(at)]
            } catch let f as StepFailure { throw f } catch { throw failure(error) }
        case "set_insert":
            let i = try insertIndex()
            var insert = current[i]
            if let b = p["bypass"], case .bool(let v) = b { insert.bypass = v }
            if p["value"] != nil, p["parameter"] == nil { throw StepFailure(Said("step.set_insert.value_needs_parameter", "set_insert: value needs parameter.")) }
            if p["parameter"] != nil, p["value"] == nil { throw StepFailure(Said("step.set_insert.parameter_needs_value", "set_insert: parameter needs value.")) }
            var info: [String: Double] = [:]
            if p["preset"] != nil || p["parameter"] != nil {
                do {
                    let unit = try InsertUnits.makeBlocking(insert.plugin, channels: project.channels, sampleRate: project.sampleRate, state: insert.state)
                    if let preset = p["preset"]?.string { try unit.loadPreset(preset) }
                    if let name = p["parameter"]?.string, let v = p["value"]?.double { try unit.set(name, to: v) }
                    insert.state = unit.captureState()
                    info["latencyMs"] = latencyMs(unit)
                } catch { throw failure(error) }
            }
            var list = current
            list[i] = insert
            put(list, &s)
            if let named = p["key"]?.string {
                guard Operations.sidechainOn else { throw StepFailure(Said("step.set_insert.build_has_sidechain_keys", "set_insert: this build has no sidechain keys."), reason: "not_available") }
                do {
                    if named.lowercased() == "none" {
                        try s.project.setKey(strip: id, insert: insert.id, key: nil)
                    } else {
                        guard let source = UUID(uuidString: named) else { throw StepFailure(Said("step.set_insert.key_id_track_bus", "set_insert: key is the id of a track or bus, or \"none\"."), reason: "not_found") }
                        // Asked of the plugin itself: does it have the input, and can it be fed here?
                        let unit: any InsertUnit
                        do { unit = try InsertUnits.makeBlocking(insert.plugin, channels: project.channels, sampleRate: project.sampleRate, state: nil) } catch { throw failure(error) }
                        guard unit.hasKeyInput else {
                            let why = unit.keyRefusal ?? Said("plugin.key.none", "%@ has no sidechain input, so it can't be given a key.", insert.name)
                            throw StepFailure("set_insert: " + why.text, reason: "no_key_input", keyed: why.keyed)
                        }
                        try s.project.setKey(strip: id, insert: insert.id, key: source)
                    }
                } catch let e as Mixer.Failure { throw StepFailure("set_insert: " + (e.errorDescription ?? ""), reason: e.reason, keyed: e.keyed) }
            }
            return info
        default:
            let i = try insertIndex()
            var list = current
            list.remove(at: i)
            put(list, &s)
            return [:]
        }
    }
}

extension Double {
    /// The number as an agent reads it, the same on every Mac: no grouping, a point for the decimals
    /// (`formatted()` writes 9 999 and 25,08 on a Swedish one).
    var plain: String { self == rounded() && abs(self) < 1e15 ? String(Int64(self)) : String((self * 1_000_000).rounded() / 1_000_000) }
}
