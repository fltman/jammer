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
    /// What the status line says. Set as a text, it is information; `say` sets what kind of line it is
    /// (an error, a warning, something done), which gives it its symbol and what VoiceOver says first.
    var status: String? { didSet { if !sayingKind { statusKind = .info } } }
    private(set) var statusKind: StateKind = .info
    @ObservationIgnored private var sayingKind = false
    func say(_ text: String?, _ kind: StateKind) {
        sayingKind = true
        status = text
        statusKind = kind
        sayingKind = false
    }
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
    /// Set for a document read from a project file (see ProjectAccess): where it may read audio.
    @ObservationIgnored var readsFromPackage: URL?
    @ObservationIgnored var isRestricted = false
    @ObservationIgnored var askedAboutOutside = false
    @ObservationIgnored private(set) var plan: RenderPlan
    /// The units playing the tracks' inserts. Exports and measurements make their own.
    @ObservationIgnored private(set) var inserts: InsertHost
    /// Safe mode: every plugin loads in Apple's host process instead of Jämmer's (tried 2026-11-15:
    /// AUHostingServiceXPC appears and the unit processes). That a crash there leaves Jämmer standing isn't tested.
    static var pluginSafeMode: Bool {
        get { UserDefaults.standard.bool(forKey: "plugins.safeMode") }
        set { UserDefaults.standard.set(newValue, forKey: "plugins.safeMode") }
    }
    @ObservationIgnored let output: AudioOutput
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var peakTasks: [UUID: Task<Void, Never>] = [:]

    /// `fromPackage`: the project was read from a project file, so its audio is read only where
    /// that is allowed (ProjectAccess). The rule is in place before the first file is opened:
    /// compiling the plan and drawing the waveforms already read the audio.
    init(project: Project, fromPackage: Bool = false, package: URL? = nil) {
        self.project = project
        if fromPackage {
            readsFromPackage = package
            isRestricted = true
            pool.restrict(ProjectAccess.rule(package: package))
        }
        output = AudioOutput(channels: project.channels, sampleRate: project.sampleRate)
        inserts = InsertHost(channels: project.channels, sampleRate: project.sampleRate, outOfProcess: Self.pluginSafeMode)
        plan = PlanCompiler.compile(project, pool: pool)
        output.setPlan(plan)
        output.setGain(volume)
        #if DEBUG
        // A test copy is started with `-silentOutput YES` (scripts/with-app.sh always passes it): the
        // engine plays, meters and counts as usual and hands the device silence. What it would have
        // handed over is counted instead, so "what was heard" can be measured without a sound.
        if Self.silentOutput { output.setSilent(true) }
        #endif
        history = try? History(root: project)
        loadPeaks()
        syncInserts()
    }

    /// Brings the playing units in line with the document's inserts (new, removed,
    /// changed settings), then plays through them.
    func syncInserts() {
        let p = project
        guard !p.allInserts.isEmpty || !inserts.isEmpty else { return }
        let host = inserts
        Task { @MainActor in
            guard await host.sync(p), host === self.inserts else { return }
            self.plan = PlanCompiler.compile(self.project.listening(solo: self.solo), pool: self.pool, inserts: host)
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
        didSet {
            if let l = linkedFile {
                linkRecord = l.record
                lostLink = nil
            }
            watchLink()
            // The link is in Jämmer's own journal from now on, and the window is not among the system's
            // saved windows: one way back after a restart or a crash, not two.
            window?.isRestorable = false
            noteInLinkJournal()
            (window?.windowController as? EditorWindowController)?.showLink()
        }
    }
    /// What is kept of the link across a restart.
    private(set) var linkRecord: LinkedFile.Record?
    /// The document's entry in Jämmer's own journal of linked documents (LinkJournalStore).
    var linkEntryID: UUID?
    /// Brought back from the journal when Jämmer started, with changes that were never saved back. True
    /// until they are saved back or given up; the window and `linkedFile.recovered` say so.
    var recovered = false
    /// …and it had been kept for later on purpose (a window closed, or Jämmer quit), not left by a stop.
    var keptFromBefore = false
    /// Steps made since the file was handed over or last saved back: what closing without saving would lose.
    var stepsNotSavedBack = 0
    /// The window is closing with its changes kept for later: the journal's entry stays when the document goes.
    var keepsLinkEntry = false
    /// An ordinary document is autosaved a second after each step, not when macOS's clock next comes
    /// round: by the clock, a hard stop 6 s after a change lost a document that had never been saved
    /// (measured 2026-11-17). Steps that follow each other within the second make one write. A linked
    /// document isn't autosaved at all: Jämmer's journal has it after every step.
    private var autosaveWaiting: DispatchWorkItem?
    func autosaveSoon() {
        guard linkRecord == nil, document != nil else { return }
        autosaveWaiting?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let document = self?.document, document.hasUnautosavedChanges else { return }
            document.autosave(withImplicitCancellability: true) { _ in }
        }
        autosaveWaiting = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// The document as it now stands into the journal, once the step that is being made is done with
    /// (so that "has changes" is what it is after the step).
    func noteInLinkJournal() {
        guard linkRecord != nil else { return }
        DispatchQueue.main.async { [weak self] in if let self { LinkJournalStore.note(self) } }
    }
    /// Set for a document that was linked and whose file can't be used any more (gone, read-only,
    /// another kind of file). It is still not an ordinary document: ⌘S says what is wrong instead of
    /// offering Save As.
    private(set) var lostLink: (name: String, requester: String, why: String)?
    var wasLinked: Bool { linkedFile != nil || lostLink != nil }

    /// The sibling's file can go away, come back or be replaced while the document is open (the sibling
    /// deletes its clip, a disk is unplugged). The title, the menu, ⌘S and `linkedFile.available` in the
    /// agent API have to say what is true now, not what was true when the document opened, so the file is
    /// looked at once a second while there is a link, and again right before every save and listing.
    @ObservationIgnored private var linkWatch: Timer?
    private func watchLink() {
        guard linkRecord != nil, linkWatch == nil else { return }
        linkWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // A document that has been closed is not watched any more.
                guard let self else { return }
                if self.document == nil { self.stopWatchingLink() } else { self.checkLink() }
            }
        }
    }
    func stopWatchingLink() { linkWatch?.invalidate(); linkWatch = nil }

    /// Looks at the linked file now and takes the consequences if its state changed.
    func checkLink() {
        guard let record = linkRecord else { return }
        switch LinkedFile.restore(record) {
        case .linked(let link):
            guard linkedFile == nil else { return }
            linkedFile = link
            status = "\(link.fileName) is back: ⌘S saves it back to \(link.requester) again."
        case .lost(let name, let requester, let why):
            guard lostLink?.why != why || linkedFile != nil else { return }
            linkedFile = nil
            lostLink = (name, requester, why)
            status = "\(name) can't be saved back to \(requester): \(why)"
            (window?.windowController as? EditorWindowController)?.showLink()
            document?.invalidateRestorableState()
        }
    }

    /// After a restart: the link again, or the fact that it is lost.
    func restoreLink(_ record: LinkedFile.Record) {
        linkRecord = record
        window?.isRestorable = false
        watchLink()
        switch LinkedFile.restore(record) {
        case .linked(let link):
            linkedFile = link
        case .lost(let name, let requester, let why):
            linkedFile = nil
            lostLink = (name, requester, why)
            status = "\(name) can't be saved back to \(requester): \(why)"
            (window?.windowController as? EditorWindowController)?.showLink()
        }
    }

    /// Turns safe mode on or off and starts every plugin again.
    func restartPlugins() {
        inserts = InsertHost(channels: project.channels, sampleRate: project.sampleRate, outOfProcess: Self.pluginSafeMode)
        plan = PlanCompiler.compile(project.listening(solo: solo), pool: pool, inserts: inserts)
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
        // `track` is the id of the strip the plugin is on: a track or a bus.
        guard var list = project.strip(track)?.inserts, let i = list.firstIndex(where: { $0.id == insert }),
              !Self.sameState(list[i].state, state) else { return }
        var p = project
        list[i].state = state
        p.setInserts(list, on: track)
        inserts.markApplied(insert, state: state)
        commit(p, action: "Change \(list[i].name)")
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
        // A frozen strip is a file of what it was: a change to what it was made from is not taken.
        if let name = old.frozenViolation(in: newProject) {
            status = "\(name) is frozen. Unfreeze it (Audio › Mixer…) before changing what it was frozen from."
            NSSound.beep()
            return
        }
        PluginStateTrust.noteMade(from: old, to: newProject)
        replace(with: newProject)
        // A step that made a new file: this document is now known to use it (File › Storage…).
        if newProject.sources.map(\.id) != old.sources.map(\.id) { StorageScanner.note(self) }
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

    /// Opens the sources again under the pool's current rule and rebuilds what plays.
    func reloadAudio() { replace(with: project) }

    private func replace(with newProject: Project) {
        let before = project
        var newProject = newProject
        if !collected.isEmpty {
            for i in newProject.sources.indices {
                if let r = collected[newProject.sources[i].id] { newProject.sources[i] = r }
            }
        }
        project = newProject
        if let s = selection { selection = s.clamped(to: 0..<max(1, project.length)) }
        playhead = min(playhead, project.length)
        plan = PlanCompiler.compile(project.listening(solo: solo), pool: pool, inserts: inserts)
        output.setPlan(plan)
        version += 1
        syncInserts()
        loadPeaks()
        document?.invalidateRestorableState()
        if linkRecord != nil { stepsNotSavedBack += 1 }
        noteInLinkJournal()
        autosaveSoon()
        if isPlaying {
            // A change to the mix alone (a mute, a level, a pan, a send, a lane) goes on in the engine
            // from where the sound is: nothing is restarted, so no plugin's tail is cut, and it is heard
            // when the ring has played up to it (a few blocks while the mixer window is in use, up to a
            // third of a second otherwise). A change to what is on the timeline is heard at once, by
            // starting again from the playhead, as before.
            if before.tracks.map(\.clips) == project.tracks.map(\.clips), before.sources == project.sources {
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "stepProbe") {
                    NSLog("Jammer: a mix change while playing: heard in %.0f ms (the ring is %@), %lld plans gone on so far", output.buffered * 1_000, mixerAhead == nil ? "long" : "short", output.continued)
                }
                #endif
            } else {
                try? output.play(from: output.playhead)
            }
        }
    }

    /// Runs steps from the menu, the palette or an agent. All or nothing: a
    /// failure leaves the document as it was. One undo step.
    func run(_ steps: [Step], action: String) async -> [StepResult] {
        let probe0 = Date()
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
        let probe1 = Date()
        if end.project != project { commit(end.project, action: action) }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "stepProbe") {
            let probe2 = Date()
            DispatchQueue.main.async {
                NSLog("Jammer: step probe: the step itself %.1f ms, taking it into the document %.1f ms, the window after it %.1f ms",
                      probe1.timeIntervalSince(probe0) * 1_000, probe2.timeIntervalSince(probe1) * 1_000, Date().timeIntervalSince(probe2) * 1_000)
            }
        }
        #endif
        if let last = steps.last, last.op == "loudness_preset", let preset = LoudnessPreset(rawValue: last.params["preset"]?.string ?? "") {
            presetTarget = (.init(integrated: preset.integrated, ceiling: preset.truePeakCeiling), end.project)
        }
        selection = end.selection
        playhead = end.playhead
        AppClipboard.content = end.clipboard
        if isPlaying, end.playhead != start.playhead { try? output.play(from: playhead) }
        // What a step wants said with its result (automation that stayed where it was under a moved track):
        // in the status line, where it happens.
        if let warning = results.flatMap(\.warnings).first { say(warning, .warning) }
        return results
    }

    /// One operation from the menu or the palette; shows failures in the status line.
    /// `saying`: what the status line says when the step went through and has nothing of its own to say.
    func perform(_ op: String, _ params: [String: JSONValue] = [:], saying: String? = nil) {
        let title = Operations.named(op)?.title ?? op
        Task {
            let r = await run([Step(op: op, params: params)], action: title)
            if let failed = r.first(where: { $0.status == .failed }) {
                // The step's name means nothing in the status bar, and the reason has to fit there.
                // (A line that says what didn't go: an error, by its symbol and to VoiceOver.)
                say(op == "detect_tempo" && failed.reason == "no_steady_tempo" ? "No steady tempo was found, so the tempo is as it was."
                    : op == "duck" && failed.reason == "no_speech" ? "No speech was found to duck under, so nothing was changed."
                    : failed.error, .error)
                NSSound.beep()
            } else if op == "limit", let info = r.first?.info, let after = info["truePeakAfter"], let cut = info["reductionMaxDB"], let secs = info["limitedSeconds"] {
                status = String(format: "Limited: true peak now %.2f dBTP, at most %.1f dB taken off, over %.1f s.", after, cut, secs)
                    + (info["beforePlugins"] == 1 ? " The plugins on the tracks and buses come after it." : "")
            } else if let info = r.first?.info, let after = info["integratedAfter"], let target = info["target"] {
                status = info["limited"] == 1
                    ? String(format: "%@: %.1f LUFS. The limiter took at most %.1f dB off the peaks, over %.1f s.", title, after, info["reductionMaxDB"] ?? 0, info["limitedSeconds"] ?? 0)
                        + (info["limitedByPeak"] == 1 ? String(format: " The target was %.0f.", target) : "")
                    : info["limitedByPeak"] == 1
                    ? String(format: "Reached %.1f instead of %.0f LUFS: the peaks held it back. Loudness Preset With Limiter reaches it.", after, target)
                    : String(format: "%@: %.1f LUFS (%+.2f dB)", title, after, info["gainDB"] ?? 0)
            } else if op == "detect_tempo", let info = r.first?.info, let bpm = info["bpm"] {
                let shown = bpm == bpm.rounded() ? String(format: "%.0f", bpm) : String(format: "%.2f", bpm)
                status = "Tempo \(shown) BPM, first beat at \(String(format: "%.3f", info["firstBeat"] ?? 0)) s."
            } else if op == "duck", let info = r.first?.info, let regions = info["regions"] {
                let n = Int(regions), by = params["amount"]?.double ?? -12
                status = "Ducked under \(n) passage\(n == 1 ? "" : "s") of speech, \(by < 0 ? "−" : "")\(abs(by).formatted(.number.precision(.fractionLength(0...1)))) dB"
                    + (info["replaced"] ?? 0 > 0 ? " (in place of the earlier ducking)" : "") + "."
            } else if let gain = r.first?.info["gainDB"] {
                status = String(format: "%@: %+.2f dB", title, gain)
            } else {
                status = saying
            }
        }
    }

    // MARK: Playback

    func togglePlay() { isPlaying ? stop() : play() }

    #if DEBUG
    static let silentOutput = UserDefaults.standard.bool(forKey: "silentOutput")
    /// Where playback last started (project frames), for comparing what went out with a render.
    private(set) var lastPlayStart: Frame = 0
    /// What the engine handed to the device since playback last started.
    var tapped: (frames: Int64, rmsDB: Double?) { output.tapped }
    #endif

    /// The strips that are soloed: a way of listening, not part of the document. Not saved, not undone,
    /// and nothing that is exported, measured or bounced is changed by it. Ids of strips that are gone
    /// are dropped when it is read.
    private(set) var solo: Set<UUID> = []
    var soloNames: [String] {
        project.tracks.filter { solo.contains($0.id) }.map(\.name) + project.buses.filter { solo.contains($0.id) }.map(\.name)
    }
    func setSolo(_ strips: Set<UUID>) {
        solo = strips.filter { id in project.tracks.contains { $0.id == id } || project.bus(id) != nil }
        plan = PlanCompiler.compile(project.listening(solo: solo), pool: pool, inserts: inserts)
        output.setPlan(plan)
        // Said in the window for as long as it is on, so that a quiet mix is never a puzzle.
        (window?.windowController as? EditorWindowController)?.showLink()
        version += 1
    }

    /// Times, since playback last started, that the sound card asked for audio and there wasn't enough
    /// rendered: each is a gap that was heard. (The engine counts nothing finer: a block that was late
    /// but in time for the card isn't heard and isn't counted.)
    var underruns: Int64 { max(0, output.underruns - underrunsAtStart) }

    // MARK: A hand on the mixer

    /// How far ahead the engine renders while the mixer window is in use, in seconds; nil: the whole ring.
    /// 20 ms to begin with. If the render thread can't keep that without dropouts it is stepped up, to 40
    /// and then 80 ms, and the mixer window says which holds, rather than let the sound stutter.
    private(set) var mixerAhead: Double?
    /// Dropouts since the ring was made short this time.
    private(set) var mixerDropouts: Int64 = 0
    static let mixerAheadSteps = [0.02, 0.04, 0.08]
    @ObservationIgnored private var aheadStep = 0
    @ObservationIgnored private var dropoutsSeen: Int64 = 0
    @ObservationIgnored private var aheadWatch: Timer?
    @ObservationIgnored private var aheadRelease: DispatchWorkItem?

    /// The mixer window came to the front (true) or left it (false; the ring is long again half a second later).
    func mixerInUse(_ on: Bool) {
        aheadRelease?.cancel()
        aheadRelease = nil
        if on {
            guard mixerAhead == nil else { return }
            aheadStep = 0
            mixerDropouts = 0
            dropoutsSeen = output.underruns
            mixerAhead = Self.mixerAheadSteps[0]
            output.setAhead(seconds: Self.mixerAheadSteps[0])
            aheadWatch = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.watchDropouts() }
            }
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                aheadWatch?.invalidate()
                aheadWatch = nil
                mixerAhead = nil
                output.setAhead(seconds: 0)
            }
            aheadRelease = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }
    private func watchDropouts() {
        let now = output.underruns
        guard isPlaying, now > dropoutsSeen else { dropoutsSeen = now; return }
        mixerDropouts += now - dropoutsSeen
        dropoutsSeen = now
        if aheadStep < Self.mixerAheadSteps.count - 1 {
            aheadStep += 1
            mixerAhead = Self.mixerAheadSteps[aheadStep]
            output.setAhead(seconds: Self.mixerAheadSteps[aheadStep])
        }
    }
    @ObservationIgnored private var underrunsAtStart: Int64 = 0

    func play(from frame: Frame? = nil) {
        var start = frame ?? (selection?.lowerBound ?? playhead)
        if start >= project.length { start = 0 }
        do {
            underrunsAtStart = output.underruns
            #if DEBUG
            lastPlayStart = start
            output.startTap()
            #endif
            try output.play(from: start)
            isPlaying = true
            NotificationCenter.default.post(name: PulsingGlow.transportChanged, object: nil)
            playhead = start
            startTimer()
        } catch {
            status = error.localizedDescription
        }
    }

    func stop() {
        output.stop()
        isPlaying = false
        NotificationCenter.default.post(name: PulsingGlow.transportChanged, object: nil)
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

    /// The project with only `tracks` in it, as they sound (gain, fades, effects), over the same
    /// timeline. A track that is named plays even if it is muted: it was asked for.
    func alone(_ tracks: Set<UUID>?) -> Project {
        // (A track that a plugin on one of these listens to stays as its key, heard nowhere.)
        project.only(tracks: tracks)
    }

    func analyze(_ range: Range<Frame>? = nil, tracks: Set<UUID>? = nil) async -> LoudnessResult {
        let plan = await PlanCompiler.mix(alone(tracks), pool: pool, outOfProcess: Self.pluginSafeMode)
        let r = range ?? 0..<project.length
        let result = await Task.detached(priority: .userInitiated) { LoudnessMeter.measure(plan, r) }.value
        if range == nil, tracks == nil { lastAnalysis = result }
        return result
    }

    /// The document measured for ACX's requirements: the mix, its pauses, its ends, and, when the document
    /// is at 44.1 kHz, the MP3 it would be handed in as (192 kbps, constant bit rate), decoded again.
    func acxMeasured() async -> ACX.Measured {
        let mix = await analyze()
        let p = project, pool = pool
        let (floor, head, tail) = await Task.detached(priority: .userInitiated) { () -> (Restoration.NoiseFloor?, Double, Double) in
            let a = Restoration.analyze(p, range: 0..<p.length, pool: pool)
            let quiet = p.silences(minLength: p.frames(0.05), threshold: -45, pool: pool)
            let head = quiet.first.map { $0.lowerBound == 0 ? p.seconds(Frame($0.count)) : 0 } ?? 0
            let tail = quiet.last.map { $0.upperBound >= p.length ? p.seconds(Frame($0.count)) : 0 } ?? 0
            return (a.noiseFloor, head, tail)
        }.value
        var m = ACX.Measured(mix: mix, noiseFloor: floor?.level, noiseSeconds: floor?.seconds ?? 0, channels: p.channels, sampleRate: p.sampleRate,
                             seconds: p.seconds(p.length), head: head, tail: tail)
        let dir = FileManager.default.temporaryDirectory.appending(path: "jammer-acx-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "check.mp3")
        do {
            // At ACX's rate, converted when the document is at another.
            _ = try await export(to: file, options: .init(encoded: EncodedExportOptions(format: .mp3, bitRate: ACX.minBitRate), chapters: false, sampleRate: ACX.sampleRate))
            if let measured = await Task.detached(priority: .userInitiated, operation: { EncodedWriter.measureWritten(file, scratch: dir) }).value {
                m.encoded = measured
                m.encodedBitRate = ACX.minBitRate
                m.encodedSampleRate = ACX.sampleRate
            } else {
                m.encodedReason = "the MP3 couldn't be read back on this Mac"
            }
        } catch {
            m.encodedReason = "the MP3 couldn't be made (\(error.localizedDescription))"
        }
        return m
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
        /// Only these tracks (see `alone`); the file still covers the whole timeline, so stems line up.
        var tracks: Set<UUID>?
        /// The file's sample rate when it is to differ from the document's (one of `Resampler.rates`).
        var sampleRate: Double?
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
    /// Writes the file. With a limiter on the master the file is then measured as written, and written
    /// again with the limiter aiming further under its ceiling until the file holds it: the promise is
    /// about the file, whatever the conversion, the dither or the encoder did after the limiter.
    func export(to url: URL, options: ExportOptions, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> LoudnessDelivery? {
        lastExportLimiter = nil
        guard let ceiling = project.master.limiter?.ceilingDB else {
            return try await exportOnce(to: url, options: options, masterMargin: Mixer.masterMargins[0], progress: progress)
        }
        var peak = Double.infinity
        for margin in Mixer.exportMargins {
            let delivery = try await exportOnce(to: url, options: options, masterMargin: margin, progress: progress)
            let measured = await Task.detached(priority: .userInitiated) {
                EncodedWriter.measureWritten(url, scratch: FileManager.default.temporaryDirectory)
            }.value
            guard let measured else {
                try? FileManager.default.removeItem(at: url)
                throw MasterCeilingError(ceilingDB: ceiling, truePeakDB: nil)
            }
            peak = measured.truePeak
            #if DEBUG
            // A debug build started with `-masterMeasureOffsetDB` reads every file that much hotter than it
            // is, so that the export that can't be held, which a working limiter never gives, can be seen.
            peak += UserDefaults.standard.double(forKey: "masterMeasureOffsetDB")
            #endif
            if peak <= ceiling {
                lastExportLimiter = (ceiling, peak, margin)
                return delivery
            }
        }
        try? FileManager.default.removeItem(at: url)
        throw MasterCeilingError(ceilingDB: ceiling, truePeakDB: peak)
    }

    /// The ceiling, the true peak the file measured, and how far under the ceiling the limiter had to aim,
    /// for the last export through a master limiter; nil when there was none.
    var lastExportLimiter: (ceilingDB: Double, truePeakDB: Double, marginDB: Double)?

    private func exportOnce(to url: URL, options: ExportOptions, masterMargin: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> LoudnessDelivery? {
        // Units of its own: playback keeps going untouched while this renders.
        let mixed = await PlanCompiler.mix(alone(options.tracks), pool: pool, outOfProcess: Self.pluginSafeMode, masterMargin: masterMargin)
        let asked = options.range ?? 0..<project.length
        guard !asked.isEmpty else { throw EditError.emptyRange }
        let chapters = project.chapters(in: asked)
        // Another sample rate than the document's: the mix is rendered once and converted (r8brain, see
        // docs/MASTERING.md), and everything below, the loudness correction included, then works on the
        // converted audio as if it were the document. Times in seconds (chapters) stay as they are.
        var plan = mixed, range = asked, project = self.project, pool = self.pool
        var scratch: URL?
        defer { if let scratch { try? FileManager.default.removeItem(at: scratch) } }
        lastExportSampleRate = project.sampleRate
        if let to = options.sampleRate, to != project.sampleRate {
            let dir = FileManager.default.temporaryDirectory.appending(path: "jammer-convert-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            scratch = dir
            let file = dir.appending(path: "converted.wav")
            let from = project.sampleRate, channels = project.channels
            try UploadStore.checkSpace(for: Int64(Double(asked.count) * to / from) * Int64(channels) * 4, at: dir)
            let converted = try await Task.detached(priority: .userInitiated) {
                try SampleRateConversion.render(mixed, range: asked, to: to, into: file) { progress($0 * 0.5) }
            }.value
            project = Project(source: converted)
            pool = SourcePool()
            plan = PlanCompiler.compile(project, pool: pool)
            range = 0..<project.length
            lastExportSampleRate = to
        }
        let scale = project.sampleRate / self.project.sampleRate
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
                let project = project, pool = pool, range = range, plan = plan, safe = Self.pluginSafeMode, final = encoded
                return try await Task.detached(priority: .userInitiated) {
                    try LoudnessDelivery.deliver(target, encode: { gain in
                        var p = project
                        if gain != 0 { try p.changeGain(range, by: gain) }
                        // The first encode uses the plan already made; a corrected one needs its own.
                        let use = gain == 0 ? plan : PlanCompiler.mixBlocking(p, pool: pool, outOfProcess: safe, masterMargin: masterMargin)
                        try EncodedWriter.export(use, range: range, to: url, options: final) { p in progress(p); return true }
                    }, measure: { EncodedWriter.measureWritten(url, scratch: FileManager.default.temporaryDirectory) })
                }.value
            }
            let (thePlan, theRange, final) = (plan, range, encoded)
            try await Task.detached(priority: .userInitiated) {
                try EncodedWriter.export(thePlan, range: theRange, to: url, options: final) { p in progress(p); return true }
            }.value
            return nil
        }
        var wav = WAVWriter.Options(encoding: options.encoding, channels: project.channels, sampleRate: project.sampleRate,
                                    dither: options.dither)
        let first = self.project.sources.first?.info
        if asked.lowerBound == 0 {
            if var bext = first?.bext {
                bext.codingHistory += "A=PCM,F=\(Int(project.sampleRate)),W=\(options.encoding == .int16 ? 16 : (options.encoding == .int24 ? 24 : 32)),T=Jammer\r\n"
                bext.loudnessValue = nil
                bext.loudnessRange = nil
                bext.maxTruePeakLevel = nil
                wav.bext = bext
            }
            wav.ixml = first?.ixml
        }
        // Markers follow the audio to the new rate.
        wav.markers = self.project.markers.filter { asked.contains($0.position) }
            .map { FileMarker(position: Frame((Double($0.position - asked.lowerBound) * scale).rounded()), length: Frame((Double($0.length) * scale).rounded()), name: $0.cueLabel) }
        let finalOptions = wav
        let (thePlan, theRange) = (plan, range)
        let dithered = try await Task.detached(priority: .userInitiated) { () -> Int64 in
            let writer = try WAVWriter(url: url, options: finalOptions)
            let total = Double(theRange.count)
            var done = 0.0
            try thePlan.render(theRange) { block in
                try writer.write(block)
                done += Double(block.count / thePlan.channels)
                progress(done / total)
            }
            try writer.finish()
            return writer.ditheredSamples
        }.value
        // What was done about dither, said afterwards: "tpdf", or "not_needed" when it was asked for and
        // every sample already sat on a step of the target depth (audio that was 16 bits to begin with).
        lastExportDither = !options.dither || options.encoding == .float32 ? "none" : dithered > 0 ? "tpdf" : "not_needed"
        return nil
    }

    /// See `export`: "none", "tpdf" or "not_needed" for the last WAV written.
    var lastExportDither = "none"
    /// The sample rate of the last file written.
    var lastExportSampleRate = 0.0
}
