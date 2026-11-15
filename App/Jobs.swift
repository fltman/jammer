import Foundation
import JammerAgent
import Observation
import JammerCore
import JammerSpeech
import JammerWhisper

/// Running and recently finished jobs (transcription for now). Main actor; the
/// work itself runs in detached tasks.
@MainActor
@Observable
final class JobRegistry {
    static let shared = JobRegistry()
    private(set) var jobs: [String: Job] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    /// Finished jobs stay readable for this long.
    @ObservationIgnored private let keep: TimeInterval = 3_600
    @ObservationIgnored private var finishedAt: [String: Date] = [:]

    /// The newest job of `kind` for a document, running or not.
    func latest(_ kind: String, document: String) -> Job? {
        jobs.values.filter { $0.kind == kind && $0.documentID == document }.max { $0.id < $1.id }
    }

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

    /// Repairs the clips in `range` (all when nil) and commits the result as one undo step.
    func startRestoration(_ session: EditorSession, settings: Restoration.Settings, range: Range<Frame>?, tracks: Set<UUID>? = nil,
                          action: String) -> Job {
        var job = Job(kind: "restore", documentID: session.agentID)
        jobs[job.id] = job
        let project = session.project
        let pool = session.pool
        let media = MediaStore.folder
        let id = job.id
        tasks[id] = Task { [weak self, weak session] in
            job.status = .running
            self?.update(job)
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<(Project, Restoration.ApplyReport), Error> in
                Result {
                    try Restoration.apply(settings, to: project, range: range, tracks: tracks, pool: pool, media: media) { p in
                        Task { @MainActor in
                            guard var j = self?.jobs[id], !j.isFinished else { return }
                            j.progress = min(0.99, p)
                            self?.update(j)
                        }
                        return !Task.isCancelled
                    }
                }
            }.value
            guard self?.jobs[id]?.status != .cancelled else { return }
            switch outcome {
            case .success(let (newProject, report)):
                session?.commitRestoration(newProject, basedOn: project, action: action)
                job.status = .done
                job.progress = 1
                var result: [String: JSONValue] = ["clips": .number(Double(report.clips))]
                if let f = report.humFrequency { result["humFrequency"] = .number(f) }
                if settings.kind == .declip { result["clippedRuns"] = .number(Double(report.clippedRuns)) }
                if settings.kind == .declick { result["clicks"] = .number(Double(report.clicks)) }
                job.result = result
            case .failure(let error):
                job.status = .failed
                let code = switch error as? Restoration.ApplyError {
                case .noHum: "no_hum"
                case .nothingInRange: "nothing_in_range"
                default: "restore_failed"
                }
                job.error = (code, error.localizedDescription)
            }
            self?.finish(job)
        }
        return job
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
        // KB-Whisper for Swedish when its model is installed (it scores far better, see
        // docs/TRANSCRIPTION.md); Apple's recognisers otherwise.
        let store = ModelStore.standard()
        let kb = ModelSpec.catalogue.first { store.isInstalled($0) }
        let engine: any TranscriptionEngine = (locale.language.languageCode?.identifier == "sv" && kb != nil)
            ? WhisperEngine(model: kb!, path: store.path(for: kb!)) : AppleSpeechEngine()
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
