import Foundation
import JammerAgent
import JammerCore
import JammerSpeech

/// Running and recently finished jobs (transcription for now). Main actor; the
/// work itself runs in detached tasks.
@MainActor
final class JobRegistry {
    static let shared = JobRegistry()
    private(set) var jobs: [String: Job] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    /// Finished jobs stay readable for this long.
    private let keep: TimeInterval = 3_600
    private var finishedAt: [String: Date] = [:]

    var running: [Job] { jobs.values.filter { !$0.isFinished }.sorted { $0.id < $1.id } }

    func job(_ id: String) -> Job? {
        prune()
        return jobs[id]
    }

    func cancel(_ id: String) -> Job? {
        guard var job = jobs[id] else { return nil }
        if !job.isFinished {
            tasks[id]?.cancel()
            job.status = .cancelled
            finish(job)
        }
        return jobs[id]
    }

    private func update(_ job: Job) {
        // A cancelled job stays cancelled whatever the worker reports afterwards.
        if jobs[job.id]?.status == .cancelled { return }
        jobs[job.id] = job
    }

    private func finish(_ job: Job) {
        jobs[job.id] = job
        tasks[job.id] = nil
        finishedAt[job.id] = Date()
    }

    private func prune() {
        let now = Date()
        for (id, t) in finishedAt where now.timeIntervalSince(t) > keep {
            jobs[id] = nil
            finishedAt[id] = nil
        }
    }

    /// Transcribes every source the session's clips use that has no transcript yet
    /// (or all of them with `replace`). The result lands as one undo step; words are
    /// anchored to the sources, so edits made meanwhile don't matter.
    func startTranscription(_ session: EditorSession, locale: Locale, replace: Bool) -> Job {
        var job = Job(kind: "transcribe", documentID: session.agentID)
        jobs[job.id] = job
        let project = session.project
        let used = Set(project.tracks.flatMap { $0.clips.map(\.sourceID) })
        let todo = project.sources.filter { src in used.contains(src.id) && (replace || !project.transcripts.contains { $0.sourceID == src.id }) }
        let pool = session.pool
        let engine = AppleSpeechEngine()
        let id = job.id
        let total = Double(todo.reduce(Frame(0)) { $0 + $1.info.frames })
        tasks[id] = Task { [weak self, weak session] in
            job.status = .running
            self?.update(job)
            guard await engine.supports(locale) else {
                job.status = .failed
                job.error = ("unsupported_language", TranscriptionError.unsupportedLanguage(locale.identifier(.bcp47)).localizedDescription)
                self?.finish(job)
                return
            }
            var results: [SourceTranscript] = []
            var done = 0.0
            do {
                for src in todo {
                    try Task.checkCancellation()
                    let base = done
                    let share = Double(src.info.frames) / max(1, total)
                    let t = try await engine.transcribe(src, pool: pool, locale: locale) { p in
                        Task { @MainActor in
                            guard var j = self?.jobs[id], !j.isFinished else { return }
                            j.progress = min(0.99, base + p * share)
                            self?.update(j)
                        }
                    }
                    results.append(t)
                    done += share
                }
                try Task.checkCancellation()
            } catch is CancellationError {
                return
            } catch {
                guard self?.jobs[id]?.status != .cancelled else { return }
                job.status = .failed
                job.error = ("transcription_failed", error.localizedDescription)
                self?.finish(job)
                return
            }
            guard self?.jobs[id]?.status != .cancelled else { return }
            session?.applyTranscripts(results)
            job.status = .done
            job.progress = 1
            job.result = ["sources": .number(Double(results.count)),
                          "words": .number(Double(results.reduce(0) { $0 + $1.words.count })),
                          "language": .string(results.first?.language ?? locale.identifier(.bcp47)),
                          "engine": .string(results.first?.engine ?? engine.id)]
            self?.finish(job)
        }
        return job
    }
}
