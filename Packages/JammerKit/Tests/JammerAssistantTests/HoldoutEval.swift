import Foundation
import JammerAgent
import JammerCore
import Testing
@testable import JammerAssistant

/// Runs a hold-out set once against the on-device model. `JAMMER_HOLDOUT=1`.
@Suite("Assistant hold-out", .serialized, .enabled(if: ProcessInfo.processInfo.environment["JAMMER_HOLDOUT"] != nil))
struct HoldoutEval {
    static func matches(_ have: JSONValue?, _ want: String, tracks: [String]) -> Bool {
        let text = AssistantEval.text(have)
        if want == "<0" || want == "<1" || want == ">0" {
            guard case .number(let d)? = have else { return false }
            return want == "<0" ? d < 0 : want == "<1" ? d < 1 : d > 0
        }
        let options = want.split(separator: "|").map { w -> String in
            switch w { case "{track1}": tracks[0]; case "{track2}": tracks[1]; case "{music}": tracks.count > 2 ? tracks[2] : "-"; default: String(w) }
        }
        return options.contains { $0.caseInsensitiveCompare(text) == .orderedSame || (Double($0) != nil && Double($0) == Double(text)) }
    }

    @Test("Hold-out set, on-device (JAMMER_HOLDOUT=1 or 2)")
    func run() async throws {
        let which = ProcessInfo.processInfo.environment["JAMMER_HOLDOUT"]
        let set = which == "4" ? HoldoutSet4.cases : which == "3" ? HoldoutSet3.cases : which == "2" ? HoldoutSet2.cases : HoldoutSet1.cases
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: 48_000 * 60, chunks: [], bext: nil, ixml: nil, markers: [])
        var p = Project(source: SourceRef(name: "Anna", path: "/dev/null", info: info))
        let b = SourceRef(name: "Erik", path: "/dev/null", info: info)
        p.sources.append(b)
        p.tracks.append(Track(name: "Erik", clips: [Clip(sourceID: b.id, start: 0, length: 48_000 * 60)]))
        var tracks = p.tracks.map(\.id.uuidString)
        // Set 4 is about the mixer: its document has a bus the requests can name.
        if which == "4" { tracks.append(try p.addBus(name: "Music").id.uuidString) }
        let context = AssistantContext(project: p, selection: nil, playhead: 0)
        let actions = AssistantCatalog.actions
        var right = 0, rightForUser = 0, valuesRight = 0, valuesTotal = 0, invented = 0, wrongLanguage = 0, unaskedRuns = 0
        var byKind: [String: (Int, Int)] = [:]
        var rows: [String] = []
        for c in set {
            var plan = AssistantPlan(reply: "", steps: [])
            var failure: String?
            do { plan = try await AssistantEval.planner.plan(goal: c.goal, context: context, history: [], actions: actions) } catch { failure = error.localizedDescription }
            let got = plan.steps.map(\.op)
            let ok = failure == nil && got == c.ops
            let faults = ReplyGuard.faults(plan, goal: c.goal, context: context)
            if !plan.steps.allSatisfy({ AssistantCatalog.changesNothing.contains($0.op) }), !plan.needsConfirmation(goal: c.goal, actions: actions), !c.ops.contains(where: { op in plan.steps.contains { $0.op == op } }) {
                unaskedRuns += 1; print("CHANGED WITHOUT ASKING: \(c.goal) → \(got)")
            }
            if faults.inventedFigure { invented += 1; print("FIGURE OF ITS OWN: \(c.goal) → \(plan.reply)") }
            if faults.wrongLanguage { wrongLanguage += 1; print("OTHER LANGUAGE: \(c.goal) → \(plan.reply)") }
            var notes: [String] = []
            for (op, expected) in c.params {
                let step = plan.steps.first { $0.op == op }
                for (k, v) in expected {
                    valuesTotal += 1
                    if Self.matches(step?.params[k], v, tracks: tracks) { valuesRight += 1 } else { notes.append("\(k)=\(AssistantEval.text(step?.params[k]).isEmpty ? "–" : AssistantEval.text(step?.params[k]))") }
                }
            }
            if ok { right += 1 }
            // As the user gets it: after the checks the app makes on every plan (ReplyGuard). This is the
            // app's behaviour; the plan as the model made it says how much the checks carry.
            let shownPlan = ReplyGuard.checked(plan, goal: c.goal, context: context)
            let forUser = failure == nil && shownPlan.steps.map(\.op) == c.ops
            if forUser { rightForUser += 1 }
            let k = byKind[c.kind] ?? (0, 0)
            byKind[c.kind] = (k.0 + (ok ? 1 : 0), k.1 + 1)
            let shown = plan.steps.map { s in s.op + (s.params.isEmpty ? "" : "(" + s.params.sorted { $0.key < $1.key }.map { "\($0.key)=\(AssistantEval.text($0.value))" }.joined(separator: ", ") + ")") }.joined(separator: "; ")
            let planned = (failure.map { "error: \($0)" } ?? (shown.isEmpty ? "(no steps) “\(plan.reply.prefix(70))”" : shown))
                + (plan.dropped.isEmpty ? "" : " [left out: \(plan.dropped.joined(separator: "; "))]")
            rows.append("| \(c.kind) | \(c.goal) | \(c.ops.isEmpty ? "(no steps)" : c.ops.joined(separator: ", ")) | \(planned) | \(forUser && !ok ? "for the user ✓; " : "")\(ok ? (notes.isEmpty ? "✓" : "ops ✓, " + notes.joined(separator: " ")) : "✗") |")
        }
        let kinds = ["task", "multi", "clarify", "refuse", "answer"].compactMap { k in byKind[k].map { "\(k) \($0.0)/\($0.1)" } }.joined(separator: ", ")
        let summary = "As the user gets it: \(rightForUser)/\(set.count). The model's own plan, right actions: \(right)/\(set.count) (\(kinds)). Right values: \(valuesRight)/\(valuesTotal). Replies with a figure of the model's own (struck before showing): \(invented). Replies in another language than the request (replaced): \(wrongLanguage). Plans with none of the expected actions that would have changed the document without a yes: \(unaskedRuns)."
        let table = "| Kind | Request | Expected | Planned | Result |\n|---|---|---|---|---|\n" + rows.joined(separator: "\n") + "\n\n" + summary + "\n"
        print(table)
        if let path = ProcessInfo.processInfo.environment["JAMMER_EVAL_REPORT"] { try table.write(toFile: path, atomically: true, encoding: .utf8) }
    }
}
