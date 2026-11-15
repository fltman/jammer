import AppKit
import JammerAgent
import JammerCore
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
    private var assistantView: NSView!

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
        let stack = NSStackView(views: [transport, timeline, transcript, statusBar])
        transcript.isHidden = !UserDefaults.standard.bool(forKey: "transcript.visible")
        transcript.heightAnchor.constraint(equalTo: timeline.heightAnchor, multiplier: 0.45).isActive = true
        transcript.setContentHuggingPriority(.defaultLow, for: .vertical)
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        stack.setHuggingPriority(.defaultHigh, for: .vertical)
        transport.setContentHuggingPriority(.required, for: .vertical)
        statusBar.setContentHuggingPriority(.required, for: .vertical)
        timeline.setContentHuggingPriority(.defaultLow, for: .vertical)
        let assistantHost = NSHostingView(rootView: AssistantView(model: assistant))
        assistantHost.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        assistantHost.isHidden = !UserDefaults.standard.bool(forKey: "assistant.visible")
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(stack)
        split.addArrangedSubview(assistantHost)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        window.contentView = split
        DispatchQueue.main.async { split.setPosition(split.frame.width - 320, ofDividerAt: 0) }
        window.center()
        window.setFrameAutosaveName("JammerEditor")
        window.makeFirstResponder(timeline.firstResponderView)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func windowDidBecomeKey(_ notification: Notification) {
        window?.makeFirstResponder(timeline.firstResponderView)
    }

    func windowWillClose(_ notification: Notification) { session.stop() }

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
        panel.message = "Choose each speaker's own recording. Jämmer adds them as tracks and lines them up with the first track."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            let urls = panel.urls
            let session = self.session
            Task {
                session.status = "Importing \(urls.count) track\(urls.count == 1 ? "" : "s")…"
                var p = session.project
                var added: [UUID] = []
                for url in urls {
                    do {
                        let r = try await Task.detached { try AudioImporter.importFile(url, mediaFolder: MediaStore.folder) }.value
                        added.append(p.addTrack(source: r.source, name: url.deletingPathExtension().lastPathComponent).id)
                    } catch {
                        session.status = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
                        return
                    }
                }
                guard p.tracks.count > 1 else {
                    session.commit(p, action: "Import Tracks")
                    session.status = "Imported \(added.count) tracks."
                    return
                }
                session.status = "Lining up the tracks…"
                let pool = session.pool
                let (aligned, notes) = await Task.detached { () -> (Project, [String]) in
                    var q = p
                    // The call recording (where everyone is heard) makes the best reference.
                    let reference = q.suggestedReference(pool: pool) ?? q.tracks[0].id
                    let others = q.tracks.map(\.id).filter { $0 != reference }
                    let results = q.alignTracks(to: reference, tracks: others, pool: pool, minConfidence: 0.3)
                    var notes = ["reference \(q.tracks.first { $0.id == reference }?.name ?? "?")"]
                    for id in others {
                        guard let t = q.tracks.first(where: { $0.id == id }), let r = results[id] else { continue }
                        if r.confidence < 0.3 {
                            notes.append("\(t.name): no clear match (\(String(format: "%.2f", r.confidence))), left at the start")
                        } else {
                            var note = "\(t.name): \(String(format: "%+.3f", q.seconds(r.offset))) s"
                            // Recorders' clocks can disagree; say so when they part noticeably.
                            if let d = q.drift(of: id, against: reference, pool: pool), d.start.confidence > 0.5, d.end.confidence > 0.5,
                               abs(d.partsPerMillion) > 10 {
                                note += String(format: ", drifts %.0f ms per hour", d.partsPerMillion * 3.6)
                            }
                            notes.append(note)
                        }
                    }
                    return (q, notes)
                }.value
                session.commit(aligned, action: "Import Tracks")
                session.status = "Imported and lined up: " + notes.joined(separator: "; ")
            }
        }
    }

    @objc func toggleAssistant(_ sender: Any?) {
        guard let split = window?.contentView as? NSSplitView, split.arrangedSubviews.count > 1 else { return }
        let view = split.arrangedSubviews[1]
        view.isHidden.toggle()
        UserDefaults.standard.set(!view.isHidden, forKey: "assistant.visible")
        if !view.isHidden { split.setPosition(split.frame.width - 320, ofDividerAt: 0) }
    }

    @objc func toggleTranscript(_ sender: Any?) {
        transcript.isHidden.toggle()
        UserDefaults.standard.set(!transcript.isHidden, forKey: "transcript.visible")
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

    @objc func performOperation(_ sender: Any?) {
        guard let item = (sender as? NSMenuItem)?.representedObject as? OperationItem else { return }
        session.perform(item.op, item.params)
    }

    @objc func addMarker(_ sender: Any?) {
        let n = session.project.markers.count + 1
        session.perform("add_marker", ["name": .string("Marker \(n)")])
    }

    /// Asks for tempo and time signature from the start or from the playhead, then runs `set_tempo`.
    @objc func setTempo(_ sender: Any?) {
        guard let window else { return }
        let current = session.project.tempo.change(at: session.playhead)
        let alert = NSAlert()
        alert.messageText = "Set Tempo"
        alert.informativeText = "Tempo in quarter notes per minute. Tempo changes move with the audio when you delete or insert."
        let bpm = NSTextField(string: current.bpm.formatted(.number.precision(.fractionLength(0...3)).grouping(.never)))
        let beats = NSTextField(string: "\(current.meter.beats)")
        let unit = NSPopUpButton()
        unit.addItems(withTitles: ["1", "2", "4", "8", "16", "32"])
        unit.selectItem(withTitle: "\(current.meter.unit)")
        let fromPlayhead = NSButton(checkboxWithTitle: "From the playhead (\(session.project.musicalPosition(at: session.playhead)))", target: nil, action: nil)
        fromPlayhead.state = session.playhead > 0 ? .on : .off
        fromPlayhead.isEnabled = session.playhead > 0
        for f in [bpm, beats] { f.widthAnchor.constraint(equalToConstant: 70).isActive = true }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "BPM:"), bpm],
            [NSTextField(labelWithString: "Time signature:"), NSStackView(views: [beats, NSTextField(labelWithString: "/"), unit])],
            [NSGridCell.emptyContentView, fromPlayhead],
        ])
        grid.frame = NSRect(x: 0, y: 0, width: 300, height: 84)
        alert.accessoryView = grid
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
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
            session.status = "Measuring…"
            let r = await session.analyze(session.selection)
            func f(_ v: Double?, _ unit: String) -> String { v.map { String(format: "%.1f %@", $0, unit) } ?? "—" }
            session.status = "\(session.selection == nil ? "All" : "Selection"): \(f(r.integrated, "LUFS")), range \(f(r.range, "LU")), true peak \(f(r.truePeak, "dBTP"))"
        }
    }

    @objc func showCommandPalette(_ sender: Any?) {
        guard let window else { return }
        CommandPalette.show(over: window, session: session, timeline: timeline)
    }

    @objc func exportAudio(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav, .aiff, UTType("org.xiph.flac") ?? .audio, .mpeg4Audio, UTType(filenameExtension: "opus") ?? .audio, .mp3]
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = session.name + ".wav"
        let model = ExportChoices(hasSelection: session.selection != nil)
        panel.accessoryView = NSHostingView(rootView: ExportAccessory(model: model))
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let chosen = panel.url, let self else { return }
            let url = chosen.deletingPathExtension().appendingPathExtension(model.choice.fileExtension)
            var options = EditorSession.ExportOptions(encoding: model.choice.encoding, dither: model.dither, encoded: model.choice.encoded,
                                                      chapters: model.chapters, chaptersJSON: model.chaptersJSON)
            if model.selectionOnly { options.range = self.session.selection }
            let session = self.session
            Task {
                session.status = "Exporting…"
                do {
                    try await session.export(to: url, options: options) { p in
                        Task { @MainActor in session.status = "Exporting… \(Int(p * 100)) %" }
                    }
                    session.status = "Exported \(url.lastPathComponent)"
                } catch {
                    session.status = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(togglePlayback(_:)) {
            item.title = session.isPlaying ? "Stop" : "Play"
            return session.project.length > 0
        }
        if item.action == #selector(zoomToSelection(_:)) { return session.selection != nil }
        if item.action == #selector(toggleAssistant(_:)) {
            let hidden = ((window?.contentView as? NSSplitView)?.arrangedSubviews.last?.isHidden) ?? true
            item.title = hidden ? "Show Assistant" : "Hide Assistant"
            return true
        }
        if item.action == #selector(toggleTranscript(_:)) {
            item.title = transcript.isHidden ? "Show Transcript" : "Hide Transcript"
            return true
        }
        if item.action == #selector(showRestore(_:)) {
            return session.project.length > 0 && !(JobRegistry.shared.latest("restore", document: session.agentID).map { !$0.isFinished } ?? false)
        }
        if item.action == #selector(performOperation(_:)), let op = (item.representedObject as? OperationItem)?.op {
            let needsRange: Set<String> = ["delete", "silence", "crop", "fade_in", "fade_out", "cut", "copy"]
            return !needsRange.contains(op) || session.selection != nil
        }
        return true
    }
}

