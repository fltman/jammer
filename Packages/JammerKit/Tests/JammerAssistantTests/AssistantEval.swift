import Foundation
import JammerAgent
import JammerCore
import Testing
@testable import JammerAssistant

/// How well a planner picks the right actions on a fixed set of requests.
/// `JAMMER_ASSISTANT_EVAL=1` runs it against the on-device model.
@Suite("Assistant evaluation", .serialized, .enabled(if: ProcessInfo.processInfo.environment["JAMMER_ASSISTANT_EVAL"] != nil))
struct AssistantEval {
    struct Case {
        var goal: String
        var ops: [String]
        /// Param checks on the first step with that op: name → expected value as text.
        var params: [String: [String: String]] = [:]
    }

    static func cases(track2: String) -> [Case] { [
        Case(goal: "normalisera till −16 LUFS", ops: ["normalize"], params: ["normalize": ["target": "loudness", "level": "-16"]]),
        Case(goal: "ta bort alla ehm", ops: ["remove_fillers"]),
        Case(goal: "ta bort tystnader längre än en sekund", ops: ["remove_silences"], params: ["remove_silences": ["min_length": "1"]]),
        Case(goal: "ta bort alla ehm och tystnader längre än en sekund", ops: ["remove_fillers", "remove_silences"]),
        Case(goal: "ta bort brummet på talare 2", ops: ["restore"], params: ["restore": ["kind": "dehum", "tracks": track2]]),
        Case(goal: "sänk volymen med 3 dB", ops: ["gain"], params: ["gain": ["db": "-3"]]),
        Case(goal: "fade in the first two seconds", ops: ["fade_in"], params: ["fade_in": ["start": "0", "end": "2"]]),
        Case(goal: "add an echo", ops: ["echo"]),
        Case(goal: "remove the clicks", ops: ["restore"], params: ["restore": ["kind": "declick"]]),
        Case(goal: "transcribe this in Swedish", ops: ["transcribe"], params: ["transcribe": ["language": "sv-SE"]]),
        Case(goal: "cut from 10 to 15 seconds", ops: ["delete"], params: ["delete": ["start": "10", "end": "15"]]),
        Case(goal: "lägg till en markör som heter Intro vid 5 sekunder", ops: ["add_marker"], params: ["add_marker": ["name": "Intro", "at": "5"]]),
        Case(goal: "reduce the background noise", ops: ["restore"], params: ["restore": ["kind": "denoise"]]),
        Case(goal: "hur högt är det, i LUFS?", ops: ["measure_loudness"]),
    ] }

    static func text(_ v: JSONValue?) -> String {
        switch v {
        case .number(let d): d == d.rounded() ? String(Int(d)) : String(d)
        case .string(let s): s
        case .bool(let b): String(b)
        case .array(let a): a.map { text($0) }.joined(separator: ",")
        default: ""
        }
    }

    @Test("On-device model picks the right actions")
    func onDevice() async throws {
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: 48_000 * 60, chunks: [], bext: nil, ixml: nil, markers: [])
        var p = Project(source: SourceRef(name: "Anna", path: "/dev/null", info: info))
        let b = SourceRef(name: "Erik", path: "/dev/null", info: info)
        p.sources.append(b)
        p.tracks.append(Track(name: "Erik", clips: [Clip(sourceID: b.id, start: 0, length: 48_000 * 60)]))
        let context = AssistantContext(project: p, selection: nil, playhead: 0)
        let planner = OnDevicePlanner()
        let actions = AssistantCatalog.actions
        var opsRight = 0, paramsRight = 0, paramsTotal = 0
        var rows: [String] = []
        var seconds = 0.0
        for c in Self.cases(track2: p.tracks[1].id.uuidString) {
            let t0 = ContinuousClock.now
            let plan: AssistantPlan
            do { plan = try await planner.plan(goal: c.goal, context: context, history: [], actions: actions) } catch {
                rows.append("| \(c.goal) | \(c.ops.joined(separator: ", ")) | error: \(error.localizedDescription) | ✗ |")
                continue
            }
            let d = ContinuousClock.now - t0
            seconds += Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
            let got = plan.steps.map(\.op)
            let ok = got == c.ops
            if ok { opsRight += 1 }
            var paramNotes: [String] = []
            for (op, expected) in c.params {
                guard let step = plan.steps.first(where: { $0.op == op }) else { paramsTotal += expected.count; continue }
                for (k, v) in expected {
                    paramsTotal += 1
                    let have = Self.text(step.params[k])
                    if have.caseInsensitiveCompare(v) == .orderedSame { paramsRight += 1 } else { paramNotes.append("\(k)=\(have.isEmpty ? "–" : have)") }
                }
            }
            let shown = plan.steps.map { s in s.op + (s.params.isEmpty ? "" : "(" + s.params.sorted { $0.key < $1.key }.map { "\($0.key)=\(Self.text($0.value))" }.joined(separator: ", ") + ")") }.joined(separator: "; ")
            rows.append("| \(c.goal) | \(c.ops.joined(separator: ", ")) | \(shown.isEmpty ? "(none) " + plan.reply.prefix(60) : shown)\(plan.dropped.isEmpty ? "" : " [dropped: \(plan.dropped.joined(separator: ", "))]") | \(ok ? (paramNotes.isEmpty ? "✓" : "ops ✓, " + paramNotes.joined(separator: " ")) : "✗") |")
        }
        let n = Self.cases(track2: "").count
        let summary = "Right actions in the right order: \(opsRight)/\(n). Right key values: \(paramsRight)/\(paramsTotal). Average \(String(format: "%.1f", seconds / Double(n))) s per request."
        let table = "| Request | Expected | Planned | Result |\n|---|---|---|---|\n" + rows.joined(separator: "\n") + "\n\n" + summary + "\n"
        print(table)
        if let path = ProcessInfo.processInfo.environment["JAMMER_EVAL_REPORT"] { try table.write(toFile: path, atomically: true, encoding: .utf8) }
    }
}
