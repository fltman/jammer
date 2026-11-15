import AppKit
import JammerAgent
import JammerAudio
import JammerCore
import JammerEngine
import Observation

/// Copy and cut go here, shared by every window.
@MainActor
enum AppClipboard {
    static var content: ClipboardContent?
}

/// One open document: the project, the selection and playhead around it, undo,
/// playback and the caches the timeline draws from.
@MainActor
@Observable
final class EditorSession {
    /// Stable while the window is open; the agent API addresses documents by it.
    let agentID = UUID().uuidString
    private(set) var project: Project
    var selection: Range<Frame>? { didSet { if selection?.isEmpty == true { selection = nil } } }
    var playhead: Frame = 0
    private(set) var isPlaying = false
    /// Bumped on every document change (the timeline's cache key).
    private(set) var version = 0
    private(set) var peaks: [UUID: PeakIndex] = [:]
    private(set) var peakProgress: [UUID: Double] = [:]
    var status: String?
    var lastAnalysis: LoudnessResult?
    var volume: Float = (UserDefaults.standard.object(forKey: "playback.volume") as? Float) ?? 1 {
        didSet {
            output.setGain(volume)
            UserDefaults.standard.set(volume, forKey: "playback.volume")
        }
    }

    @ObservationIgnored weak var document: JammerDocument?
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored let pool = SourcePool()
    @ObservationIgnored private(set) var plan: RenderPlan
    @ObservationIgnored let output: AudioOutput
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var peakTasks: [UUID: Task<Void, Never>] = [:]

    init(project: Project) {
        self.project = project
        output = AudioOutput(channels: project.channels, sampleRate: project.sampleRate)
        plan = PlanCompiler.compile(project, pool: pool)
        output.setPlan(plan)
        output.setGain(volume)
        loadPeaks()
    }

    var undoManager: UndoManager? { document?.undoManager }
    var name: String { document?.displayName ?? project.tracks.first?.name ?? "Untitled" }
    var duration: Double { project.duration }
    var missingSources: [SourceRef] { project.sources.filter { pool.missing.contains($0.id) } }

    // MARK: Changing the document