// MARK: Transport

struct TransportBar: View {
    @Bindable var session: EditorSession
    let timeline: TimelineView

    var body: some View {
        HStack(spacing: 14) {
            Button { session.togglePlay() } label: {
                Image(systemName: session.isPlaying ? "stop.fill" : "play.fill").frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(session.isPlaying ? "Stop (Space)" : "Play (Space)")
            .accessibilityLabel(session.isPlaying ? "Stop" : "Play")
            Text(formatTime(session.project.seconds(session.playhead)))
                .font(.system(.title3, design: .monospaced).weight(.medium))
                .foregroundStyle(Theme.neonColor)
                .shadow(color: Theme.neonColor.opacity(0.5), radius: 6)
                .accessibilityLabel("Playhead")
            Text("/ \(formatTime(session.duration))").font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
            Text(session.project.musicalPosition(at: session.playhead).description)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .help("Bar.beat.tick at the playhead")
                .accessibilityLabel("Bar, beat and tick")
            Spacer()
            HStack(spacing: 6) {
                Button { timeline.zoom(by: 0.5) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom Out (⌘−)")
                Button { timeline.zoomToFit() } label: { Image(systemName: "arrow.left.and.right") }
                    .help("Zoom to Fit (⌘0)")
                Button { timeline.zoom(by: 2) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom In (⌘+)")
            }
            .buttonStyle(.borderless)
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                Slider(value: $session.volume, in: 0...1).frame(width: 90).accessibilityLabel("Playback volume")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 30)
        .padding(.bottom, 8)
        .background(Theme.inkColor)
    }
}

struct StatusBar: View {
    let session: EditorSession

    var body: some View {
        HStack(spacing: 16) {
            if let sel = session.selection {
                Text("Selection \(formatTime(session.project.seconds(sel.lowerBound)))–\(formatTime(session.project.seconds(sel.upperBound))) (\(formatTime(session.project.seconds(Frame(sel.count)))))")
            } else {
                Text("No selection")
            }
            if let job = JobRegistry.shared.running.first(where: { $0.documentID == session.agentID }) {
                Text("\(job.kind == "transcribe" ? "Transcribing" : "Repairing")… \(Int(job.progress * 100)) %")
                    .foregroundStyle(Theme.neonColor)
            } else if let status = session.status { Text(status).foregroundStyle(Theme.neonColor).lineLimit(1) }
            Spacer()
            if !session.missingSources.isEmpty {
                Label("\(session.missingSources.count) missing file(s)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Button {
                NSApp.sendAction(#selector(EditorWindowController.setTempo(_:)), to: nil, from: nil)
            } label: {
                let c = session.project.tempo.change(at: session.playhead)
                Text("\(c.bpm.formatted(.number.precision(.fractionLength(0...2)))) BPM \(c.meter.description)\(session.project.tempo.isConstant ? "" : " (map)")")
            }
            .buttonStyle(.plain)
            .help("Tempo and time signature at the playhead. Click to change.")
                        Text("\(Int(session.project.sampleRate)) Hz · \(session.project.channels == 1 ? "mono" : (session.project.channels == 2 ? "stereo" : "\(session.project.channels) ch"))")
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
             flac16 = "FLAC 16-bit", flac24 = "FLAC 24-bit", alac24 = "Apple Lossless (ALAC) 24-bit", aac = "AAC 192 kbit/s", opus = "Opus 96 kbit/s (Ogg)", mp3 = "MP3 160 kbit/s"
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
            }
        }
        var encoding: WAVWriter.Encoding { self == .wav16 ? .int16 : (self == .wavFloat ? .float32 : .int24) }
        var fileExtension: String { encoded?.format.fileExtension ?? "wav" }
    }
    var choice: Choice = .wav24
    var chapters = true
    var chaptersJSON = false
    var encoding: WAVWriter.Encoding = .int24
    var dither = false
    var selectionOnly = false
    let hasSelection: Bool
    init(hasSelection: Bool) {
        self.hasSelection = hasSelection
        selectionOnly = hasSelection
    }
}

struct ExportAccessory: View {
    @Bindable var model: ExportChoices

    var body: some View {
        Form {
            Picker("Format", selection: $model.choice) {
                ForEach(ExportChoices.Choice.allCases.filter { $0 != .mp3 || EncodedWriter.mp3Factory != nil }, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Toggle("Dither (TPDF)", isOn: $model.dither).disabled(model.choice != .wav16 && model.choice != .wav24)
            if model.choice.encoded != nil {
                Text("Broadcast Wave metadata and markers are kept in WAV only.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Selection only", isOn: $model.selectionOnly).disabled(!model.hasSelection)
            Toggle("Chapters from markers (MP3)", isOn: $model.chapters).disabled(model.choice != .mp3)
            Toggle("Also save chapters as JSON (Podcasting 2.0)", isOn: $model.chaptersJSON)
        }
        .padding(12)
        .frame(width: 320)
    }
}
