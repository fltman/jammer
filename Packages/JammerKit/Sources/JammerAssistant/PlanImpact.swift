import Foundation
import JammerAgent
import JammerCore

/// What a plan will do, in numbers worked out from its steps (simulated on a copy), not
/// from the model's words, plus warnings when it removes a lot or doesn't match the request.
public struct PlanImpact: Sendable, Equatable {
    public var lines: [String]
    public var removedSeconds: Double
    public var fractionRemoved: Double
    public var warnings: [String]

    public var isAlarming: Bool { !warnings.isEmpty }

    static func clock(_ s: Double) -> String {
        let t = max(0, s)
        let m = Int(t) / 60
        let sec = t - Double(m * 60)
        return m > 0 ? String(format: "%d:%04.1f", m, sec) : String(format: "%.1f s", sec)
    }

    /// Verbs that ask for audio to go.
    static let removalWords = ["ta bort", "radera", "klipp", "rensa", "korta", "kapa", "cut", "delete", "remove", "trim", "crop", "shorten",
                               "get rid", "clean up", "strip", "drop", "ehm", "öh", "filler", "fyllnad", "tystnad", "paus", "silenc", "pause"]

    public static func compute(_ plan: AssistantPlan, goal: String, state: EditState) -> PlanImpact {
        let p0 = state.project
        let length0 = p0.length
        let sr = p0.sampleRate
        func secs(_ f: Frame) -> Double { Double(f) / sr }
        func where_(_ r: Range<Frame>, _ len: Frame) -> String {
            if r.lowerBound <= 0, r.upperBound >= len { return "the whole document" }
            if r.lowerBound <= 0 { return "at the start" }
            if r.upperBound >= len { return "at the end" }
            return "at \(clock(secs(r.lowerBound)))–\(clock(secs(r.upperBound)))"
        }
        var scratch = state
        var lines: [String] = []
        var removedTotal: Frame = 0
        let measure: StepRunner.Measure = { p, r in LoudnessMeter.measure(PlanCompiler.compile(p, pool: state.pool ?? SourcePool()), r) }
        for s in plan.steps {
            let before = scratch.project
            let len = before.length
            func range(_ wholeIfNone: Bool) -> Range<Frame>? {
                if let a = s.params["start"]?.double, let b = s.params["end"]?.double { return before.frames(a)..<min(len, before.frames(b)) }
                return scratch.selection ?? (wholeIfNone ? 0..<len : nil)
            }
            switch s.op {
            case "transcribe": lines.append("Transcribes the document.")
            case "measure_loudness", "analyze_restoration": lines.append("Measures; changes nothing.")
            case "restore":
                let r = range(true) ?? 0..<len
                lines.append("Repairs (\(s.params["kind"]?.string ?? "?")) \(clock(secs(Frame(r.count)))) \(where_(r, len)); the original stays one undo away.")
            default:
                // Steps and macros: run them on the copy and compare.
                let concrete: [Step]
                do {
                    var named = s
                    named.params = try StepRunner.resolveStrips(Step(op: s.op, params: s.params), in: scratch.project).params
                    concrete = try MacroExpander.expand([named], state: scratch)
                } catch {
                    // Most failures already begin with the step's name ("duck: …"); it isn't said twice.
                    let said = error.localizedDescription
                    lines.append(said.hasPrefix("\(s.op):") ? said : "\(s.op): \(said)"); continue
                }
                for c in concrete { _ = StepRunner.run([c], on: &scratch, measure: measure) }
                let after = scratch.project
                let removed = len - after.length
                switch s.op {
                case "delete", "cut", "crop":
                    let r = s.op == "crop" ? nil : range(false)
                    removedTotal += max(0, removed)
                    lines.append("Deletes \(clock(secs(removed))) of \(clock(secs(len)))" + (r.map { " " + where_($0, len) } ?? "") + ".")
                case "remove_fillers", "delete_words":
                    let n = concrete.first?.params["words"]?.strings?.count ?? 0
                    removedTotal += max(0, removed)
                    lines.append("Removes \(n) word\(n == 1 ? "" : "s") (\(clock(secs(removed)))).")
                case "remove_silences":
                    removedTotal += max(0, removed)
                    lines.append("Shortens \(concrete.count) pause\(concrete.count == 1 ? "" : "s") (\(clock(secs(removed))) in all).")
                case "silence":
                    if let r = range(false) { lines.append("Silences \(clock(secs(Frame(r.count)))) \(where_(r, len)) without moving anything.") }
                case "fade_in", "fade_out":
                    if let r = range(false) { lines.append("\(s.op == "fade_in" ? "Fades in" : "Fades out") over \(clock(secs(Frame(r.count)))) \(where_(r, len)).") }
                case "gain":
                    let r = range(true) ?? 0..<len
                    lines.append(String(format: "Changes the level by %+.1f dB on ", s.params["db"]?.double ?? 0) + "\(clock(secs(Frame(r.count)))) \(where_(r, len)).")
                case "normalize":
                    lines.append("Sets the \(s.params["target"]?.string ?? "loudness") to \(s.params["level"]?.double.map { String(format: "%g", $0) } ?? "?").")
                case "loudness_preset":
                    let preset = LoudnessPreset(rawValue: s.params["preset"]?.string ?? "")
                    lines.append("Sets the loudness for \(preset?.title ?? "the preset"); if the peaks don't allow the full target, it stops at the ceiling and says so.")
                case "echo":
                    lines.append("Adds an echo" + (removed < 0 ? " and makes the document \(clock(secs(-removed))) longer." : "."))
                default:
                    if removed > 0 { removedTotal += removed; lines.append("\(s.op): removes \(clock(secs(removed))).") }
                    else { lines.append(Operations.named(s.op)?.title ?? s.op) }
                }
            }
        }
        let fraction = length0 > 0 ? Double(removedTotal) / Double(length0) : 0
        var warnings: [String] = []
        if fraction > 0.2 {
            warnings.append(String(format: "This removes %.0f %% of the document.", fraction * 100))
        }
        let g = " " + goal.lowercased() + " "
        if removedTotal > 0, !removalWords.contains(where: { g.contains($0) }) {
            warnings.append("Your request doesn't ask to remove anything, but this plan deletes audio.")
        }
        return PlanImpact(lines: lines, removedSeconds: secs(removedTotal), fractionRemoved: fraction, warnings: warnings)
    }
}