    /// Replaces the project as one undo step named `action`.
    func commit(_ newProject: Project, action: String) {
        let old = project
        guard newProject != old else { return }
        replace(with: newProject)
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.commit(old, action: action) }
        }
        undoManager?.setActionName(action)
    }

    /// A finished transcription: one undo step. Sources the project no longer uses are skipped.
    func applyTranscripts(_ ts: [SourceTranscript]) {
        var p = project
        for t in ts where p.source(t.sourceID) != nil { p.setTranscript(t) }
        commit(p, action: "Transcribe")
    }

    /// A finished repair. If the user edited meanwhile, the repaired clips are carried
    /// over by id onto the current project, so neither the edit nor the repair is lost.
    func commitRestoration(_ repaired: Project, basedOn base: Project, action: String) {
        guard project != base else { commit(repaired, action: action); return }
        var p = project
        let byID = Dictionary(repaired.tracks.flatMap(\.clips).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let changed = Set(byID.keys.filter { id in base.tracks.flatMap(\.clips).first { $0.id == id }.map { $0.sourceID != byID[id]!.sourceID } ?? false })
        var touched = false
        for t in p.tracks.indices {
            for c in p.tracks[t].clips.indices where changed.contains(p.tracks[t].clips[c].id) {
                let old = p.tracks[t].clips[c], new = byID[old.id]!
                // Only if the clip still covers the same stretch of audio.
                guard old.sourceID == base.tracks.flatMap(\.clips).first(where: { $0.id == old.id })?.sourceID,
                      old.sourceStart == base.tracks.flatMap(\.clips).first(where: { $0.id == old.id })?.sourceStart,
                      old.length == new.length else { continue }
                p.tracks[t].clips[c].sourceID = new.sourceID
                p.tracks[t].clips[c].sourceStart = new.sourceStart
                touched = true
            }
        }
        guard touched else { status = "The audio changed while repairing; nothing was applied."; return }
        for s in repaired.sources where p.source(s.id) == nil { p.sources.append(s) }
        for t in repaired.transcripts where !p.transcripts.contains(where: { $0.sourceID == t.sourceID }) { p.transcripts.append(t) }
        p.pruneSources()
        commit(p, action: action)
    }

    /// While previewing a repair: play `plan` instead of the document (nil goes back).
    func setPreviewPlan(_ preview: RenderPlan?) {
        output.setPlan(preview ?? plan)
    }

    /// Used when a document is read, without undo.
    func load(_ newProject: Project) {
        replace(with: newProject)
    }

    /// Sources that now live inside the package. Applied to every project this
    /// session installs, undo steps included, so undo never points back outside.
    private var collected: [UUID: SourceRef] = [:]

    /// After "collect and save": these sources are the package's copies from now on.
    func adoptCollected(_ refs: [SourceRef]) {
        for r in refs { collected[r.id] = r }
        replace(with: project)
    }

    private func replace(with newProject: Project) {
        var newProject = newProject
        if !collected.isEmpty {
            for i in newProject.sources.indices {
                if let r = collected[newProject.sources[i].id] { newProject.sources[i] = r }
            }
        }
        project = newProject
        if let s = selection { selection = s.clamped(to: 0..<max(1, project.length)) }
        playhead = min(playhead, project.length)
        plan = PlanCompiler.compile(project, pool: pool)
        output.setPlan(plan)
        version += 1
        loadPeaks()
        document?.invalidateRestorableState()
        // Keep playing: restart where we are so the change is heard at once.
        if isPlaying { try? output.play(from: output.playhead) }
    }

    /// Runs steps from the menu, the palette or an agent. All or nothing: a
    /// failure leaves the document as it was. One undo step.
    func run(_ steps: [Step], action: String) async -> [StepResult] {
        let start = EditState(project: project, selection: selection, playhead: playhead, clipboard: AppClipboard.content,
                              pool: pool, media: MediaStore.folder)
        let pool = self.pool
        let (results, end) = await Task.detached(priority: .userInitiated) { () -> ([StepResult], EditState) in
            var s = start
            let r = StepRunner.run(steps, on: &s, measure: { p, range in
                LoudnessMeter.measure(PlanCompiler.compile(p, pool: pool), range)
            })
            return (r, s)
        }.value
        guard results.allSatisfy({ $0.status == .done }) else { return results }
        if end.project != project { commit(end.project, action: action) }
        selection = end.selection
        playhead = end.playhead
        AppClipboard.content = end.clipboard
        if isPlaying, end.playhead != start.playhead { try? output.play(from: playhead) }
        return results
    }

    /// One operation from the menu or the palette; shows failures in the status line.
    func perform(_ op: String, _ params: [String: JSONValue] = [:]) {
        let title = Operations.named(op)?.title ?? op
        Task {
            let r = await run([Step(op: op, params: params)], action: title)
            if let failed = r.first(where: { $0.status == .failed }) {
                status = failed.error
                NSSound.beep()
            } else if let gain = r.first?.info["gainDB"] {
                status = String(format: "%@: %+.2f dB", title, gain)
            } else {
                status = nil
            }
        }
    }

    // MARK: Playback

    func togglePlay() { isPlaying ? stop() : play() }

    func play(from frame: Frame? = nil) {
        var start = frame ?? (selection?.lowerBound ?? playhead)
        if start >= project.length { start = 0 }
        do {
            try output.play(from: start)
            isPlaying = true
            playhead = start
            startTimer()
        } catch {
            status = error.localizedDescription
        }
    }

    func stop() {
        output.stop()
        isPlaying = false
        playhead = output.playhead
        timer?.invalidate()
        timer = nil
        // Let the device sleep a moment later (restarting it costs a little latency).
        Task {
            try? await Task.sleep(for: .seconds(5))
            if !isPlaying { output.stopDevice() }
        }
    }

    func seek(_ frame: Frame) {
        playhead = max(0, min(frame, project.length))
        if isPlaying { try? output.play(from: playhead) }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.playhead = self.output.playhead
                if !self.output.isPlaying { self.stop() }
            }
        }
    }

    // MARK: Peaks

    static var peakCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "com.brattoo.jammer/Peaks")
    }

    private func loadPeaks() {
        for ref in project.sources where peaks[ref.id] == nil && peakTasks[ref.id] == nil {
            let url = SourcePool.resolve(ref)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let cacheURL = Self.peakCache.appending(path: PeakIndex.cacheKey(for: url, info: ref.info) + ".peaks")
            let info = ref.info
            let id = ref.id
            peakProgress[id] = 0
            peakTasks[id] = Task { [weak self] in
                let index = await Task.detached(priority: .utility) { () -> PeakIndex? in
                    if let cached = PeakIndex.read(from: cacheURL), cached.frames == info.frames { return cached }
                    guard let src = AudioFileReader.openSource(info, at: url) else { return nil }
                    defer { jm_source_release(src) }
                    let built = PeakIndex.build(reading: { at, n in
                        var out = [Float](repeating: 0, count: n * info.channels)
                        let got = Int(jm_source_read(src, at, Int64(n), &out))
                        if got < n { out.removeLast((n - got) * info.channels) }
                        return out
                    }, channels: info.channels, frames: info.frames, progress: { p in
                        Task { @MainActor [weak self] in self?.peakProgress[id] = p }
                        return !Task.isCancelled
                    })
                    try? built?.write(to: cacheURL)
                    return built
                }.value
                guard let self else { return }
                self.peakTasks[id] = nil
                self.peakProgress[id] = nil
                if let index {
                    self.peaks[id] = index
                    self.version += 1
                }
            }
        }
    }

    // MARK: Analysis and export

    func analyze(_ range: Range<Frame>? = nil) async -> LoudnessResult {
        let plan = self.plan
        let r = range ?? 0..<project.length
        let result = await Task.detached(priority: .userInitiated) { LoudnessMeter.measure(plan, r) }.value
        if range == nil { lastAnalysis = result }
        return result
    }

    struct ExportOptions: Sendable {
        var encoding: WAVWriter.Encoding = .int24
        var range: Range<Frame>?
        var dither = false
    }

    /// Renders to a WAV file off the main thread. Keeps the first source's
    /// Broadcast Wave and iXML data when exporting from the start.
    func export(to url: URL, options: ExportOptions, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let plan = self.plan
        let range = options.range ?? 0..<project.length
        guard !range.isEmpty else { throw EditError.emptyRange }
        var wav = WAVWriter.Options(encoding: options.encoding, channels: project.channels, sampleRate: project.sampleRate,
                                    dither: options.dither)
        let first = project.sources.first?.info
        if range.lowerBound == 0 {
            if var bext = first?.bext {
                bext.codingHistory += "A=PCM,F=\(Int(project.sampleRate)),W=\(options.encoding == .int16 ? 16 : (options.encoding == .int24 ? 24 : 32)),T=Jammer\r\n"
                bext.loudnessValue = nil
                bext.loudnessRange = nil
                bext.maxTruePeakLevel = nil
                wav.bext = bext
            }
            wav.ixml = first?.ixml
        }
        wav.markers = project.markers.filter { range.contains($0.position) }
            .map { FileMarker(position: $0.position - range.lowerBound, length: $0.length, name: $0.name) }
        let finalOptions = wav
        try await Task.detached(priority: .userInitiated) {
            let writer = try WAVWriter(url: url, options: finalOptions)
            let total = Double(range.count)
            var done = 0.0
            try plan.render(range) { block in
                try writer.write(block)
                done += Double(block.count / plan.channels)
                progress(done / total)
            }
            try writer.finish()
        }.value
    }
}
