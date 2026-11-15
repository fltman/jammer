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

    init(session: EditorSession) {
        self.session = session
        timeline = TimelineView(session: session)
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
        let stack = NSStackView(views: [transport, timeline, statusBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        stack.setHuggingPriority(.defaultHigh, for: .vertical)
        transport.setContentHuggingPriority(.required, for: .vertical)
        statusBar.setContentHuggingPriority(.required, for: .vertical)
        timeline.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = stack
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

    @objc func performOperation(_ sender: Any?) {
        guard let item = (sender as? NSMenuItem)?.representedObject as? OperationItem else { return }
        session.perform(item.op, item.params)
    }

    @objc func addMarker(_ sender: Any?) {
        let n = session.project.markers.count + 1
        session.perform("add_marker", ["name": .string("Marker \(n)")])
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
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = session.name + ".wav"
        let model = ExportChoices(hasSelection: session.selection != nil)
        panel.accessoryView = NSHostingView(rootView: ExportAccessory(model: model))
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            var options = EditorSession.ExportOptions(encoding: model.encoding, dither: model.dither)
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
            if let status = session.status { Text(status).foregroundStyle(Theme.neonColor).lineLimit(1) }
            Spacer()
            if !session.missingSources.isEmpty {
                Label("\(session.missingSources.count) missing file(s)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
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
            Picker("Format", selection: $model.encoding) {
                Text("WAV 16-bit").tag(WAVWriter.Encoding.int16)
                Text("WAV 24-bit").tag(WAVWriter.Encoding.int24)
                Text("WAV 32-bit float").tag(WAVWriter.Encoding.float32)
            }
            Toggle("Dither (TPDF)", isOn: $model.dither).disabled(model.encoding == .float32)
            Toggle("Selection only", isOn: $model.selectionOnly).disabled(!model.hasSelection)
        }
        .padding(12)
        .frame(width: 320)
    }
}
