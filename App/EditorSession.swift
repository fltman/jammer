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
    /// The units playing the tracks' inserts. Exports and measurements make their own.
    @ObservationIgnored private(set) var inserts: InsertHost
    /// Safe mode: every plugin loads out of process, so a crash can't take Jämmer down.
    static var pluginSafeMode: Bool {
        get { UserDefaults.standard.bool(forKey: "plugins.safeMode") }
        set { UserDefaults.standard.set(newValue, forKey: "plugins.safeMode") }
    }
    @ObservationIgnored let output: AudioOutput
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var peakTasks: [UUID: Task<Void, Never>] = [:]

    init(project: Project) {
        self.project = project
        output = AudioOutput(channels: project.channels, sampleRate: project.sampleRate)
        inserts = InsertHost(channels: project.channels, sampleRate: project.sampleRate, outOfProcess: Self.pluginSafeMode)
        plan = PlanCompiler.compile(project, pool: pool)
        output.setPlan(plan)
        output.setGain(volume)
        history = try? History(root: project)
        loadPeaks()
        syncInserts()
    }

    /// Brings the playing units in line with the document's inserts (new, removed,
    /// changed settings), then plays through them.
    func syncInserts() {
        let p = project
        guard p.tracks.contains(where: { !$0.inserts.isEmpty }) || !inserts.isEmpty else { return }
        let host = inserts
        Task { @MainActor in
            guard await host.sync(p), host === self.inserts else { return }
            self.plan = PlanCompiler.compile(self.project, pool: self.pool, inserts: host)
            self.output.setPlan(self.plan)
            self.pluginsVersion += 1
        }
    }

    /// Bumped when the running plugins change (windows and lists refresh).
    var pluginsVersion = 0

    /// Spectrogram drawing: the tool and the area drawn (on one track).
    enum SpectralTool: String { case box, lasso, brush }
    struct SpectralArea { var shape: SpectralShape; var track: Int }
    var spectralTool: SpectralTool = .box
    var spectralArea: SpectralArea? {
        didSet { if let a = spectralArea { status = "Area: \(a.shape.summary) on \(project.tracks[safe: a.track]?.name ?? "a track")" } }
    }

    /// Runs spectral_edit on the drawn area.
    func editArea(_ action: SpectralAction, db: Double = -20) {
        guard let area = spectralArea, let track = project.tracks[safe: area.track] else { NSSound.beep(); return }
        var params: [String: JSONValue] = ["action": .string(action.rawValue), "tracks": .array([.string(track.id.uuidString)]), "db": .number(db)]
        switch area.shape {
        case .box(let a, let b, let lo, let hi):
            params["shape"] = .string("box"); params["start"] = .number(a); params["end"] = .number(b); params["low"] = .number(lo); params["high"] = .number(hi)
        case .polygon(let pts):
            params["shape"] = .string("polygon"); params["points"] = .array(pts.flatMap { [.number($0.t), .number($0.f)] })
        case .brush(let pts, let r, let rt):
            params["shape"] = .string("brush"); params["points"] = .array(pts.flatMap { [.number($0.t), .number($0.f)] })
            params["radius"] = .number(r); params["radiusTime"] = .number(rt)
        }
        let title = action == .heal ? "Heal Area" : "Attenuate Area"
        Task {
            let r = await run([Step(op: "spectral_edit", params: params)], action: title)
            if let f = r.first(where: { $0.status == .failed }) { status = f.error; NSSound.beep() } else { spectralArea = nil; status = "\(title): done." }
        }
    }

    /// Set when a sibling app handed Jämmer a file to edit; ⌘S then saves back into it.
    var linkedFile: LinkedFile? {
        didSet { (window?.windowController as? EditorWindowController)?.showLink() }
    }

    /// Turns safe mode on or off and starts every plugin again.
    func restartPlugins() {
        inserts = InsertHost(channels: project.channels, sampleRate: project.sampleRate, outOfProcess: Self.pluginSafeMode)
        plan = PlanCompiler.compile(project, pool: pool, inserts: inserts)
        output.setPlan(plan)
        pluginsVersion += 1
        syncInserts()
    }

    /// Settings compared as property lists (serialising the same state twice needn't give
    /// the same bytes), so an undo that re-applies a state doesn't come back as an edit.
    static func sameState(_ a: Data?, _ b: Data?) -> Bool {
        if a == b { return true }
        guard let a, let b,
              let x = try? PropertyListSerialization.propertyList(from: a, format: nil) as? NSDictionary,
              let y = try? PropertyListSerialization.propertyList(from: b, format: nil) as? NSDictionary else { return false }
        return x.isEqual(y)
    }

    /// A plugin's own window changed its settings: store them as one undo step.
    func commitPluginState(track: UUID, insert: UUID, state: Data?) {
        guard let t = project.tracks.firstIndex(where: { $0.id == track }),
              let i = project.tracks[t].inserts.firstIndex(where: { $0.id == insert }),
              !Self.sameState(project.tracks[t].inserts[i].state, state) else { return }
        var p = project
        p.tracks[t].inserts[i].state = state
        inserts.markApplied(insert, state: state)
        commit(p, action: "Change \(p.tracks[t].inserts[i].name)")
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
        // The history tree records the change; undo and redo move along it (a change after
        // an undo starts a branch rather than discarding the old future).
        let from = history?.current
        try? history?.record(project, action: action)
        undoGroup {
            if let from, let to = history?.current {
                registerMove(back: from, forward: to, action: action)
            } else {
                undoManager?.registerUndo(withTarget: self) { target in
                    MainActor.assumeIsolated { target.commit(old, action: action) }
                }
            }
            undoManager?.setActionName(action)
        }
        historyVersion += 1
    }

    /// One change, one undo step, also for agent requests and finished jobs (no user
    /// events between them): see UndoManager.separateStep.
    private func undoGroup(_ body: () -> Void) {
        guard let um = undoManager else { body(); return }
        um.separateStep(body)
    }

    /// The document's history (View › History, `GET …/history`).
    @ObservationIgnored var history: History?
    var historyVersion = 0

    /// Undo (and then redo) as moves between two history nodes.
    private func registerMove(back: UUID, forward: UUID, action: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.moveHistory(to: back)
                target.registerMove(back: forward, forward: back, action: action)
                target.undoManager?.setActionName(action)
            }
        }
    }

    private func moveHistory(to id: UUID) {
        guard let p = try? history?.move(to: id) else { return }
        replace(with: p)
        historyVersion += 1
    }

    /// Goes to any step in the history; itself one undo step back to where you were.
    func jump(to id: UUID) throws {
        guard let h = history, let node = h.node(id) else { throw HistoryError.unknownNode }
        let from = h.current
        guard from != id else { return }
        moveHistory(to: id)
        let action = "Go to \(node.action)"
        undoGroup {
            registerMove(back: from, forward: id, action: action)
            undoManager?.setActionName(action)
        }
    }

    /// A finished transcription: one undo step. Sources the project no longer uses are skipped.
    /// A finished diarisation, worked out on an earlier copy of the document. Turns are
    /// anchored in the sources, so they carry over onto edits made meanwhile.
    func applySpeakers(from diarized: Project) {
        var p = project
        p.speakers = diarized.speakers
        p.speakerTurns = diarized.speakerTurns.filter { p.source($0.sourceID) != nil }
        p.compactSpeakers()
        p.labelWords()
        commit(p, action: "Find Speakers")
    }

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

    /// Used when a document is read, without undo. A saved history whose current step is
    /// this project continues; otherwise the history starts here.
    func load(_ newProject: Project, history saved: History? = nil) {
        replace(with: newProject)
        if let saved, let p = try? saved.project(of: saved.current), p.tracks == project.tracks, p.markers == project.markers {
            history = saved
        } else {
            history = try? History(root: project)
        }
        historyVersion += 1
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
        plan = PlanCompiler.compile(project, pool: pool, inserts: inserts)
        output.setPlan(plan)
        version += 1
        syncInserts()
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
        let safe = Self.pluginSafeMode
        let (results, end) = await Task.detached(priority: .userInitiated) { () -> ([StepResult], EditState) in
            var s = start
            // Loudness is measured on the mix as heard, plugins included.
            let r = StepRunner.run(steps, on: &s, measure: { p, range in
                LoudnessMeter.measure(PlanCompiler.mixBlocking(p, pool: pool, outOfProcess: safe), range)
            })
            return (r, s)
        }.value
        guard results.allSatisfy({ $0.status == .done }) else { return results }
        if end.project != project { commit(end.project, action: action) }
        if let last = steps.last, last.op == "loudness_preset", let preset = LoudnessPreset(rawValue: last.params["preset"]?.string ?? "") {
            presetTarget = (.init(integrated: preset.integrated, ceiling: preset.truePeakCeiling), end.project)
        }
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
            } else if let info = r.first?.info, let after = info["integratedAfter"], let target = info["target"] {
                status = info["limitedByPeak"] == 1
                    ? String(format: "Reached %.1f instead of %.0f LUFS: the peaks held it back (no limiter yet).", after, target)
                    : String(format: "%@: %.1f LUFS (%+.2f dB)", title, after, info["gainDB"] ?? 0)
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
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "\(Bundle.main.bundleIdentifier ?? "com.brattoo.jammer")/Peaks")
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
        let plan = await PlanCompiler.mix(project, pool: pool, outOfProcess: Self.pluginSafeMode)
        let r = range ?? 0..<project.length
        let result = await Task.detached(priority: .userInitiated) { LoudnessMeter.measure(plan, r) }.value
        if range == nil { lastAnalysis = result }
        return result
    }

    struct ExportOptions: Sendable {
        var encoding: WAVWriter.Encoding = .int24
        var range: Range<Frame>?
        var dither = false
        /// AIFF, FLAC, ALAC or AAC; nil writes WAV.
        var encoded: EncodedExportOptions?
        /// Chapters from the markers: ID3 CHAP in MP3, a chapter track in AAC/ALAC, CHAPTERxxx in Opus.
        var chapters = true
        /// Also write Podcasting 2.0 JSON chapters next to the file.
        var chaptersJSON = false
        /// Lossy formats: measure the file as written and correct the gain before the encoder
        /// until it meets this (at most two corrections, never past the ceiling).
        var loudness: LoudnessDelivery.Target?
    }

    /// The target of a loudness preset, while the document is still as that preset left it:
    /// a lossy export is then delivered at it without being asked.
    private var presetTarget: (target: LoudnessDelivery.Target, project: Project)?
    var deliveryTarget: LoudnessDelivery.Target? {
        guard let p = presetTarget, p.project == project else { return nil }
        return p.target
    }

    /// Renders to a WAV file off the main thread. Keeps the first source's
    /// Broadcast Wave and iXML data when exporting from the start.
    @discardableResult
    func export(to url: URL, options: ExportOptions, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> LoudnessDelivery? {
        // Units of its own: playback keeps going untouched while this renders.
        let plan = await PlanCompiler.mix(project, pool: pool, outOfProcess: Self.pluginSafeMode)
        let range = options.range ?? 0..<project.length
        guard !range.isEmpty else { throw EditError.emptyRange }
        let chapters = project.chapters(in: range)
        if options.chaptersJSON, !chapters.isEmpty {
            try ChapterFormats.podcastingJSON(chapters).write(to: url.deletingPathExtension().appendingPathExtension("chapters.json"))
        }
        if var encoded = options.encoded {
            if encoded.format == .mp3, options.chapters {
                encoded.id3 = ChapterFormats.id3Tag(chapters, title: name)
            }
            if [.opus, .aac, .alac].contains(encoded.format), options.chapters {
                encoded.chapters = chapters
                encoded.language = project.transcripts.first?.language
            }
            if let target = options.loudness, encoded.format.loudnessIsCompensated {
                let project = self.project, pool = self.pool, safe = Self.pluginSafeMode, final = encoded
                return try await Task.detached(priority: .userInitiated) {
                    try LoudnessDelivery.deliver(target, encode: { gain in
                        var p = project
                        if gain != 0 { try p.changeGain(range, by: gain) }
                        // The first encode uses the plan already made; a corrected one needs its own.
                        let use = gain == 0 ? plan : PlanCompiler.mixBlocking(p, pool: pool, outOfProcess: safe)
                        try EncodedWriter.export(use, range: range, to: url, options: final) { p in progress(p); return true }
                    }, measure: { EncodedWriter.measureWritten(url, scratch: FileManager.default.temporaryDirectory) })
                }.value
            }
            try await Task.detached(priority: .userInitiated) {
                try EncodedWriter.export(plan, range: range, to: url, options: encoded) { p in progress(p); return true }
            }.value
            return nil
        }
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
            .map { FileMarker(position: $0.position - range.lowerBound, length: $0.length, name: $0.cueLabel) }
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
        return nil
    }
}
