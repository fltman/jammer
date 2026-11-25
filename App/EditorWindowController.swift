import AppKit
import JammerAgent
import JammerCore
import JammerDiarize
import JammerStems
import SwiftUI
import UniformTypeIdentifiers

/// A menu item's operation and its preset parameters.
final class OperationItem: NSObject {
    let op: String
    let params: [String: JSONValue]
    init(_ op: String, _ params: [String: JSONValue] = [:]) {
        self.op = op
        self.params = params
    }
}

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let session: EditorSession
    let timeline: TimelineView
    let transcript: TranscriptPanel
    let assistant: AssistantModel
    /// Focus mode: which side panels were shown before it hid them (a view mode, never an undo step).
    var focusMode: (assistant: Bool, transcript: Bool, palette: Bool)?
    var toolPaletteView: NSView?
    private var assistantView: NSView!
    /// The omnibar at the bottom of the window (⌘K), over the timeline's lower edge while it lists commands.
    private(set) var omnibar: OmnibarModel!

    init(session: EditorSession) {
        self.session = session
        timeline = TimelineView(session: session)
        transcript = TranscriptPanel(session: session)
        assistant = AssistantModel(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 640, height: 360)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.ink
        window.titlebarAppearsTransparent = true
        window.tabbingMode = .preferred
        super.init(window: window)
        window.delegate = self
        session.window = window

        let transport = NSHostingView(rootView: TransportBar(session: session, timeline: timeline))
        let statusBar = NSHostingView(rootView: StatusBar(session: session))
        // Room for the omnibar's field above the status bar, so that it covers nothing while it is empty; its
        // list grows upwards over the timeline only while it is in use.
        let omnibarRoom = NSView()
        omnibarRoom.heightAnchor.constraint(equalToConstant: 52).isActive = true
        omnibarRoom.setContentHuggingPriority(.required, for: .vertical)
        // The tool palette in a column of its own beside the timeline (never over the waveform).
        let palette = NSHostingView(rootView: ToolPalette(session: session) { [unowned self] id in self.chooseTool(id) })
        palette.isHidden = UserDefaults.standard.object(forKey: "toolPalette.visible") as? Bool == false
        toolPaletteView = palette
        let timelineRow = NSStackView(views: [palette, timeline])
        timelineRow.orientation = .horizontal
        timelineRow.spacing = 0
        timelineRow.alignment = .height
        timelineRow.setContentHuggingPriority(.defaultLow, for: .vertical)
        let stack = NSStackView(views: [transport, timelineRow, transcript, omnibarRoom, statusBar])
        transcript.isHidden = !UserDefaults.standard.bool(forKey: "transcript.visible")
        transcript.heightAnchor.constraint(equalTo: timeline.heightAnchor, multiplier: 0.45).isActive = true
        transcript.setContentHuggingPriority(.defaultLow, for: .vertical)
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        stack.setHuggingPriority(.defaultHigh, for: .vertical)
        // The timeline and the transcript the stack's whole width, required: the stack's own alignment gave way after
        // some edits (a fade in) and the transcript panel shrank to its one-line label, against the right edge (seen
        // 2026-11-17). The transport and the status bar keep their own width, centered.
        for row in [timelineRow, transcript] as [NSView] { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        transport.setContentHuggingPriority(.required, for: .vertical)
        statusBar.setContentHuggingPriority(.required, for: .vertical)
        timeline.setContentHuggingPriority(.defaultLow, for: .vertical)
        let assistantHost = NSHostingView(rootView: AssistantView(model: assistant))
        assistantHost.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        // Its width is ours (at least 260, preferably 320), not what SwiftUI offers: with the field focused, the
        // field editor of a vertical text field made the panel's least width about 600 pt (seen 2026-11-17).
        assistantHost.sizingOptions = []
        assistantHost.isHidden = !UserDefaults.standard.bool(forKey: "assistant.visible")
        // A split view starts its panes at the sizes of their frames, and a hosting view's first frame is its
        // content's ideal size: the assistant's intro sentence made that about 600 pt, which the panel's holding
        // priority then kept (seen 2026-11-17). Both start at a size of ours: the panel 320 pt.
        stack.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        assistantHost.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
        let left = NSView(frame: stack.frame)
        stack.translatesAutoresizingMaskIntoConstraints = false
        left.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: left.leadingAnchor), stack.trailingAnchor.constraint(equalTo: left.trailingAnchor),
            stack.topAnchor.constraint(equalTo: left.topAnchor), stack.bottomAnchor.constraint(equalTo: left.bottomAnchor),
        ])
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(left)
        split.addArrangedSubview(assistantHost)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        window.contentView = split
        omnibar = OmnibarModel(
            commands: { [unowned self] in CommandPalette.commands(controller: self) },
            ask: { [unowned self] text in self.askFromOmnibar(text) },
            leave: { [unowned self] in self.window?.makeFirstResponder(self.timeline) })
        let omnibarHost = NSHostingView(rootView: OmnibarView(model: omnibar))
        omnibarHost.sizingOptions = [.intrinsicContentSize]
        omnibarHost.translatesAutoresizingMaskIntoConstraints = false
        left.addSubview(omnibarHost)
        let wide = omnibarHost.widthAnchor.constraint(equalTo: left.widthAnchor, constant: -32)
        wide.priority = .defaultHigh
        NSLayoutConstraint.activate([
            omnibarHost.bottomAnchor.constraint(equalTo: omnibarRoom.bottomAnchor, constant: -6),
            omnibarHost.centerXAnchor.constraint(equalTo: left.centerXAnchor),
            omnibarHost.widthAnchor.constraint(lessThanOrEqualToConstant: 720), wide,
        ])
        window.center()
        window.setFrameAutosaveName("JammerEditor")
        window.makeFirstResponder(timeline.firstResponderView)
        // Where the keyboard is when the window first becomes key: the timeline (Space plays), never the
        // assistant's field, which otherwise won that race now and then (seen 2026-11-17).
        window.initialFirstResponder = timeline.firstResponderView
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// A linked file says so under the title: "clip.wav · For Flimmer – ⌘S saves back".
    /// And solo says so there too, for as long as it is on, so that a mix with tracks missing is never a puzzle.
    func showLink() {
        // A linked window is not among the system's saved windows: Jämmer's own journal is its way back.
        if session.linkRecord != nil { window?.isRestorable = false }
        var parts: [String] = []
        if let lost = session.lostLink {
            parts.append(L10n.text("link.subtitle.lost", lost.name, lost.requester))
        } else if let link = session.linkedFile {
            parts.append(L10n.text("link.subtitle", link.fileName, link.requester))
        }
        // Said in the window for as long as it is so, not only once in the status line.
        if session.recovered, session.wasLinked { parts.append(session.keptFromBefore ? L10n.text("link.kept.subtitle") : L10n.text("link.recovered.subtitle")) }
        if !session.solo.isEmpty { parts.append(L10n.text("solo.subtitle", session.soloNames.joined(separator: ", "))) }
        window?.subtitle = parts.joined(separator: " · ")
    }

    // File › Save and Duplicate come here first (the window controller is ahead of the
    // document in the responder chain): linked documents save back instead.
    @objc(saveDocument:) func saveOrSaveBack(_ sender: Any?) {
        // The file as it is this moment: one that was removed a second ago gets the explanation, not a failed write.
        session.checkLink()
        if session.linkedFile != nil { session.saveBack() }
        else if session.lostLink != nil, let window { session.saveBackOrExplain(in: window) }
        else { session.document?.save(sender) }
    }

    @objc(duplicateDocument:) func duplicateOrCopy(_ sender: Any?) {
        if session.wasLinked { session.saveJammerCopy() } else { session.document?.duplicate(sender) }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        window?.makeFirstResponder(timeline.firstResponderView)
        // Again once SwiftUI has done its part: in a window opened while the app is active, it gave the
        // assistant's field the keyboard right after this (seen 2026-11-17 on the second document opened).
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.isKeyWindow else { return }
            window.makeFirstResponder(self.timeline.firstResponderView)
        }
    }

    func windowWillClose(_ notification: Notification) { closeMixer(); session.stop() }

    // MARK: Actions (reached through the responder chain)

    @objc func togglePlayback(_ sender: Any?) { session.togglePlay() }
    @objc func goToStart(_ sender: Any?) { session.seek(0) }
    @objc func zoomIn(_ sender: Any?) { timeline.zoom(by: 2) }
    @objc func zoomOut(_ sender: Any?) { timeline.zoom(by: 0.5) }
    @objc func zoomToFit(_ sender: Any?) { timeline.zoomToFit() }
    @objc func zoomToSelection(_ sender: Any?) { timeline.zoomToSelection() }

    /// Double-enders: each speaker's own recording as a track, lined up with track 1.
    @objc func importTracks(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio]
        panel.message = L10n.text("importTracks.panel")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            let urls = panel.urls
            // The user picked these: a project saved with them may read them again.
            ProjectAccess.approve(urls)
            let session = self.session
            Task {
                session.status = L10n.count("importTracks.working", urls.count)
                var p = session.project
                var added: [UUID] = [], short: [String] = []
                for url in urls {
                    do {
                        // At the document's sample rate: a file at another rate is converted, not played at the wrong speed.
                        let rate = p.sampleRate
                        let r = try await Task.detached { try AudioImporter.importFile(url, sampleRate: rate, mediaFolder: MediaStore.folder) }.value
                        added.append(p.addTrack(source: r.source, name: url.deletingPathExtension().lastPathComponent).id)
                        if let w = r.warning { short.append(w) }
                    } catch {
                        session.status = L10n.text("importTracks.failed", url.lastPathComponent, L10n.error(error))
                        return
                    }
                }
                guard p.tracks.count > 1 else {
                    session.commit(p, action: L10n.text("importTracks.action"))
                    session.status = ([L10n.count("importTracks.done", added.count)] + short).joined(separator: " ")
                    return
                }
                session.status = L10n.text("importTracks.aligning")
                let pool = session.pool
                let (aligned, notes) = await Task.detached { () -> (Project, [String]) in
                    var q = p
                    // The call recording (where everyone is heard) makes the best reference.
                    let reference = q.suggestedReference(pool: pool) ?? q.tracks[0].id
                    let others = q.tracks.map(\.id).filter { $0 != reference }
                    let results = q.alignTracks(to: reference, tracks: others, pool: pool, minConfidence: 0.3)
                    var notes = [L10n.text("importTracks.note.reference", q.tracks.first { $0.id == reference }?.name ?? "?")]
                    for id in others {
                        guard let t = q.tracks.first(where: { $0.id == id }), let r = results[id] else { continue }
                        if r.confidence < 0.3 {
                            notes.append(L10n.text("importTracks.note.noMatch", t.name, L10n.number(r.confidence, 2)))
                        } else {
                            var note = L10n.text("importTracks.note.moved", t.name, L10n.number(q.seconds(r.offset), 3, sign: true))
                            // Recorders' clocks can disagree; say so when they part noticeably.
                            if let d = q.drift(of: id, against: reference, pool: pool), d.start.confidence > 0.5, d.end.confidence > 0.5,
                               abs(d.partsPerMillion) > 10 {
                                note += ", " + L10n.text("importTracks.note.drift", L10n.number(d.partsPerMillion * 3.6, 0))
                            }
                            notes.append(note)
                        }
                    }
                    return (q, notes)
                }.value
                session.commit(aligned, action: L10n.text("importTracks.action"))
                session.status = (short + [L10n.text("importTracks.aligned", notes.joined(separator: "; "))]).joined(separator: " ")
            }
        }
    }

    /// Lowers a frequency band inside the selection (spectral attenuation).
    @objc func attenuateFrequencies(_ sender: Any?) {
        guard let window, let sel = session.selection else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = L10n.text("attenuate.title")
        alert.informativeText = L10n.text("attenuate.text")
        let low = NSTextField(string: "4000"), high = NSTextField(string: "8000"), db = NSTextField(string: "-20")
        for f in [low, high, db] { f.widthAnchor.constraint(equalToConstant: 80).isActive = true }
        low.setAccessibilityLabel(L10n.text("attenuate.from.ax"))
        high.setAccessibilityLabel(L10n.text("attenuate.to.ax"))
        db.setAccessibilityLabel(L10n.text("attenuate.change.ax"))
        let grid = NSGridView(views: [[NSTextField(labelWithString: L10n.text("attenuate.from")), low], [NSTextField(labelWithString: L10n.text("attenuate.to")), high],
                                      [NSTextField(labelWithString: L10n.text("attenuate.change")), db]])
        grid.frame = NSRect(x: 0, y: 0, width: 240, height: 90)
        alert.accessoryView = grid
        alert.addButton(withTitle: L10n.text("attenuate.button"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        alert.beginSheetModal(for: window) { [session] response in
            guard response == .alertFirstButtonReturn else { return }
            let p = session.project, pool = session.pool
            let band = min(low.doubleValue, high.doubleValue)...max(low.doubleValue, high.doubleValue), gain = min(0, db.doubleValue)
            Task {
                session.status = L10n.text("attenuate.working")
                let result = await Task.detached { Result { try p.applyingSpectralAttenuation(range: sel, freq: band, gainDB: gain, pool: pool, media: MediaStore.folder) } }.value
                switch result {
                case .success(let q):
                    session.commit(q, action: L10n.text("attenuate.title"))
                    session.status = L10n.text("attenuate.done", L10n.number(band.lowerBound, 0), L10n.number(band.upperBound, 0), L10n.number(-gain, 0))
                case .failure(let e):
                    session.status = L10n.error(e)
                }
            }
        }
    }

    // Spectrogram areas (drawn with B, L, P in the spectrogram).

    @objc func healArea(_ sender: Any?) { session.editArea(.heal) }

    @objc func attenuateArea(_ sender: Any?) {
        guard let window, session.spectralArea != nil else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = L10n.text("spectral.attenuate.action")
        alert.informativeText = session.spectralArea.map { L10n.message($0.shape.summarySaid.keyed) } ?? ""
        let db = NSTextField(string: "-20")
        db.setAccessibilityLabel(L10n.text("attenuate.change.ax"))
        db.frame = NSRect(x: 0, y: 0, width: 80, height: 22)
        alert.accessoryView = db
        alert.addButton(withTitle: L10n.text("attenuate.button"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        alert.beginSheetModal(for: window) { [session] r in
            guard r == .alertFirstButtonReturn else { return }
            session.editArea(.attenuate, db: max(-80, min(0, db.doubleValue)))
        }
    }

    /// For anyone who can't draw: a box by numbers, on a chosen track.
    @objc func editSpectrumNumerically(_ sender: Any?) {
        guard let window, !session.project.tracks.isEmpty else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = L10n.text("spectrum.title")
        alert.informativeText = L10n.text("spectrum.text")
        let fields = [L10n.text("spectrum.field.start"), L10n.text("spectrum.field.end"), L10n.text("spectrum.field.from"), L10n.text("spectrum.field.to"), L10n.text("spectrum.field.change")].map { label -> (String, NSTextField) in
            let f = NSTextField(string: "")
            f.setAccessibilityLabel(label)
            f.widthAnchor.constraint(equalToConstant: 90).isActive = true
            return (label, f)
        }
        let sel = session.selection
        fields[0].1.stringValue = String(format: "%.3f", session.project.seconds(sel?.lowerBound ?? session.playhead))
        fields[1].1.stringValue = String(format: "%.3f", session.project.seconds(sel?.upperBound ?? session.playhead + Frame(session.project.sampleRate / 10)))
        fields[2].1.stringValue = "2000"; fields[3].1.stringValue = "8000"; fields[4].1.stringValue = "-20"
        let action = NSPopUpButton(); action.addItems(withTitles: [L10n.text("spectrum.heal"), L10n.text("attenuate.button")]); action.setAccessibilityLabel(L10n.text("spectrum.action"))
        let track = NSPopUpButton(); track.addItems(withTitles: session.project.tracks.map(\.name)); track.setAccessibilityLabel(L10n.text("plugins.strip.track"))
        let grid = NSGridView(views: fields.map { [NSTextField(labelWithString: $0.0 + ":"), $0.1] } + [[NSTextField(labelWithString: L10n.text("spectrum.action") + ":"), action], [NSTextField(labelWithString: L10n.text("plugins.strip.track") + ":"), track]])
        grid.frame = NSRect(x: 0, y: 0, width: 260, height: 200)
        alert.accessoryView = grid
        alert.addButton(withTitle: L10n.text("button.apply"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        alert.beginSheetModal(for: window) { [session] r in
            guard r == .alertFirstButtonReturn else { return }
            let v = fields.map(\.1.doubleValue)
            session.spectralArea = .init(shape: .box(start: min(v[0], v[1]), end: max(v[0], v[1]), low: min(v[2], v[3]), high: max(v[2], v[3])),
                                         track: track.indexOfSelectedItem)
            session.editArea(action.indexOfSelectedItem == 0 ? .heal : .attenuate, db: max(-80, min(0, v[4])))
        }
    }

    /// View › Automation: the item's represented object is the kind of lane, or nil for none.
    @objc func showAutomation(_ sender: Any?) {
        timeline.shownAutomation = ((sender as? NSMenuItem)?.representedObject as? String).flatMap(AutomationLane.Param.init(rawValue:))
    }

    @objc func toggleStripLanes(_ sender: Any?) { timeline.showsStripLanes.toggle() }

    @objc func toggleSpectrogram(_ sender: Any?) {
        timeline.showsSpectrogram.toggle()
    }

    @objc func toggleAssistant(_ sender: Any?) {
        guard let split = window?.contentView as? NSSplitView, split.arrangedSubviews.count > 1 else { return }
        let view = split.arrangedSubviews[1]
        // Shows the panel and puts the keyboard in its field; hides it only from there. So one command
        // takes a keyboard or VoiceOver user to the field, wherever they were.
        if view.isHidden {
            view.isHidden = false
            split.setPosition(split.frame.width - 320, ofDividerAt: 0)
            assistant.focusRequest += 1
        } else if !assistant.fieldFocused {
            assistant.focusRequest += 1
        } else {
            view.isHidden = true
            window?.makeFirstResponder(timeline)
        }
        UserDefaults.standard.set(!view.isHidden, forKey: "assistant.visible")
    }

    /// From the command palette: always to the field, never away from it.
    @objc func askAssistant(_ sender: Any?) {
        guard let split = window?.contentView as? NSSplitView, split.arrangedSubviews.count > 1 else { return }
        let view = split.arrangedSubviews[1]
        if view.isHidden {
            view.isHidden = false
            split.setPosition(split.frame.width - 320, ofDividerAt: 0)
            UserDefaults.standard.set(true, forKey: "assistant.visible")
        }
        assistant.focusRequest += 1
    }

    @objc func toggleTranscript(_ sender: Any?) {
        transcript.isHidden.toggle()
        UserDefaults.standard.set(!transcript.isHidden, forKey: "transcript.visible")
    }

    /// File › Send to Flimmer…: the sound of a film that came from Flimmer goes back to it (docs/PLAN.md).
    @objc func sendToFlimmer(_ sender: Any?) {
        guard let window else { return }
        let model = FlimmerSendModel(session: session)
        let host = NSHostingController(rootView: AnyView(EmptyView()))
        host.rootView = AnyView(FlimmerSendSheet(model: model) { [weak host] in
            guard let sheet = host?.view.window else { return }
            window.endSheet(sheet)
        })
        window.contentViewController?.presentAsSheet(host) ?? {
            let sheet = NSWindow(contentViewController: host)
            window.beginSheet(sheet)
        }()
    }

    @objc func showRestore(_ sender: Any?) {
        guard let window else { return }
        let kind = (sender as? NSMenuItem)?.representedObject as? String
        let model = RestoreModel(session: session, kind: kind.flatMap(Restoration.Kind.init(rawValue:)) ?? .dehum)
        let host = NSHostingController(rootView: AnyView(EmptyView()))
        host.rootView = AnyView(RestoreSheet(model: model) { [weak host] in
            guard let sheet = host?.view.window else { return }
            window.endSheet(sheet)
        })
        window.contentViewController?.presentAsSheet(host) ?? {
            let sheet = NSWindow(contentViewController: host)
            window.beginSheet(sheet)
        }()
    }

    /// Audio › Find Speakers: each track as its speaker for a double-ender, the model
    /// otherwise; with a count ("2 Speakers") always the model, told how many.
    /// Audio › Find Speakers › Save Speaker as Voice Profile…: the consent sheet (VoiceProfiles.swift). Also what
    /// an agent's request opens (POST …/voice-profile/request); the user decides.
    @objc func saveVoiceProfile(_ sender: Any?) { showVoiceProfileSheet(speaker: (sender as? NSMenuItem)?.representedObject as? Int) }

    /// Shows the sheet unless one is already shown; false then.
    @discardableResult
    func showVoiceProfileSheet(speaker: Int?) -> Bool {
        guard let window, window.attachedSheet == nil else { return false }
        let host = NSHostingController(rootView: AnyView(EmptyView()))
        host.rootView = AnyView(VoiceProfileSheet(session: session, speaker: speaker) { [weak host] in
            guard let sheet = host?.view.window else { return }
            window.endSheet(sheet)
        })
        window.contentViewController?.presentAsSheet(host) ?? {
            window.beginSheet(NSWindow(contentViewController: host))
        }()
        return true
    }

    /// Audio › Split Speakers onto Tracks: the first track with two or more speakers (the selected one first).
    @objc func splitSpeakers(_ sender: Any?) {
        guard let t = splittableTrack else { return }
        session.perform("split_speakers", ["track": .string(t.uuidString)])
    }
    var splittableTrack: UUID? {
        let turns = session.project.placedTurns()
        let tracks = session.project.tracks.indices.filter { i in Set(turns.filter { $0.track == i }.map(\.speaker)).count > 1 }
        return tracks.first.map { session.project.tracks[$0].id }
    }

    @objc func findSpeakers(_ sender: Any?) {
        let p = session.project
        let tracks = p.tracks.filter { !$0.clips.isEmpty }.map(\.id)
        guard !tracks.isEmpty else { return }
        let count = (sender as? NSMenuItem)?.representedObject as? Int
        guard count == nil || Diarization.engine != nil else { return }
        let byTrack = count == nil && (p.hasOverlappingTracks || Diarization.engine == nil)
        // The first time: what the model is and where it comes from, before anything is fetched (the register).
        if !byTrack, let d = Diarization.engine as? FluidDiarizer, !d.isInstalled {
            ModelDownloadSheet.ask("diarisation", on: window) { [weak self] in
                guard let self else { return }
                self.session.status = L10n.text("modelDownload.downloading", L10n.text("settings.models.diarisation.title"))
                Task { @MainActor in
                    do {
                        try await d.install()
                        self.findSpeakers(sender)
                    } catch {
                        self.session.status = L10n.text("settings.models.failed", L10n.error(error))
                    }
                }
            }
            return
        }
        _ = JobRegistry.shared.startDiarization(session, byTrack: byTrack, tracks: tracks, minSpeakers: count, maxSpeakers: count)
        session.status = byTrack ? L10n.text("speakers.working.byTrack") : L10n.text("speakers.working")
    }

    @objc func showHistory(_ sender: Any?) { HistoryPanel.show(session) }

    /// Audio › Separate Stems: every track with audio into vocals, drums, bass and other.
    @objc func separateStems(_ sender: Any?) {
        let model = (sender as? NSMenuItem)?.representedObject as? String ?? "music4"
        guard Stems.isInstalled(model) else {
            session.status = L10n.error(StemError.modelMissing)
            NSSound.beep()
            return
        }
        if let t = session.project.tracks.first(where: { !$0.inserts.isEmpty && !$0.clips.isEmpty }) {
            session.status = L10n.error(StemError.hasInserts(t.name))
            NSSound.beep()
            return
        }
        _ = JobRegistry.shared.startSeparation(session, tracks: nil, model: model)
        session.status = model == "dialog" ? L10n.text("stems.working.soundtrack") : L10n.text("stems.working")
    }

    @objc func showPlugins(_ sender: Any?) {
        guard let window else { return }
        let host = NSHostingController(rootView: AnyView(EmptyView()))
        host.rootView = AnyView(PluginsSheet(session: session) { [weak host] in
            guard let sheet = host?.view.window else { return }
            window.endSheet(sheet)
        })
        window.contentViewController?.presentAsSheet(host) ?? {
            let sheet = NSWindow(contentViewController: host)
            window.beginSheet(sheet)
        }()
    }

    /// Audio › Mixer…: a window of its own beside the document's, so that a level can be set, and ridden,
    /// while the timeline is in reach and the sound plays (a sheet lay over the timeline). It is the
    /// document's: its undo is the document's undo, the menus work in it as in the document's window, the
    /// Space bar plays and stops, and it closes when the document's window does.
    private var mixerWindow: MixerWindow?
    @objc func showMixer(_ sender: Any?) {
        if let w = mixerWindow { w.makeKeyAndOrderFront(nil); return }
        let w = MixerWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.session = session
        w.isReleasedWhenClosed = false
        w.identifier = NSUserInterfaceItemIdentifier("mixer")
        w.title = L10n.text("mixer.window.title", session.name)
        w.contentViewController = NSHostingController(rootView: MixerSheet(session: session) { [weak w] in w?.close() })
        // The menus' actions that the document's window answers (Play, Undo, the operations) reach it from here too.
        w.nextResponder = self
        mixerWindow = w
        w.makeKeyAndOrderFront(nil)
        // Where it was put last time, and as large (it can be made lower: the strips then scroll). The
        // first time: under the document's window where the screen has room for it there, so that it
        // doesn't lie over the timeline it is opened to be used beside; otherwise at the bottom of the screen.
        if w.setFrameUsingName("JammerMixer") {
            w.setFrameAutosaveName("JammerMixer")
        } else if let main = window, let screen = main.screen?.visibleFrame {
            w.setFrameAutosaveName("JammerMixer")
            w.layoutIfNeeded()
            let size = w.frame.size
            let top = main.frame.minY - 8 >= screen.minY + size.height ? main.frame.minY - 8 : screen.minY + size.height
            let left = min(max(screen.minX, main.frame.minX), max(screen.minX, screen.maxX - size.width))
            w.setFrameTopLeftPoint(NSPoint(x: left, y: top))
        }
    }
    /// The mixer goes with its document, and so does the picture.
    func closeMixer() { mixerWindow?.close(); mixerWindow = nil; pictureWindow?.close(); pictureWindow = nil }

    private var pictureWindow: PictureWindow?
    /// The film beside the sound, in a window of its own: it follows the playhead.
    /// Listening on headphones through Apple's spatial mixer, for documents wider than stereo.
    @objc func toggleBinaural(_ sender: Any?) {
        EditorSession.binaural.toggle()
        session.say(EditorSession.binaural ? L10n.text("listen.binaural.on") : L10n.text("listen.binaural.off"), .info)
    }

    /// Audio › Follow Head Movements: binaural listening turns with headphones that have motion sensors.
    @objc func toggleFollowHead(_ sender: Any?) {
        EditorSession.followHead.toggle()
        if EditorSession.followHead { session.say(L10n.text("listen.head.on"), .info) }
        else { session.say(L10n.text("listen.head.off"), .info) }
    }

    /// Audio › Center Head: where the head points now becomes the front.
    @objc func recenterHead(_ sender: Any?) {
        HeadTracker.shared.recenter()
        session.say(L10n.text("listen.head.centred"), .info)
    }

    @objc func showPicture(_ sender: Any?) {
        if let w = pictureWindow { w.makeKeyAndOrderFront(nil); return }
        let w = PictureWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.session = session
        w.isReleasedWhenClosed = false
        w.identifier = NSUserInterfaceItemIdentifier("picture")
        w.title = L10n.text("picture.window.title", session.name)
        let follower = PictureFollower(session: session)
        w.follower = follower
        let hosting = NSHostingController(rootView: PictureSheet(session: session, follower: follower))
        // The window's size is the user's (and the first time 640 by 400): the view's own wishes don't resize it.
        hosting.sizingOptions = []
        w.contentViewController = hosting
        w.setContentSize(NSSize(width: 640, height: 400))
        w.nextResponder = self
        pictureWindow = w
        if !w.setFrameUsingName("JammerPicture") { w.center() }
        w.setFrameAutosaveName("JammerPicture")
        w.makeKeyAndOrderFront(nil)
    }

    @objc func performOperation(_ sender: Any?) {
        guard let item = (sender as? NSMenuItem)?.representedObject as? OperationItem else { return }
        session.perform(item.op, item.params)
    }

    /// Audio › Duck Under Speech…: the user ticks the tracks to lower (music, atmosphere); the others
    /// decide when. A guess is ticked in advance (the tracks with the fewest words per second, when
    /// there is a transcript), but it is only a guess: transcribing music gives words too.
    /// Audio › Check Against ACX Requirements…: measures, changes nothing, and says what was measured against what.
    @objc func checkACX(_ sender: Any?) {
        guard let window else { return }
        session.status = L10n.text("acx.working")
        Task { [session] in
            let rows = ACX.requirements(await session.acxMeasured())
            session.status = nil
            let failed = rows.filter { $0.pass == false }
            let alert = NSAlert()
            alert.messageText = failed.isEmpty ? L10n.text("acx.none") : L10n.count("acx.failed", failed.count)
            alert.informativeText = rows.map { r in
                // ACX's requirement is quoted as ACX publishes it (in English); what Jämmer measured and why, in the window's language.
                L10n.text("acx.row", r.pass == true ? L10n.text("acx.met") : r.pass == false ? L10n.text("acx.notMet") : L10n.text("acx.notJudged"), r.required,
                          L10n.message(r.measuredSaid.keyed)) + (r.noteSaid.map { "\n" + L10n.message($0.keyed) } ?? "")
            }.joined(separator: "\n\n") + "\n\n" + L10n.message(ACX.wordingSaid.keyed) + "\n\(ACX.source)"
            alert.addButton(withTitle: L10n.text("button.ok"))
            _ = await alert.beginSheetModal(for: window)
        }
    }

    /// Audio › Limit Peaks…: the ceiling is asked for; the selection, or the whole document, is limited.
    @objc func limitPeaks(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text("limit.title")
        alert.informativeText = session.selection == nil ? L10n.text("limit.text.document") : L10n.text("limit.text.selection")
        let field = NSTextField(string: "-1")
        field.alignment = .right
        field.setAccessibilityLabel(L10n.text("limit.ceiling.ax"))
        let unit = NSTextField(labelWithString: L10n.text("limit.ceiling.unit"))
        let row = NSStackView(views: [NSTextField(labelWithString: L10n.text("limit.ceiling")), field, unit])
        row.orientation = .horizontal
        row.spacing = 8
        field.widthAnchor.constraint(equalToConstant: 60).isActive = true
        row.frame = NSRect(x: 0, y: 0, width: 300, height: 26)
        alert.accessoryView = row
        alert.addButton(withTitle: L10n.text("limit.button"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [session] answer in
            MainActor.assumeIsolated {
                guard answer == .alertFirstButtonReturn else { return }
                // A comma is a decimal point to half the world, and a typographic minus is a minus.
                let typed = field.stringValue.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "−", with: "-").trimmingCharacters(in: .whitespaces)
                guard let ceiling = Double(typed), Limiter.ceilingRange.contains(ceiling) else {
                    session.status = L10n.text("limit.badCeiling")
                    NSSound.beep()
                    return
                }
                session.perform("limit", ["ceiling": .number(ceiling)])
            }
        }
    }

    @objc func duckUnderSpeech(_ sender: Any?) {
        guard let window else { return }
        let p = session.project
        let sounding = p.tracks.filter { !$0.isMuted && !$0.clips.isEmpty }
        guard sounding.count >= 2 else {
            session.status = L10n.text("duck.needsTwo")
            NSSound.beep()
            return
        }
        var words: [UUID: Double] = [:]
        for w in p.placedWords() { words[p.tracks[w.track].id, default: 0] += 1 }
        let density = sounding.map { t in (words[t.id] ?? 0) / max(1, p.seconds(t.clips.reduce(0) { $0 + $1.length })) }
        let most = density.max() ?? 0
        let alert = NSAlert()
        alert.messageText = L10n.text("duck.title")
        alert.informativeText = L10n.text("duck.text")
        let boxes = zip(sounding, density).map { t, d -> NSButton in
            let b = NSButton(checkboxWithTitle: t.name, target: nil, action: nil)
            b.state = most > 0 && d < most / 2 ? .on : .off
            return b
        }
        let stack = NSStackView(views: boxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: CGFloat(boxes.count) * 24)
        alert.accessoryView = stack
        alert.addButton(withTitle: L10n.text("duck.button"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        alert.beginSheetModal(for: window) { [session] answer in
            MainActor.assumeIsolated {
                guard answer == .alertFirstButtonReturn else { return }
                let lower = zip(sounding, boxes).filter { $0.1.state == .on }.map(\.0), under = zip(sounding, boxes).filter { $0.1.state == .off }.map(\.0)
                guard !lower.isEmpty, !under.isEmpty else {
                    session.status = lower.isEmpty ? L10n.text("duck.noneTicked") : L10n.text("duck.allTicked")
                    NSSound.beep()
                    return
                }
                session.perform("duck", ["tracks": .array(lower.map { .string($0.id.uuidString) }), "under": .array(under.map { .string($0.id.uuidString) })])
            }
        }
    }

    @objc func addMarker(_ sender: Any?) {
        let n = session.project.markers.count + 1
        session.perform("add_marker", ["name": .string(L10n.text("marker.default", String(n)))])
    }

    /// Asks for tempo and time signature from the start or from the playhead, then runs `set_tempo`.
    @objc func setTempo(_ sender: Any?) {
        guard let window else { return }
        let current = session.project.tempo.change(at: session.playhead)
        let alert = NSAlert()
        alert.messageText = L10n.text("tempo.title")
        alert.informativeText = L10n.text("tempo.text")
        let bpm = NSTextField(string: current.bpm.formatted(.number.precision(.fractionLength(0...3)).grouping(.never)))
        let beats = NSTextField(string: "\(current.meter.beats)")
        let unit = NSPopUpButton()
        unit.addItems(withTitles: ["1", "2", "4", "8", "16", "32"])
        unit.selectItem(withTitle: "\(current.meter.unit)")
        let fromPlayhead = NSButton(checkboxWithTitle: L10n.text("tempo.fromPlayhead", session.project.musicalPosition(at: session.playhead).description), target: nil, action: nil)
        fromPlayhead.state = session.playhead > 0 ? .on : .off
        fromPlayhead.isEnabled = session.playhead > 0
        for f in [bpm, beats] { f.widthAnchor.constraint(equalToConstant: 70).isActive = true }
        bpm.setAccessibilityLabel(L10n.text("tempo.bpm.ax"))
        beats.setAccessibilityLabel(L10n.text("tempo.beats.ax"))
        unit.setAccessibilityLabel(L10n.text("tempo.unit.ax"))
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: L10n.text("tempo.bpm")), bpm],
            [NSTextField(labelWithString: L10n.text("tempo.signature")), NSStackView(views: [beats, NSTextField(labelWithString: "/"), unit])],
            [NSGridCell.emptyContentView, fromPlayhead],
        ])
        grid.frame = NSRect(x: 0, y: 0, width: 300, height: 84)
        alert.accessoryView = grid
        alert.addButton(withTitle: L10n.text("tempo.set"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        alert.window.initialFirstResponder = bpm
        alert.beginSheetModal(for: window) { [session] response in
            guard response == .alertFirstButtonReturn else { return }
            let at = fromPlayhead.state == .on ? session.project.seconds(session.playhead) : 0
            session.perform("set_tempo", ["bpm": .number(bpm.doubleValue), "at": .number(at),
                                          "beats": .number(Double(beats.integerValue)),
                                          "unit": .number(Double(unit.titleOfSelectedItem ?? "4") ?? 4)])
        }
    }

    @objc func analyzeLoudness(_ sender: Any?) {
        Task {
            session.status = L10n.text("measure.working")
            let r = await session.analyze(session.selection)
            func f(_ v: Double?, _ unit: String) -> String { v.map { L10n.number($0, 1) + " " + unit } ?? "—" }
            session.status = session.selection == nil ? L10n.text("measure.done.all", f(r.integrated, "LUFS"), f(r.range, "LU"), f(r.truePeak, "dBTP")) : L10n.text("measure.done.selection", f(r.integrated, "LUFS"), f(r.range, "LU"), f(r.truePeak, "dBTP"))
        }
    }

    /// ⌘K: the keyboard to the omnibar.
    @objc func showCommandPalette(_ sender: Any?) {
        window?.makeKeyAndOrderFront(nil)
        omnibar.focusRequest += 1
    }

    /// A request typed in the omnibar: to the assistant, as from its own field (the same source, price question
    /// and checks), with the panel shown so that its answer is seen.
    func askFromOmnibar(_ text: String) {
        guard let split = window?.contentView as? NSSplitView, split.arrangedSubviews.count > 1 else { return }
        let view = split.arrangedSubviews[1]
        if view.isHidden {
            view.isHidden = false
            split.setPosition(split.frame.width - 320, ofDividerAt: 0)
            UserDefaults.standard.set(true, forKey: "assistant.visible")
        }
        assistant.input = text
        assistant.send()
    }

    @objc func transcribeVoiceTracks(_ sender: Any?) { startVoiceTranscription(splitTrack: nil) }

    @objc func splitAndTranscribeSpeakers(_ sender: Any?) {
        guard let track = splittableTrack else { return }
        startVoiceTranscription(splitTrack: track)
    }

    private func startVoiceTranscription(splitTrack: UUID?) {
        guard let window else { return }
        let alert = NSAlert()
        if !SpeechEngines.store.isInstalled(.multilingualWhisper) {
            alert.messageText = L10n.text("op.transcribe_voice_tracks.title")
            alert.informativeText = L10n.text("voiceTranscribe.model")
            alert.addButton(withTitle: L10n.text("settings.models"))
            alert.addButton(withTitle: L10n.text("button.cancel"))
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { SettingsWindow.show(pane: "models") }
            }
            return
        }
        alert.messageText = L10n.text(splitTrack == nil ? "op.transcribe_voice_tracks.title" : "voiceTranscribe.split")
        alert.informativeText = L10n.text("voiceTranscribe.ask")
        let names = NSButton(checkboxWithTitle: L10n.text("voiceTranscribe.names"), target: nil, action: nil)
        names.state = .on
        names.sizeToFit()
        alert.accessoryView = names
        alert.addButton(withTitle: L10n.text("transcript.transcribe"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                _ = try JobRegistry.shared.startVoiceTranscription(session, splitTrack: splitTrack, nameSpeakers: names.state == .on)
                if transcript.isHidden { toggleTranscript(nil) }
            } catch { session.say(L10n.error(error), .error) }
        }
    }

    @objc func exportTranscript(_ sender: Any?) {
        guard let window else { return }
        let project = session.project
        let indices = Set(project.placedWords().map(\.track)).sorted()
        guard !indices.isEmpty else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = session.name + ".txt"
        panel.allowsOtherFileTypes = false
        let formats = NSPopUpButton()
        formats.addItems(withTitles: ["TXT", "JSON", "SRT", "WebVTT"])
        let formatChoice = TranscriptSaveFormatChoice(panel: panel)
        formats.target = formatChoice
        formats.action = #selector(TranscriptSaveFormatChoice.changed(_:))
        formatChoice.changed(formats)
        let tracks = NSPopUpButton()
        tracks.addItem(withTitle: L10n.text("transcript.export.allTracks"))
        for index in indices {
            let item = NSMenuItem(title: project.tracks[index].name, action: nil, keyEquivalent: "")
            tracks.menu?.addItem(item)
        }
        let formatLabel = NSTextField(labelWithString: L10n.text("transcript.export.format"))
        let trackLabel = NSTextField(labelWithString: L10n.text("transcript.export.track"))
        formats.setAccessibilityLabel(formatLabel.stringValue)
        tracks.setAccessibilityLabel(trackLabel.stringValue)
        let grid = NSGridView(views: [[formatLabel, formats], [trackLabel, tracks]])
        grid.frame = NSRect(x: 0, y: 0, width: 320, height: 60)
        panel.accessoryView = grid
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            let format = formatChoice.format
            let selected = tracks.indexOfSelectedItem
            let ids: Set<UUID>? = selected > 0 ? [project.tracks[indices[selected - 1]].id] : nil
            Task {
                do {
                    try await Task.detached {
                        try format.data(project: project, tracks: ids).write(to: url, options: .atomic)
                    }.value
                    session.status = L10n.text("transcript.export.done", url.lastPathComponent)
                } catch { session.say(L10n.error(error), .error) }
            }
        }
    }

    @objc func exportAudio(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav, .aiff, UTType("org.xiph.flac") ?? .audio, .mpeg4Audio, UTType(filenameExtension: "opus") ?? .audio, .mp3]
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = session.name + ".wav"
        let model = ExportChoices(hasSelection: session.selection != nil, wide: session.project.channels > 2)
        panel.accessoryView = NSHostingView(rootView: ExportAccessory(model: model))
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let chosen = panel.url, let self else { return }
            let url = chosen.deletingPathExtension().appendingPathExtension(model.choice.fileExtension)
            var options = EditorSession.ExportOptions(encoding: model.choice.encoding, dither: model.dither, encoded: model.choice.encoded,
                                                      chapters: model.chapters, chaptersJSON: model.chaptersJSON)
            // Opus is always 48 kHz; for the rest, the rate chosen when it isn't the document's own.
            if model.sampleRate > 0, model.choice != .opus { options.sampleRate = model.sampleRate }
            if model.selectionOnly { options.range = self.session.selection }
            // After a loudness preset, a lossy file is delivered at the preset's target: measured as written, corrected, encoded again.
            options.loudness = self.session.deliveryTarget
            let session = self.session
            Task {
                session.status = L10n.text("export.working")
                do {
                    let delivery = try await session.export(to: url, options: options) { p in
                        Task { @MainActor in session.status = L10n.text("export.working.percent", String(Int(p * 100))) }
                    }
                    if let d = delivery, let l = d.loudness {
                        let name = url.lastPathComponent, loud = L10n.number(l, 1)
                        session.status = d.limitedByPeak ? L10n.text("export.done.loudness.peaks", name, loud)
                            : d.compensatedDB == 0 ? L10n.text("export.done.loudness.asEncoded", name, loud)
                            : L10n.text("export.done.loudness.compensated", name, loud, L10n.number(d.compensatedDB, 2, sign: true))
                    } else if let l = session.lastExportLimiter {
                        session.status = L10n.text("export.done.limiter", url.lastPathComponent, L10n.number(l.truePeakDB, 2).replacingOccurrences(of: "-", with: "−"), L10n.number(l.ceilingDB, 1).replacingOccurrences(of: "-", with: "−"))
                    } else {
                        session.status = L10n.text("export.done", url.lastPathComponent)
                    }
                } catch {
                    session.status = L10n.text("export.failed", L10n.error(error))
                }
            }
        }
    }

    /// File › Export Timeline…: the clips as an EDL, OTIO or DAWproject file for another program; nothing is
    /// rendered. What the format can't hold is said in the status line.
    @objc func exportTimeline(_ sender: Any?) {
        guard let window else { return }
        let formats = TimelineFormat.allCases
        let panel = NSSavePanel()
        panel.allowedContentTypes = formats.compactMap { UTType(filenameExtension: $0.fileExtension) }
        panel.nameFieldStringValue = session.name + ".otio"
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        let titles: [TimelineFormat: String] = [.edl: L10n.text("export.timeline.edl"), .otio: L10n.text("export.timeline.otio"), .dawproject: L10n.text("export.timeline.dawproject")]
        for f in formats { popup.addItem(withTitle: titles[f] ?? f.rawValue) }
        popup.selectItem(at: formats.firstIndex(of: .otio) ?? 0)
        popup.setAccessibilityLabel(L10n.text("export.timeline.format"))
        let chooser = TimelineFormatChooser(panel: panel, formats: formats)
        popup.target = chooser
        popup.action = #selector(TimelineFormatChooser.chosen(_:))
        let label = NSTextField(labelWithString: L10n.text("export.timeline.format"))
        let row = NSStackView(views: [label, popup])
        row.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        panel.accessoryView = row
        panel.beginSheetModal(for: window) { [weak self] response in
            withExtendedLifetime(chooser) {}
            guard response == .OK, let chosen = panel.url, let self else { return }
            let format = formats[popup.indexOfSelectedItem]
            let url = chosen.deletingPathExtension().appendingPathExtension(format.fileExtension)
            do {
                let file = try TimelineExport.make(self.session.project, name: self.session.name, format: format, appVersion: AgentRouter.appVersion)
                try file.data.write(to: url, options: .atomic)
                let done = L10n.text("export.done", url.lastPathComponent)
                self.session.status = file.warnings.isEmpty ? done
                    : L10n.text("import.done.notes", done, L10n.count("import.notes", file.warnings.count), L10n.message(file.warnings[0].keyed) + (file.warnings.count > 1 ? " …" : ""))
            } catch {
                self.session.status = L10n.text("export.failed", L10n.error(error))
            }
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let id = item.identifier?.rawValue, Commands.command(id) != nil else { return true }
        let (enabled, why) = availability(id, item: item)
        // A command that is off says why (SIBLINGS comfort list), here as the item's help tag.
        item.toolTip = enabled ? nil : why
        return enabled
    }

    /// Whether a command can run now and, if not, why, in the window's language; also sets the item's title and
    /// tick where they follow the state (Play/Stop, Show/Hide, the layout). One answer for the menu bar, the
    /// context menus and ⌘K.
    func availability(_ id: String, item: NSMenuItem? = nil) -> (Bool, String?) {
        let p = session.project
        let hasAudio = p.length > 0
        func needs(_ ok: Bool, _ reason: @autoclosure () -> String) -> (Bool, String?) { ok ? (true, nil) : (false, reason()) }
        let selection = L10n.text("reason.selection")
        let running = { (kind: String) in JobRegistry.shared.latest(kind, document: self.session.agentID).map { !$0.isFinished } ?? false }
        switch id {
        case "transport.play":
            item?.title = session.isPlaying ? L10n.text("transport.stop") : L10n.text("transport.play")
            return needs(hasAudio, L10n.text("reason.noAudio"))
        case "edit.cut", "edit.copy", "edit.delete", "audio.fadeIn", "audio.fadeOut", "audio.silence", "audio.crop", "view.zoomToSelection",
             "repair.attenuateFrequencies", "edit.deselectAll":
            return needs(session.selection != nil, selection)
        case "repair.healArea", "repair.attenuateArea":
            return needs(timeline.showsSpectrogram && session.spectralArea != nil, L10n.text("reason.spectralArea"))
        case "view.automation.strips":
            item?.state = timeline.showsStripLanes ? .on : .off
            return needs(timeline.shownAutomation != nil, L10n.text("reason.automation"))
        case "view.spectrogram":
            item?.title = timeline.showsSpectrogram ? L10n.text("view.showWaveform") : L10n.text("view.showSpectrogram")
            return (true, nil)
        case "view.assistant":
            let hidden = ((window?.contentView as? NSSplitView)?.arrangedSubviews.last?.isHidden) ?? true
            item?.title = hidden ? L10n.text("view.showAssistant") : assistant.fieldFocused ? L10n.text("view.hideAssistant") : L10n.text("view.askAssistant")
            return (true, nil)
        case "view.transcript":
            item?.title = transcript.isHidden ? L10n.text("view.showTranscript") : L10n.text("view.hideTranscript")
            return (true, nil)
        case "view.focusMode":
            item?.state = focusMode != nil ? .on : .off
            return (true, nil)
        case "file.save":
            item?.title = (session.linkedFile?.fileName ?? session.lostLink?.name).map { L10n.text("file.saveBack", $0) } ?? L10n.text("file.save")
            return (true, nil)
        case "file.duplicate":
            item?.title = session.wasLinked ? L10n.text("link.lost.saveCopy") : L10n.text("file.duplicate")
            return (true, nil)
        case "file.sendToFlimmer": return needs(p.imported?.app == "flimmer", L10n.text("reason.notFromFlimmer"))
        case "speech.saveVoiceProfile": return needs(!session.speakerPrints.isEmpty, L10n.text("reason.findSpeakersFirst"))
        case "file.exportTranscript", "edit.findInTranscript", "edit.findNext":
            return needs(!p.placedWords().isEmpty, L10n.text("reason.transcribeFirst"))
        case "edit.correctWord": return needs(!p.placedWords(in: session.selection).isEmpty, L10n.text("reason.selectWord"))
        case "edit.removeFillers": return needs(!p.placedWords().isEmpty, L10n.text("reason.transcribeFirst"))
        case "speech.transcribe": return needs(hasAudio, L10n.text("reason.noAudio")).0 ? needs(!running("transcribe"), L10n.text("reason.transcribing")) : (false, L10n.text("reason.noAudio"))
        case "speech.transcribeVoiceTracks":
            if running("transcribe") { return (false, L10n.text("reason.transcribing")) }
            return needs(!TrackSpeech.tracks(in: p).isEmpty, L10n.text("reason.noVoiceTracks"))
        case "speech.splitAndTranscribe":
            if running("transcribe") { return (false, L10n.text("reason.transcribing")) }
            return needs(splittableTrack != nil, L10n.text("reason.noSplittable"))
        case "speech.splitSpeakers": return needs(splittableTrack != nil, L10n.text("reason.noSplittable"))
        case "transport.binaural":
            item?.state = EditorSession.binaural ? .on : .off
            return needs(p.channels > 2, L10n.text("reason.surround"))
        case "transport.followHead":
            item?.state = EditorSession.followHead ? .on : .off
            return needs(EditorSession.binaural && p.channels > 2, L10n.text("reason.binauralFirst"))
        case "transport.centerHead": return needs(EditorSession.followHead, L10n.text("reason.followHeadFirst"))
        case "speech.cloneVoice": return needs(session.selection != nil && !p.transcripts.isEmpty, L10n.text("reason.selectTranscribed"))
        case "speech.overdub":
            if session.selection == nil { return (false, selection) }
            return needs(p.voices.contains { $0.deleted == nil }, L10n.text("reason.cloneFirst"))
        case "speech.deleteVoice": return needs(p.voices.contains { $0.deleted == nil }, L10n.text("reason.cloneFirst"))
        case "transport.previousMarker", "transport.nextMarker": return needs(!p.markers.isEmpty, L10n.text("reason.noMarkers"))
        case "track.rename", "track.mute", "track.solo":
            guard let t = currentTrack else { return (false, L10n.text("reason.chooseTrack")) }
            if id == "track.mute" { item?.state = t.isMuted ? .on : .off }
            if id == "track.solo" { item?.state = session.solo.contains(t.id) ? .on : .off }
            if id == "track.rename" { item?.title = L10n.text("track.rename.named", t.name) }
            return (true, nil)
        default: break
        }
        if id.hasPrefix("repair."), ["dehum", "declip", "declick", "denoise", "dereverb"].contains(String(id.dropFirst(7))) {
            if !hasAudio { return (false, L10n.text("reason.noAudio")) }
            return needs(!running("restore"), L10n.text("reason.repairing"))
        }
        if id.hasPrefix("view.automation.") {
            let kind = String(id.dropFirst("view.automation.".count))
            item?.state = (kind == "none" ? nil : kind) == timeline.shownAutomation?.rawValue ? .on : .off
            // Place and height are a track's in a document wider than stereo only.
            return needs(!["azimuth", "elevation"].contains(kind) || p.channels > 2, L10n.text("reason.surround"))
        }
        if id.hasPrefix("view.tool.") {
            let tool = String(id.dropFirst("view.tool.".count))
            item?.state = session.tool == tool ? .on : .off
            if ["lasso", "brush"].contains(tool), !Operations.spectralFreeform { return (false, L10n.text("reason.notInBuild")) }
            return (true, nil)
        }
        if id == "view.toolPalette" {
            item?.title = (toolPaletteView?.isHidden ?? true) ? L10n.text("view.toolPalette") : L10n.text("view.hideToolPalette")
            return (true, nil)
        }
        if id == "edit.split" { return needs(hasAudio, L10n.text("reason.noAudio")) }
        if id == "edit.stopJob" {
            let job = JobRegistry.shared.running(document: session.agentID).last
            item?.title = job.map { L10n.text("edit.stopJob.named", JobLine.label($0)) } ?? L10n.text("edit.stopJob")
            return needs(job != nil, L10n.text("reason.noJob"))
        }
        if id.hasPrefix("track.layout.order.") {
            // The order of a file that names no loudspeakers: offered only when the document has one.
            let open = p.unmaskedOrder
            item?.isHidden = open == nil
            if let item, let menu = item.menu, let i = menu.items.firstIndex(of: item), i > 0, menu.items[i - 1].isSeparatorItem { menu.items[i - 1].isHidden = open == nil }
            item?.state = open?.rawValue == String(id.dropFirst("track.layout.order.".count)) ? .on : .off
            return (open != nil, nil)
        }
        if id.hasPrefix("track.layout.") {
            item?.state = String(id.dropFirst("track.layout.".count)) == p.layout.rawValue ? .on : .off
            return (true, nil)
        }
        return (true, nil)
    }

    /// The track the Track menu acts on: the one last clicked in (or the only one).
    var currentTrack: Track? {
        let p = session.project
        if let id = session.currentTrack, let t = p.tracks.first(where: { $0.id == id }) { return t }
        return p.tracks.count == 1 ? p.tracks.first : nil
    }
}

// MARK: Transport

struct TransportBar: View {
    @Bindable var session: EditorSession
    let timeline: TimelineView

    var body: some View {
        HStack(spacing: 14) {
            Button { session.togglePlay() } label: {
                Label(session.isPlaying ? L10n.text("transport.stop") : L10n.text("transport.play"), systemImage: session.isPlaying ? "stop.fill" : "play.fill")
                    .labelStyle(.iconOnly)
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(session.isPlaying ? L10n.text("transport.stop.help") : L10n.text("transport.play.help"))
            Text(formatTime(session.project.seconds(session.playhead)))
                .font(.system(.title3, design: .monospaced).weight(.medium))
                .foregroundStyle(Theme.neonColor)
                .shadow(color: Theme.neonColor.opacity(0.5), radius: 6)
                // The time is never the one that gives way when the row is tight (the timecode beside it took its room).
                .lineLimit(1).fixedSize().layoutPriority(3)
                .accessibilityLabel(L10n.text("transport.playhead.ax"))
            Text("/ \(formatTime(session.duration))").font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
            // The picture's timecode at the playhead, when the document has one.
            if let tc = session.project.timecode {
                Text(tc.timecode(at: session.playhead, sampleRate: session.project.sampleRate).text)
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize().layoutPriority(2)
                    .accessibilityLabel(L10n.text("transport.timecode.label"))
                    .accessibilityValue(tc.timecode(at: session.playhead, sampleRate: session.project.sampleRate).text)
                    .accessibilityIdentifier("transport.timecode")
                    .help(L10n.text("transport.timecode.help", tc.rate.rawValue, tc.start.text))
            }
            Text(session.project.musicalPosition(at: session.playhead).description)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .help(L10n.text("transport.position.help"))
                .accessibilityLabel(L10n.text("transport.position.ax"))
            Spacer()
            HStack(spacing: 6) {
                Button { timeline.zoom(by: 0.5) } label: { Label(L10n.text("view.zoomOut"), systemImage: "minus.magnifyingglass").labelStyle(.iconOnly) }
                    .help(L10n.text("view.zoomOut.help"))
                Button { timeline.zoomToFit() } label: { Label(L10n.text("view.zoomToFit"), systemImage: "arrow.left.and.right").labelStyle(.iconOnly) }
                    .help(L10n.text("view.zoomToFit.help"))
                Button { timeline.zoom(by: 2) } label: { Label(L10n.text("view.zoomIn"), systemImage: "plus.magnifyingglass").labelStyle(.iconOnly) }
                    .help(L10n.text("view.zoomIn.help"))
            }
            .buttonStyle(.borderless)
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary).accessibilityHidden(true)
                Slider(value: $session.volume, in: 0...1).frame(width: 90)
                    .accessibilityLabel(L10n.text("transport.volume.ax"))
                    .accessibilityValue(Text(verbatim: "\(Int((session.volume * 100).rounded())) %"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 30)
        .padding(.bottom, 8)
        .background(Theme.inkColor)
    }
}

/// The document's running jobs in the status bar, each with its progress and a Stop that stops only that job
/// (COMFORT 7; Glimmer b8695e6): what it did is not applied, and the line says "Stopped. Nothing changed.".
struct JobLine: View {
    let session: EditorSession
    let jobs: [Job]

    static func label(_ job: Job) -> String {
        let percent = String(Int(job.progress * 100))
        return switch job.kind {
        case "transcribe": L10n.text("status.job.transcribing", percent)
        case "separate": L10n.text("status.job.separating", percent)
        case "diarize": L10n.text("status.job.diarizing", percent)
        case "freeze": L10n.text("status.job.freezing", percent)
        default: L10n.text("status.job.repairing", percent)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ForEach(jobs, id: \.id) { job in
                let label = Self.label(job)
                HStack(spacing: 5) {
                    Text(label).foregroundStyle(Theme.neonColor).lineLimit(1)
                    Button { JobRegistry.shared.stop(job.id, in: session) } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(L10n.text("job.stop.help", label))
                    .accessibilityLabel(L10n.text("job.stop.ax", label))
                    .accessibilityIdentifier("job.stop." + job.kind)
                }
            }
        }
        .layoutPriority(2)
    }
}

struct StatusBar: View {
    let session: EditorSession

    var body: some View {
        HStack(spacing: 16) {
            if let sel = session.selection {
                Text(L10n.text("status.selection", formatTime(session.project.seconds(sel.lowerBound)), formatTime(session.project.seconds(sel.upperBound)), formatTime(session.project.seconds(Frame(sel.count))))).lineLimit(1)
            } else {
                Text(L10n.text("status.noSelection"))
            }
            let jobs = JobRegistry.shared.running(document: session.agentID)
            if !jobs.isEmpty {
                JobLine(session: session, jobs: jobs)
            // What was just done is said whole; the selection's text gives way to it first.
            } else if let status = session.status {
                StateLine(kind: session.statusKind, text: status, font: .system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary).lineLimit(1).layoutPriority(2).help(status)
                    .accessibilityIdentifier("status.line")
            }
            Spacer()
            if !session.missingSources.isEmpty {
                StateLine(kind: .warning, text: L10n.count("status.missing", session.missingSources.count), font: .system(size: 11, design: .monospaced))
                    // Which, and, for one that Jämmer itself moved to the Trash, where to look.
                    .help(session.missingSources.map { s in MediaStorage.trashedHint(for: s.path, media: MediaStore.folder) ?? L10n.text("status.missing.where", s.name, s.path) }.joined(separator: "\n"))
            }
            Button {
                NSApp.sendAction(#selector(EditorWindowController.setTempo(_:)), to: nil, from: nil)
            } label: {
                let c = session.project.tempo.change(at: session.playhead)
                Text(session.project.tempo.isConstant ? L10n.text("status.tempo", c.bpm.formatted(.number.precision(.fractionLength(0...2))), c.meter.description) : L10n.text("status.tempo.map", c.bpm.formatted(.number.precision(.fractionLength(0...2))), c.meter.description))
            }
            .buttonStyle(.plain)
            .help(L10n.text("status.tempo.help"))
                        Text(verbatim: "\(Int(session.project.sampleRate)) Hz · " + (session.project.channels == 1 ? L10n.text("format.mono") : session.project.channels == 2 ? L10n.text("format.stereo") : L10n.layoutTitle(session.project.layout)))
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Theme.inkColor)
    }
}

// MARK: Export options

@MainActor
@Observable
final class ExportChoices {
    enum Choice: String, CaseIterable {
        case wav16 = "WAV 16-bit", wav24 = "WAV 24-bit", wavFloat = "WAV 32-bit float", aiff24 = "AIFF 24-bit",
             flac16 = "FLAC 16-bit", flac24 = "FLAC 24-bit", alac24 = "Apple Lossless (ALAC) 24-bit", aac = "AAC 192 kbit/s", opus = "Opus 96 kbit/s (Ogg)", mp3 = "MP3 160 kbit/s",
             // What ACX asks for at the least ("192 kbps or higher CBR").
             mp3High = "MP3 192 kbit/s",
             // 5.1, 7.1 and 7.1.4 documents: Apple's spatial codec in MP4.
             apac = "APAC (MP4)"
        var encoded: EncodedExportOptions? {
            switch self {
            case .wav16, .wav24, .wavFloat: nil
            case .aiff24: .init(format: .aiff, bitDepth: 24)
            case .flac16: .init(format: .flac, bitDepth: 16)
            case .flac24: .init(format: .flac, bitDepth: 24)
            case .alac24: .init(format: .alac, bitDepth: 24)
            case .aac: .init(format: .aac, bitRate: 192_000)
            case .opus: .init(format: .opus, bitRate: 96_000)
            case .mp3: .init(format: .mp3, bitRate: 160_000)
            case .mp3High: .init(format: .mp3, bitRate: 192_000)
            case .apac: .init(format: .apac)
            }
        }
        var encoding: WAVWriter.Encoding { self == .wav16 ? .int16 : (self == .wavFloat ? .float32 : .int24) }
        var fileExtension: String { encoded?.format.fileExtension ?? "wav" }
    }
    /// The format is remembered between exports.
    var choice: Choice = UserDefaults.standard.string(forKey: "export.format").flatMap(Choice.init(rawValue:)) ?? .wav24 {
        didSet { UserDefaults.standard.set(choice.rawValue, forKey: "export.format") }
    }
    /// MP3 (ID3), AAC and ALAC (a chapter track) and Opus (comments) carry chapters.
    var takesChapters: Bool { [.mp3, .mp3High, .aac, .alac24, .opus].contains(choice) }
    var chapters = true
    var chaptersJSON = false
    var encoding: WAVWriter.Encoding = .int24
    var dither = false
    /// 0: the document's own rate.
    var sampleRate = 0.0
    var selectionOnly = false
    let hasSelection: Bool
    /// A document wider than stereo: APAC is offered and MP3 and Opus (mono and stereo only) are not.
    let wide: Bool
    init(hasSelection: Bool, wide: Bool = false) {
        self.hasSelection = hasSelection
        self.wide = wide
        selectionOnly = hasSelection
        if wide, [.mp3, .mp3High, .opus].contains(choice) { choice = .wav24 }
        if !wide, choice == .apac { choice = .wav24 }
    }
    var offered: [Choice] {
        Choice.allCases.filter { c in
            if (c == .mp3 || c == .mp3High) && EncodedWriter.mp3Factory == nil { return false }
            return wide ? ![.mp3, .mp3High, .opus].contains(c) : c != .apac
        }
    }
}

struct ExportAccessory: View {
    @Bindable var model: ExportChoices

    var body: some View {
        Form {
            Picker(L10n.text("batch.format"), selection: $model.choice) {
                ForEach(model.offered, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Picker(L10n.text("export.sampleRate"), selection: $model.sampleRate) {
                Text(L10n.text("export.sampleRate.same")).tag(0.0)
                ForEach([44_100.0, 48_000, 88_200, 96_000, 22_050, 16_000], id: \.self) { Text(($0 / 1_000).formatted(.number.grouping(.never).locale(Locale.current)) + " kHz").tag($0) }
            }
            .disabled(model.choice == .opus)
            .help(L10n.text("export.sampleRate.help"))
            Toggle(L10n.text("export.dither"), isOn: $model.dither).disabled(model.choice != .wav16 && model.choice != .wav24)
                // Going down to 16 bits is where dither matters, so it is suggested there; it leaves audio
                // that is already 16 bits exactly as it was, so the suggestion costs nothing.
                .onChange(of: model.choice) { _, now in model.dither = now == .wav16 }
                .help(L10n.text("export.dither.help"))
            if model.choice.encoded != nil {
                Text(L10n.text("export.wavOnly")).font(.caption).foregroundStyle(.secondary)
            }
            Toggle(L10n.text("export.selectionOnly"), isOn: $model.selectionOnly).disabled(!model.hasSelection)
            Toggle(L10n.text("export.chapters"), isOn: $model.chapters).disabled(!model.takesChapters)
            Toggle(L10n.text("export.chaptersJSON"), isOn: $model.chaptersJSON)
        }
        .padding(12)
        .frame(width: 320)
    }
}

/// The mixer's window. The document's undo, and Space for play and stop as in the timeline.
final class MixerWindow: NSWindow, NSWindowDelegate {
    weak var session: EditorSession? { didSet { delegate = self } }
    // The document's undo: ⌘Z here takes back what was done here or in the timeline, in the one history.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { session?.document?.undoManager }
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
    // In front: a hand is on the mixer, and what it does should be heard at once.
    override func becomeKey() { super.becomeKey(); session?.mixerInUse(true) }
    override func resignKey() { super.resignKey(); session?.mixerInUse(false) }
    override func close() { session?.mixerInUse(false); super.close() }
    override func keyDown(with event: NSEvent) {
        // (A text field in the window takes its own keys before this is asked.)
        if event.keyCode == 49, event.modifierFlags.intersection([.command, .option, .control]).isEmpty { session?.togglePlay(); return }
        super.keyDown(with: event)
    }
}

/// Keeps the save panel's file type in sync with the transcript format.
@MainActor
private final class TranscriptSaveFormatChoice: NSObject {
    private weak var panel: NSSavePanel?
    private(set) var format: TranscriptExport = .txt

    init(panel: NSSavePanel) { self.panel = panel }

    @objc func changed(_ sender: NSPopUpButton) {
        guard TranscriptExport.allCases.indices.contains(sender.indexOfSelectedItem), let panel else { return }
        format = TranscriptExport.allCases[sender.indexOfSelectedItem]
        if let fileType = UTType(filenameExtension: format.rawValue) { panel.allowedContentTypes = [fileType] }
        let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = name + "." + format.rawValue
    }
}

/// Keeps the save panel's file name on the chosen timeline format's extension.
@MainActor
final class TimelineFormatChooser: NSObject {
    let panel: NSSavePanel
    let formats: [TimelineFormat]
    init(panel: NSSavePanel, formats: [TimelineFormat]) { self.panel = panel; self.formats = formats }
    @objc func chosen(_ sender: NSPopUpButton) {
        let f = formats[sender.indexOfSelectedItem]
        panel.nameFieldStringValue = (panel.nameFieldStringValue as NSString).deletingPathExtension + "." + f.fileExtension
    }
}
