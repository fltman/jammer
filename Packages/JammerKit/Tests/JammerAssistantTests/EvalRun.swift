import Foundation
import JammerAgent
import JammerCore
@testable import JammerAssistant

/// Whether a plan can be carried out, not only whether it names the right actions (the coordinator's proposal,
/// Anders's yes, 2026-11-19): the evaluation's document with sound and a transcript, the plan's steps run on a
/// copy, no window. A step the app runs as a job (`restore`, `transcribe` and the like: an endpoint of its own)
/// is checked as the API checks it, since the job itself needs the app.
enum EvalRun {
    /// The evaluation's document as the steps meet it: the same tracks (the same ids, so the model's plan fits),
    /// the first with words and pauses where a transcript says (fillers among them), the second a tone all along.
    static func runnable(_ p: Project) -> (Project, SourcePool) {
        let sr = 48_000, n = sr * 60
        var speech = [Float](repeating: 0, count: n * 2), tone = [Float](repeating: 0, count: n * 2)
        let spoken: [(String, Double)] = [("Hej", 1), ("och", 1.6), ("ehm", 2.4), ("välkommen", 3.0), ("till", 4.1), ("programmet", 4.6),
                                         ("öh", 9.0), ("idag", 9.6), ("pratar", 10.3), ("vi", 11.0), ("um", 11.5), ("om", 12.2), ("ljud", 12.8)]
        for (_, at) in spoken {
            for i in Int(at * Double(sr))..<min(n, Int((at + 0.4) * Double(sr))) { let v = Float(0.2 * sin(Double(i) * 0.05)); speech[i * 2] = v; speech[i * 2 + 1] = v }
        }
        // Loud enough that a limiter at −1 dBTP has something to do (a quiet test document made "limit" a no-op).
        for i in 0..<n { let v = Float(0.97 * sin(Double(i) * 0.03)); tone[i * 2] = v; tone[i * 2 + 1] = v }
        let pool = SourcePool()
        var q = p
        pool.register(q.sources[0].id, memory: speech, channels: 2)
        if q.sources.count > 1 { pool.register(q.sources[1].id, memory: tone, channels: 2) }
        let words = spoken.map { Word(text: $0.0, start: Frame($0.1 * Double(sr)), end: Frame(($0.1 + 0.4) * Double(sr))) }
        q.setTranscript(SourceTranscript(sourceID: q.sources[0].id, language: "sv-SE", engine: "eval", words: words))
        return (q, pool)
    }

    /// Nil when every step can be carried out on the document; otherwise the first failure, in Jämmer's words.
    static func failure(_ plan: AssistantPlan, project: Project, pool: SourcePool) -> String? {
        let media = FileManager.default.temporaryDirectory.appending(path: "jammer-eval-run-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: media) }
        var state = EditState(project: project, pool: pool, media: media)
        let measure: StepRunner.Measure = { p, r in LoudnessMeter.measure(PlanCompiler.compile(p, pool: pool), r) }
        // What the app runs as a job or measurement (an endpoint of its own, a sibling's operation): checked as
        // the API checks it, before the job; the rest expanded and run as steps.
        let jobs = Set(AssistantCatalog.actions.filter { if case .step = $0.kind { return false }; if case .macro = $0.kind { return false }; return true }.map(\.name))
        for s in plan.steps where jobs.contains(s.op) {
            do { _ = try StepRunner.resolveStrips(Step(op: s.op, params: s.params), in: state.project) } catch { return error.localizedDescription }
        }
        let steps: [Step]
        do { steps = try MacroExpander.expand(plan.steps.filter { !jobs.contains($0.op) }, state: state) } catch { return error.localizedDescription }
        for s in steps {
            if Operations.named(s.op)?.call != nil {
                do { try StepRunner.validate(s); _ = try StepRunner.resolveStrips(s, in: state.project) } catch { return error.localizedDescription }
                continue
            }
            let r = StepRunner.run([s], on: &state, measure: measure)
            if let f = r.first, f.status == .failed { return f.error ?? "\(s.op) failed" }
        }
        return nil
    }
}
