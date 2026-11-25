import Foundation
import JammerAgent
import Observation
import JammerCore
import JammerPlugins
import JammerParakeet
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
    /// When each job began running: ⌘. stops the newest.
    @ObservationIgnored private var startedAt: [String: Date] = [:]
    /// Jobs whose paid request has left the app, and the provider's name: a cancel may come too late to
    /// spare the charge (SIBLINGS.md §2).
    @ObservationIgnored private var paidSent: [String: String] = [:]
    /// The engine each transcription job was started with: the transcript panel says where it is being done.
    @ObservationIgnored private(set) var engineOf: [String: SpeechEngines.Choice] = [:]

    /// The newest job of `kind` for a document, running or not.
    func latest(_ kind: String, document: String) -> Job? {
        let matches = jobs.values.filter { $0.kind == kind && $0.documentID == document }
        return matches.first { !$0.isFinished } ?? matches.max {
            (finishedAt[$0.id] ?? .distantPast) < (finishedAt[$1.id] ?? .distantPast)
        }
    }

    var running: [Job] { jobs.values.filter { !$0.isFinished }.sorted { $0.id < $1.id } }

    /// A document's running jobs, oldest first (the status bar's order; ⌘. stops the last).
    func running(document: String) -> [Job] {
        jobs.values.filter { !$0.isFinished && $0.documentID == document }
            .sorted { (startedAt[$0.id] ?? .distantFuture, $0.id) < (startedAt[$1.id] ?? .distantFuture, $1.id) }
    }

    /// Stops one job from the window (COMFORT 7: Stop stops only what it concerns). Nothing it did is applied; a
    /// job whose paid request had left says so instead (`cancel`), since then something may have been charged.
    func stop(_ id: String, in session: EditorSession) {
        guard let job = cancel(id), job.status == .cancelled else { return }
        if job.result?["mayHaveBeenCharged"] == nil { session.say(L10n.text("job.stopped"), .info) }
    }

    /// Detached work that stops when the job's task is cancelled: a detached task doesn't inherit the
    /// cancellation, so `Task.isCancelled` inside it stays false; the flag carries the stop across (as freezing does).
    nonisolated static func stoppable<T: Sendable>(_ work: @escaping @Sendable (StopFlag) -> T) async -> T {
        let stop = StopFlag()
        let task = Task.detached(priority: .userInitiated) { work(stop) }
        return await withTaskCancellationHandler { await task.value } onCancel: { stop.set() }
    }

    func job(_ id: String) -> Job? {
        prune()
        return jobs[id]
    }

    func cancel(_ id: String) -> Job? {
        guard var job = jobs[id] else { return nil }
        if !job.isFinished {
            // Canceling the task stops the request where it is; whatever the provider still sends back is not
            // fetched (an async URLSession request ends with the task), and nothing of it is applied.
            tasks[id]?.cancel()
            let provider = paidSent[id]
            job.cancel(paidRequestLeft: provider != nil)
            finish(job)
            if let provider, let s = AgentRegistry.shared.sessions.first(where: { $0.agentID == job.documentID }) {
                s.say(L10n.text("job.mayHaveBeenCharged", provider), .warning)
            }
        }
        return jobs[id]
    }

    private func update(_ job: Job) {
        // A cancelled job stays cancelled whatever the worker reports afterwards.
        if jobs[job.id]?.status == .cancelled { return }
        if job.status == .running, startedAt[job.id] == nil { startedAt[job.id] = Date() }
        jobs[job.id] = job
    }

    private func finish(_ job: Job) {
        jobs[job.id] = job
        tasks[job.id] = nil
        finishedAt[job.id] = Date()
        startedAt[job.id] = nil
        paidSent[job.id] = nil
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
        let node = session.history?.current
        let pool = session.pool
        let media = MediaStore.folder
        let id = job.id
        tasks[id] = Task { [weak self, weak session] in
            job.status = .running
            self?.update(job)
            let outcome = await Self.stoppable { stop -> Result<(Project, Restoration.ApplyReport), Error> in
                Result {
                    try Restoration.apply(settings, to: project, range: range, tracks: tracks, pool: pool, media: media) { p in
                        Task { @MainActor in
                            guard var j = self?.jobs[id], !j.isFinished else { return }
                            j.progress = min(0.99, p)
                            self?.update(j)
                        }
                        return !stop.isSet
                    }
                }
            }
            guard self?.jobs[id]?.status != .cancelled else { return }
            switch outcome {
            case .success(let (newProject, report)):
                session?.commitRestoration(newProject, basedOn: project, action: action, under: node)
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
                job.fail(code, error)
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
                    results = try await Diarization.model(project, pool: pool, tracks: tracks, minSpeakers: minSpeakers, maxSpeakers: maxSpeakers, voiceprints: true) { p in
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
                job.fail((error as? DiarizationError)?.reason ?? "diarization_failed", error)
                self?.finish(job)
                return
            }
            guard self?.jobs[id]?.status != .cancelled else { return }
            var diarized = project
            diarized.applyDiarization(results, engine: engine)
            session?.applySpeakers(from: diarized)
            // Voiceprints in memory, by speaker number (the names as the diarisation gave them).
            if let session {
                session.speakerPrints = [:]
                for r in results { for (name, v) in r.prints { if let i = session.project.speakers.firstIndex(of: name) { session.speakerPrints[i] = v } } }
            }
            let seconds = diarized.speakerSeconds()
            // The model merges similar voices easily (docs/DIARISATION.md); say so rather than
            // presenting one speaker as the answer.
            let single = !byTrack && minSpeakers == nil && results.contains { $0.names.count == 1 }
            let hint = "Only one speaker was found. If more people talk, run it again with the number of speakers: the model often merges voices that sound alike."
            session?.status = diarized.speakers.isEmpty ? L10n.text("speakers.found.none")
                : single ? L10n.text("speakers.found.single")
                : L10n.count("speakers.found", diarized.speakers.count)
            // The speakers named after saved profiles: a step of its own, after "Found n speakers", so its line is the one seen.
            let recognized: (matches: [Int: VoiceMatch.Match], alternatives: [Int: VoiceMatch.Match]) = session?.nameAfterVoiceProfiles() ?? ([:], [:])
            job.status = .done
            job.progress = 1
            job.result = ["mode": .string(byTrack ? "by_track" : "ml"),
                          "hint": single ? .string(hint) : .null,
                          "speakers": .array(diarized.speakers.map { .string($0) }),
                          "seconds": .array(diarized.speakers.indices.map { .number(((seconds[$0] ?? 0) * 10).rounded() / 10) }),
                          "turns": .number(Double(diarized.placedTurns().count))]
            // Voice profiles, in the order of `speakers` (as the document has them now, after any naming): which
            // saved profile each is like, how alike, and the threshold. Never a voiceprint.
            if !byTrack, let names = session?.project.speakers {
                let m = recognized.matches, a = recognized.alternatives
                job.result?["speakers"] = .array(names.map { .string($0) })
                job.result?["matchedProfile"] = .array(names.indices.map { m[$0].map { .string($0.profile.uuidString) } ?? .null })
                job.result?["matchScore"] = .array(names.indices.map { m[$0].map { .number(($0.score * 100).rounded() / 100) } ?? .null })
                job.result?["alternativeProfile"] = .array(names.indices.map { a[$0].map { .string($0.name) } ?? .null })
                job.result?["alternativeScore"] = .array(names.indices.map { a[$0].map { .number(($0.score * 100).rounded() / 100) } ?? .null })
                job.result?["threshold"] = .number(VoiceMatch.threshold)
            }
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
            let result = await Self.stoppable { stop -> Result<(Project, StemReport), Error> in
                Result {
                    let engine = try Stems.engine(model)
                    return try project.separatingStems(tracks: tracks, engine: engine, pool: pool, media: MediaStore.folder) { p in
                        Task { @MainActor in
                            guard var j = self?.jobs[id], !j.isFinished else { return }
                            j.progress = min(0.99, p)
                            self?.update(j)
                        }
                        return !stop.isSet
                    }
                }
            }
            guard self?.jobs[id]?.status != .cancelled else { return }
            switch result {
            case .success(let (separated, report)):
                if session?.project == project { session?.commit(separated, action: L10n.text("audio.stems")) } else {
                    job.status = .failed
                    job.fail("document_changed", Said("job.changed.separating", "The document changed while separating; nothing was applied. Run it again."))
                    self?.finish(job)
                    return
                }
                // The engines' names for their stems, in the window's language.
                let names = ["vocals": L10n.text("stems.name.vocals"), "drums": L10n.text("stems.name.drums"), "bass": L10n.text("stems.name.bass"),
                             "other": L10n.text("stems.name.other"), "speech": L10n.text("stems.name.speech"), "music": L10n.text("stems.name.music"),
                             "effects": L10n.text("stems.name.effects")]
                session?.status = L10n.text("stems.done", report.stems.map { names[$0] ?? $0 }.joined(separator: ", "))
                job.status = .done
                job.progress = 1
                job.result = ["stems": .array(report.stems.map { .string($0) }), "tracks": .array(report.tracks.map { .string($0.uuidString) }),
                              "model": .string(model),
                              "note": .string(model == "dialog" ? "What the model leaves is shared between music and effects; the stems add up to the original."
                                                               : "Sound above the model's 11 kHz, and whatever the model leaves, is in other; the stems add up to the original.")]
            case .failure(let e):
                job.status = .failed
                job.fail((e as? StemError)?.reason ?? "separation_failed", e)
                session?.status = L10n.error(e)
            }
            self?.finish(job)
        }
        return job
    }

    /// Freezes a track or a bus: rendered as it sounds in the mix, through plugins of the render's own,
    /// into a file in the media folder; the strip then plays from it. One undo step.
    func startFreeze(_ session: EditorSession, strip: UUID) -> Job {
        var job = Job(kind: "freeze", documentID: session.agentID)
        jobs[job.id] = job
        let project = session.project, pool = session.pool, id = job.id, safe = EditorSession.pluginSafeMode, media = MediaStore.folder
        let name = project.strip(strip)?.name ?? L10n.text("freeze.strip.fallback")
        tasks[id] = Task { [weak self, weak session] in
            job.status = .running
            self?.update(job)
            // Cancelling the job stops the render at its next block; the half-written file is then removed
            // (`freezing` removes its file when the render throws).
            let stop = StopFlag()
            let work = Task.detached(priority: .userInitiated) { () -> Result<Project, Error> in
                Result {
                    try project.freezing(strip, media: media) { context, range, write in
                        let plan = PlanCompiler.mixBlocking(context, pool: pool, outOfProcess: safe)
                        try plan.render(range) { block in
                            if stop.isSet { throw CancellationError() }
                            try write(block)
                        }
                    }
                }
            }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { stop.set() }
            guard self?.jobs[id]?.status != .cancelled else { return }
            switch result {
            case .success(let frozen):
                guard session?.project == project else {
                    job.status = .failed
                    job.fail("document_changed", Said("job.changed.freezing", "The document changed while freezing; nothing was applied. Run it again."))
                    self?.finish(job)
                    return
                }
                session?.commit(frozen, action: L10n.text("freeze.action", name))
                session?.status = L10n.text("freeze.done", name)
                job.status = .done
                job.progress = 1
                if let f = frozen.frozen(strip) {
                    job.result = ["strip": .string(strip.uuidString), "seconds": .number((frozen.seconds(f.length) * 1_000).rounded() / 1_000)]
                }
            case .failure(let e):
                job.status = .failed
                job.fail((e as? FreezeError)?.reason ?? "freeze_failed", e)
                session?.status = L10n.error(e)
            }
            self?.finish(job)
        }
        return job
    }

    /// Set from the job's cancellation, read by the work on its own thread.
    final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    func startVoiceTranscription(_ session: EditorSession, tracks: [UUID]? = nil,
                                 splitTrack: UUID? = nil, nameSpeakers: Bool = true) throws -> Job {
        guard latest("transcribe", document: session.agentID)?.isFinished != false else {
            throw SpeechEngines.Unavailable(reason: "transcription_running",
                message: Said("transcript.working", "Transcribing on this Mac…"))
        }
        guard SpeechEngines.store.isInstalled(.multilingualWhisper) else {
            throw SpeechEngines.Unavailable(reason: "model_missing",
                message: Said("voiceTranscribe.model", "Install multilingual Whisper in Jämmer › Settings › Models to detect each track’s language."),
                requirement: ModelSpec.multilingualWhisper.id)
        }
        let base = session.project
        var working = base
        let ids = if let splitTrack { try working.splitSpeakers(track: splitTrack) }
            else { tracks ?? TrackSpeech.tracks(in: working) }
        let wanted = Set(ids)
        let turns = working.placedTurns()
        let restrictToSpeech = splitTrack == nil && working.hasOverlappingTracks
        let inputs = working.tracks.indices.filter {
            wanted.contains(working.tracks[$0].id) && !working.tracks[$0].clips.isEmpty && working.tracks[$0].frozen == nil
        }.map { TrackSpeech(project: working, index: $0, turns: turns, restrictToSpeech: restrictToSpeech) }.filter { !$0.spans.isEmpty }
        guard !inputs.isEmpty else {
            throw SpeechEngines.Unavailable(reason: "nothing_to_transcribe",
                message: Said("voiceTranscribe.noTracks", "There are no voice tracks to transcribe."))
        }
        var job = Job(kind: "transcribe", documentID: session.agentID)
        let id = job.id
        jobs[id] = job
        let pool = session.pool
        let whisper = SpeechEngines.multilingualWhisper
        let pianissimo = SpeechEngines.pianissimo
        tasks[id] = Task { [weak self, weak session] in
            job.status = .running
            self?.update(job)
            do {
                let results = try await Self.recognizeVoiceTracks(inputs, pool: pool, sampleRate: base.sampleRate, whisper: whisper,
                                                                 pianissimo: pianissimo) { progress in
                    Task { @MainActor in
                        guard var job = self?.jobs[id], !job.isFinished else { return }
                        job.progress = min(0.99, progress)
                        self?.update(job)
                    }
                }
                try Task.checkCancellation()
                guard let session else { throw CancellationError() }
                var current = session.project
                if splitTrack != nil {
                    guard current == base else { throw VoiceTrackJobError.changed }
                    current = working
                } else {
                    guard current.speakerTurns == base.speakerTurns, inputs.allSatisfy({ input in
                        current.tracks.contains { $0.id == input.track.id && $0.clips == input.track.clips && $0.frozen == nil }
                    }) else { throw VoiceTrackJobError.changed }
                }
                let names = nameSpeakers ? VoiceTrackTranscription.names(for: results, sampleRate: base.sampleRate) : [:]
                var details: [Job.TranscribedTrack] = []
                for result in results {
                    let track = result.track.track.id
                    let transcript = result.transcript
                    let count = result.track.apply(transcript, name: names[track], to: &current)
                    let name = current.tracks.first { $0.id == track }?.name ?? result.track.track.name
                    details.append(.init(id: track, name: name, language: transcript.language, engine: transcript.engine, words: count))
                }
                session.commit(current, action: L10n.text(splitTrack == nil ? "op.transcribe_voice_tracks.title" : "voiceTranscribe.split"))
                session.status = L10n.text("voiceTranscribe.done")
                job.status = .done
                job.progress = 1
                job.transcribedTracks = details
                self?.finish(job)
            } catch is CancellationError {
                if self?.jobs[id]?.status != .cancelled {
                    job.cancel(paidRequestLeft: false)
                    self?.finish(job)
                }
            } catch {
                guard self?.jobs[id]?.status != .cancelled else { return }
                job.status = .failed
                job.fail(error is VoiceTrackJobError ? "track_changed" : "transcription_failed", error)
                session?.say(L10n.error(error), .error)
                self?.finish(job)
            }
        }
        return job
    }

    private enum VoiceTrackJobError: LocalizedError, KeyedFailure {
        case changed
        var errorDescription: String? { said.text }
        var keyed: KeyedMessage? { said.keyed }
        private var said: Said {
            Said("voiceTranscribe.changed", "The voice tracks changed while transcription was running. Run it again on the current edit.")
        }
    }

    @concurrent nonisolated private static func recognizeVoiceTracks(_ inputs: [TrackSpeech], pool: SourcePool, sampleRate: Double,
                                                         whisper: WhisperEngine, pianissimo: [PianissimoModel: PianissimoEngine],
                                                         progress: @escaping @Sendable (Double) -> Void) async throws -> [VoiceTrackTranscription.Result] {
        let folder = FileManager.default.temporaryDirectory.appending(path: "jammer-voice-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        var results: [VoiceTrackTranscription.Result] = []
        for (i, track) in inputs.enumerated() {
            try Task.checkCancellation()
            let file = folder.appending(path: "\(i).wav")
            let input = try VoiceTrackTranscription.writeInput(track, sampleRate: sampleRate, pool: pool, to: file)
            let analysisPool = SourcePool()
            let base = Double(i) / Double(inputs.count), share = 1 / Double(inputs.count)
            let language = try whisper.detectLanguage(input, pool: analysisPool) ?? "und"
            let locale = Locale(identifier: language)
            var specialized: SourceTranscript?
            if let model = PianissimoModel(rawValue: language), let recognizer = pianissimo[model], recognizer.isInstalled {
                do {
                    let refined = try await recognizer.transcribe(input, pool: analysisPool, locale: locale) { progress(base + $0 * share) }
                    if !refined.words.isEmpty { specialized = refined }
                } catch {
                    try Task.checkCancellation()
                    // If the optional specialist model can't run, Whisper still recognizes this track.
                }
            }
            var transcript: SourceTranscript
            if let specialized {
                transcript = specialized
            } else {
                transcript = try await whisper.transcribe(input, pool: analysisPool, locale: locale) { progress(base + $0 * share) }
            }
            transcript.language = language
            results.append(.init(track: track, transcript: transcript))
            try FileManager.default.removeItem(at: file)
            progress(base + share)
        }
        return results
    }

    func startTranscription(_ session: EditorSession, locale: Locale, replace: Bool, engine choice: SpeechEngines.Choice = .auto, model: String? = nil) -> Job {
        var job = Job(kind: "transcribe", documentID: session.agentID)
        jobs[job.id] = job
        engineOf[job.id] = choice
        let project = session.project
        let node = session.history?.current
        let used = Set(project.tracks.flatMap { $0.clips.map(\.sourceID) })
        let todo = project.sources.filter { src in used.contains(src.id) && (replace || !project.transcripts.contains { $0.sourceID == src.id }) }
        let pool = session.pool
        let engine: any TranscriptionEngine
        do {
            engine = try SpeechEngines.engine(choice, for: locale, model: model)
        } catch {
            job.status = .failed
            job.fail((error as? SpeechEngines.Unavailable)?.reason ?? "engine_unavailable", error)
            finish(job)
            return job
        }
        let id = job.id
        let total = Double(todo.reduce(Frame(0)) { $0 + $1.info.frames })
        tasks[id] = Task { [weak self, weak session] in
            job.status = .running
            self?.update(job)
            guard await engine.supports(locale) else {
                job.status = .failed
                job.fail("unsupported_language", TranscriptionError.unsupportedLanguage(locale.identifier(.bcp47)))
                self?.finish(job)
                return
            }
            var results: [SourceTranscript] = []
            var done = 0.0
            do {
                for src in todo {
                    try Task.checkCancellation()
                    // From here a paid engine's request leaves the app.
                    if let provider = choice.provider { self?.paidSent[id] = provider }
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
                job.fail("transcription_failed", error)
                self?.finish(job)
                return
            }
            guard self?.jobs[id]?.status != .cancelled else { return }
            session?.applyTranscripts(results, basedOn: project, under: node)
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

    /// Work for another app with no document (POST /api/v1/transcribe/file): `work` reports 0…1 and leaves its
    /// result where the caller keeps it (never in the job, which /api/v1/status lists); `ended` runs once the work has
    /// really stopped, however it ended, to give back what it held.
    func startSibling(kind: String, work: @escaping @MainActor (_ id: String, _ progress: @escaping @Sendable (Double) -> Void) async throws -> [String: JSONValue],
                      ended: @escaping @MainActor () -> Void) -> Job {
        var job = Job(kind: kind)
        jobs[job.id] = job
        let id = job.id
        tasks[id] = Task { [weak self] in
            defer { ended() }
            job.status = .running
            self?.update(job)
            do {
                let facts = try await work(id) { p in
                    Task { @MainActor in
                        guard var j = self?.jobs[id], !j.isFinished else { return }
                        j.progress = min(0.99, p)
                        self?.update(j)
                    }
                }
                guard self?.jobs[id]?.status != .cancelled else { return }
                job.status = .done
                job.progress = 1
                job.result = facts
            } catch {
                guard self?.jobs[id]?.status != .cancelled, !(error is CancellationError) else { return }
                job.status = .failed
                if let e = error as? AgentAPI.APIError { job.fail(e.code, Said("error.said", "%@", e.message)) } else { job.fail("transcription_failed", error) }
            }
            self?.finish(job)
        }
        return job
    }
}
