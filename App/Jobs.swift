import Foundation
import JammerAgent
import Observation
import JammerCore
import JammerPlugins
import JammerStems
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
    /// Who speaks when. `by_track` (each track is its speaker) is the default for
    /// double-enders; `ml` runs the diarisation model on each track.
    func startDiarization(_ session: EditorSession, byTrack: Bool, tracks: [UUID], minSpeakers: Int?, maxSpeakers: Int?) -> Job {
        var job = Job(kind: "diarize", documentID: session.agentID)
        jobs[job.id] = job
        let project = session.project, pool = session.pool, id = job.id
        tasks[id] = Task { [weak self, weak session] in
            job.status = .running
            self?.update(job)
            let results: [TrackDiarization]
            let engine = byTrack ? "by-track" : (Diarization.engine?.engineName ?? "model")
            do {
                if byTrack {
                    results = await Task.detached(priority: .userInitiated) { Diarization.byTrack(project, pool: pool, tracks: tracks) }.value
                } else {
                    results = try await Diarization.model(project, pool: pool, tracks: tracks, minSpeakers: minSpeakers, maxSpeakers: maxSpeakers) { p in
                        Task { @MainActor in
                            guard var j = self?.jobs[id], !j.isFinished else { return }
                            j.progress = min(0.99, p)
                            self?.update(j)
                        }
                    }
                }
                try Task.checkCancellation()
            } catch is CancellationError {
                return
            } catch {
                guard self?.jobs[id]?.status != .cancelled else { return }
                job.status = .failed
                job.error = ((error as? DiarizationError)?.reason ?? "diarization_failed", error.localizedDescription)
                self?.finish(job)
                return
            }
            guard self?.jobs[id]?.status != .cancelled else { return }
            var diarized = project
            diarized.applyDiarization(results, engine: engine)
            session?.applySpeakers(from: diarized)
            let seconds = diarized.speakerSeconds()
            // The model merges similar voices easily (docs/DIARISATION.md); say so rather than
            // presenting one speaker as the answer.
            let single = !byTrack && minSpeakers == nil && results.contains { $0.names.count == 1 }
            let hint = "Only one speaker was found. If more people talk, run it again with the number of speakers: the model often merges voices that sound alike."
            session?.status = single
                ? "Found one speaker. If more people talk, choose Audio › Find Speakers › 2 Speakers (or more)."
                : "Found \(diarized.speakers.count) speaker\(diarized.speakers.count == 1 ? "" : "s")."
            job.status = .done
            job.progress = 1
            job.result = ["mode": .string(byTrack ? "by_track" : "ml"),
                          "hint": single ? .string(hint) : .null,
                          "speakers": .array(diarized.speakers.map { .string($0) }),
                          "seconds": .array(diarized.speakers.indices.map { .number(((seconds[$0] ?? 0) * 10).rounded() / 10) }),
                          "turns": .number(Double(diarized.placedTurns().count))]
            self?.finish(job)
        }
        return job
    }

    /// Looks for VST 3 and CLAP plugins again (Audio › Plugins…, POST /api/v1/plugins/scan).
    func startPluginScan(force: Bool) -> Job {
        var job = Job(kind: "plugin_scan")
        jobs[job.id] = job
        let id = job.id
        tasks[id] = Task { [weak self] in
            job.status = .running
            self?.update(job)
            let c = await HostedPluginsController.scan(force: force, progress: { p in
                Task { @MainActor in
                    guard var j = self?.jobs[id], !j.isFinished else { return }
                    j.progress = min(0.99, p)
                    self?.update(j)
                }
            }, cancelled: { Task.isCancelled })
            guard self?.jobs[id]?.status != .cancelled else { return }
            job.status = .done
            job.progress = 1
            // The list of what failed is in GET /api/v1/plugins (`scan.failed`).
            job.result = ["found": .number(Double(c.plugins.count)), "failed": .number(Double(c.failed.count))]
            self?.finish(job)
        }
        return job
    }

    /// Processes files without windows (File › Batch…, POST /api/v1/batch).
    func startBatch(_ request: BatchRequest, done: (@MainActor (BatchResult) -> Void)? = nil) -> Job {
        var job = Job(kind: "batch")
        jobs[job.id] = job
        let id = job.id
        tasks[id] = Task { [weak self] in
            job.status = .running
            self?.update(job)
            let result = await BatchRunner.run(request, media: MediaStore.folder, job: BatchJobs.hook, progress: { p in
                Task { @MainActor in
                    guard var j = self?.jobs[id], !j.isFinished else { return }
                    j.progress = min(0.99, p)
                    self?.update(j)
                }
            }, cancelled: { Task.isCancelled })
            done?(result)
            guard self?.jobs[id]?.status != .cancelled else { return }
            job.status = .done
            job.progress = 1
            job.result = result.json
            self?.finish(job)
        }
        return job
    }

    /// Splits tracks into stems (Spleeter); the stems replace the tracks as one undo step.
    func startSeparation(_ session: EditorSession, tracks: [UUID]?, model: String = "music4") -> Job {
        var job = Job(kind: "separate", documentID: session.agentID)
        jobs[job.id] = job
        let project = session.project, pool = session.pool, id = job.id
        tasks[id] = Task { [weak self, weak session] in
            job.status = .running
            self?.update(job)
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(Project, StemReport), Error> in
                Result {
                    let engine = try Stems.engine(model)
                    return try project.separatingStems(tracks: tracks, engine: engine, pool: pool, media: MediaStore.folder) { p in
                        Task { @MainActor in
                            guard var j = self?.jobs[id], !j.isFinished else { return }
                            j.progress = min(0.99, p)
                            self?.update(j)
                        }
                        return !Task.isCancelled && true
                    }
                }
            }.value
            guard self?.jobs[id]?.status != .cancelled else { return }
            switch result {
            case .success(let (separated, report)):
                if session?.project == project { session?.commit(separated, action: "Separate Stems") } else {
                    job.status = .failed
                    job.error = ("document_changed", "The document changed while separating; nothing was applied. Run it again.")
                    self?.finish(job)
                    return
                }
                session?.status = "Separated into \(report.stems.joined(separator: ", ")). The stems add up to the original."
                job.status = .done
                job.progress = 1
                job.result = ["stems": .array(report.stems.map { .string($0) }), "tracks": .array(report.tracks.map { .string($0.uuidString) }),
                              "model": .string(model),
                              "note": .string(model == "dialog" ? "What the model leaves is shared between music and effects; the stems add up to the original."
                                                               : "Sound above the model's 11 kHz, and whatever the model leaves, is in other; the stems add up to the original.")]
            case .failure(let e):
                job.status = .failed
                job.error = ((e as? StemError)?.reason ?? "separation_failed", e.localizedDescription)
                session?.status = e.localizedDescription
            }
            self?.finish(job)
        }
        return job
    }

    func startTranscription(_ session: EditorSession, locale: Locale, replace: Bool, engine choice: SpeechEngines.Choice = .auto) -> Job {
        var job = Job(kind: "transcribe", documentID: session.agentID)
        jobs[job.id] = job
        let project = session.project
        let used = Set(project.tracks.flatMap { $0.clips.map(\.sourceID) })
        let todo = project.sources.filter { src in used.contains(src.id) && (replace || !project.transcripts.contains { $0.sourceID == src.id }) }
        let pool = session.pool
        // See SpeechEngines: KB-Whisper for Swedish, then Parakeet, then Apple (docs/TRANSCRIPTION.md).
        let engine: any TranscriptionEngine = (try? SpeechEngines.engine(choice, for: locale)) ?? AppleSpeechEngine()
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
