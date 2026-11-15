import Foundation
import JammerCore

/// One editing operation, as the menu, the command palette, App Intents and the
/// agent API all see it. The guide and `GET /api/v1/operations` are generated
/// from this list, so they can't drift from what the app actually does.
public struct OperationSpec: Sendable, Identifiable {
    public struct Param: Sendable {
        public enum Kind: String, Sendable { case seconds, number, string, boolean }
        public var name: String
        public var kind: Kind
        public var description: String
        public var required: Bool
        public var options: [String]?

        public init(_ name: String, _ kind: Kind, _ description: String, required: Bool = false, options: [String]? = nil) {
            self.name = name
            self.kind = kind
            self.description = description
            self.required = required
            self.options = options
        }
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

    public var id: String { name }

    init(_ name: String, _ title: String, _ description: String, params: [Param] = [], paid: Bool = false, edits: Bool = true) {
        self.name = name
        self.title = title
        self.description = description
        self.params = params
        self.paid = paid
        self.edits = edits
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
    case null

    public init?(_ any: Any) {
        if let n = any as? NSNumber {
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        } else if let s = any as? String {
            self = .string(s)
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
}

/// Everything a step can change: the document and the session around it.
public struct EditState: Sendable {
    public var project: Project
    public var selection: Range<Frame>?
    public var playhead: Frame
    public var clipboard: ClipboardContent?

    public init(project: Project, selection: Range<Frame>? = nil, playhead: Frame = 0, clipboard: ClipboardContent? = nil) {
        self.project = project
        self.selection = selection
        self.playhead = playhead
        self.clipboard = clipboard
    }
}

public struct StepResult: Sendable, Equatable {
    public enum Status: String, Sendable { case done, failed, skipped }
    public var op: String
    public var status: Status
    public var error: String?
    /// Extra facts the step found (e.g. the gain normalize applied).
    public var info: [String: Double] = [:]
}

public struct StepFailure: Error, LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
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
                results.append(StepResult(op: step.op, status: .failed, error: error.localizedDescription))
                failed = true
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
            case .string:
                guard let s = value.string else { throw StepFailure("\(step.op): \"\(key)\" must be a string.") }
                if let options = p.options, !options.contains(s) {
                    throw StepFailure("\(step.op): \"\(key)\" must be one of \(options.joined(separator: ", ")).")
                }
            case .boolean:
                guard case .bool = value else { throw StepFailure("\(step.op): \"\(key)\" must be true or false.") }
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
        default:
            throw StepFailure("Unknown op \"\(step.op)\".")
        }
        return [:]
    }
}
