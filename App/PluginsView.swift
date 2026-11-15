import AppKit
import AudioToolbox
import CoreAudioKit
import JammerAgent
import JammerCore
import JammerPlugins
import SwiftUI

/// Audio › Plugins…: the inserts on each track, safe mode, and the warning that plugins
/// are someone else's code.
struct PluginsSheet: View {
    let session: EditorSession
    let done: () -> Void
    @State private var trackID: UUID?
    @State private var catalogue: [PluginInfo] = []
    @State private var failed: [PluginCatalogue.Failure] = []
    @State private var scanning = false
    @State private var safeMode = EditorSession.pluginSafeMode

    private var track: Track? {
        session.project.tracks.first { $0.id == trackID } ?? session.project.tracks.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Plugins").font(.title2.bold())
            if session.project.tracks.count > 1 {
                Picker("Track", selection: Binding(get: { track?.id }, set: { trackID = $0 })) {
                    ForEach(session.project.tracks) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            if let track {
                List {
                    if track.inserts.isEmpty {
                        Text("No plugins on \(track.name). Add one below; it runs after the clips and before the track's gain.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(track.inserts) { insert in row(track, insert) }
                }
                .frame(minHeight: 170)
                .id(session.pluginsVersion)
                Menu("Add Plugin") {
                    if catalogue.isEmpty { Text("Looking for plugins…") }
                    ForEach(Dictionary(grouping: catalogue, by: \.manufacturer).sorted { $0.key < $1.key }, id: \.key) { group in
                        Menu(group.key) {
                            ForEach(group.value, id: \.id) { info in
                                Button(info.name) {
                                    session.perform("add_insert", ["track": .string(track.id.uuidString), "plugin": .string(info.id.description)])
                                }
                            }
                        }
                    }
                }
                .fixedSize()
            }
            if HostedPluginsController.available {
                HStack {
                    Button(scanning ? "Scanning…" : "Scan for CLAP Plugins") {
                        scanning = true
                        Task {
                            await HostedPluginsController.scan(force: true)
                            catalogue = await Task.detached { PluginCatalog.effects() }.value
                            failed = HostedPlugins.current().failed
                            scanning = false
                        }
                    }
                    .disabled(scanning)
                    .help("Looks in the CLAP plugin folders again. Each plugin is loaded in a helper process, so one that crashes can't affect Jämmer.")
                    Spacer()
                }
                ForEach(failed, id: \.name) { f in
                    HStack {
                        Text(f.reason == "blocked" ? "\(f.name) is switched off: it failed while it was in use." : "\(f.name) couldn't be used (\(f.reason == "timed_out" ? "it didn't answer" : f.reason)).")
                            .font(.callout).foregroundStyle(.orange)
                        Spacer()
                        if f.reason == "blocked", let key = HostedPlugins.current().blocked.first(where: { k in HostedPlugins.current().entries.flatMap(\.plugins).contains { PluginCatalogue.key($0) == k && $0.name == f.name } }) {
                            Button("Switch On") {
                                HostedPluginsController.unblock(key)
                                failed = HostedPlugins.current().failed
                                Task { catalogue = await Task.detached { PluginCatalog.effects() }.value }
                            }
                        }
                    }
                }
            }
            Divider()
            Toggle("Safe mode: run every Audio Unit in a separate process", isOn: $safeMode)
                .onChange(of: safeMode) { _, on in
                    EditorSession.pluginSafeMode = on
                    session.restartPlugins()
                }
            Text("Plugins are third-party code. CLAP plugins each run in a helper process of their own, never inside Jämmer. Audio Units run inside Jämmer; if one crashes or misbehaves, turn on safe mode: every Audio Unit then runs in macOS's separate plugin host process. Plugins play 0.3 s ahead, so a change is heard a moment later.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { done() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
        .task {
            catalogue = await Task.detached { PluginCatalog.effects() }.value
            failed = HostedPlugins.current().failed
        }
    }

    private func row(_ track: Track, _ insert: Insert) -> some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { !insert.bypass }, set: { on in
                session.perform("set_insert", ["track": .string(track.id.uuidString), "insert": .string(insert.id.uuidString), "bypass": .bool(!on)])
            })) { EmptyView() }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel("\(insert.name) on")
            VStack(alignment: .leading, spacing: 2) {
                Text(insert.name)
                if let f = session.inserts.failure(insert.id) {
                    Label(f.localizedDescription, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Button("Edit…") { PluginWindows.show(session, track: track.id, insert: insert.id) }
                .accessibilityLabel("Edit \(insert.name)")
                .disabled(session.inserts.instance(insert.id) == nil)
            Button { session.perform("remove_insert", ["track": .string(track.id.uuidString), "insert": .string(insert.id.uuidString)]) } label: {
                Label("Remove \(insert.name)", systemImage: "trash").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Remove \(insert.name)")
        }
    }
}

/// Plugin windows, one per insert.
@MainActor
enum PluginWindows {
    static var open: [UUID: PluginWindowController] = [:]

    static func show(_ session: EditorSession, track: UUID, insert: UUID) {
        if let w = open[insert] {
            w.showWindow(nil)
            return
        }
        guard let unit = session.inserts.instance(insert),
              let t = session.project.tracks.first(where: { $0.id == track }),
              let i = t.inserts.first(where: { $0.id == insert }) else { return }
        let c = PluginWindowController(session: session, track: track, insert: insert, unit: unit, title: "\(i.name) — \(t.name)")
        open[insert] = c
        c.showWindow(nil)
    }
}

/// Shows a plugin's own view (or sliders for its parameters) and stores what changes
/// in the document, as an undo step, shortly after the last change and on close.
final class PluginWindowController: NSWindowController, NSWindowDelegate {
    private weak var session: EditorSession?
    private let track: UUID
    private let insert: UUID
    private let unit: any InsertUnit
    /// The Audio Unit, when it is one (its own view and parameter observer); nil for VST 3 and CLAP.
    private var audioUnit: PluginInstance? { unit as? PluginInstance }
    private var token: AUParameterObserverToken?
    private var pending: Task<Void, Never>?

    init(session: EditorSession, track: UUID, insert: UUID, unit: any InsertUnit, title: String) {
        self.session = session
        self.track = track
        self.insert = insert
        self.unit = unit
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300), styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        w.center()
        if let au = audioUnit {
            au.au.requestViewController { [weak self] vc in
                DispatchQueue.main.async { self?.install(vc) }
            }
            token = au.au.parameterTree?.token(byAddingParameterObserver: { [weak self] _, _ in
                DispatchQueue.main.async { self?.schedule() }
            })
        } else {
            // VST 3 and CLAP run in a helper process; their own windows come later. Sliders from the parameter list.
            let host = NSHostingController(rootView: HostedPluginView(unit: unit) { [weak self] in self?.schedule() })
            w.contentViewController = host
            w.setContentSize(host.view.fittingSize)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func install(_ vc: NSViewController?) {
        guard let window else { return }
        if let vc {
            let size = vc.preferredContentSize.width > 0 ? vc.preferredContentSize : vc.view.frame.size
            window.contentViewController = vc
            if size.width > 0, size.height > 0 { window.setContentSize(size) }
        } else {
            guard let au = audioUnit else { return }
            let host = NSHostingController(rootView: GenericPluginView(unit: au))
            window.contentViewController = host
            window.setContentSize(host.view.fittingSize)
        }
    }

    private func schedule() {
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.commit()
        }
    }

    private func commit() {
        session?.commitPluginState(track: track, insert: insert, state: unit.captureState())
    }

    func windowWillClose(_ notification: Notification) {
        pending?.cancel()
        commit()
        if let token { audioUnit?.au.parameterTree?.removeParameterObserver(token) }
        PluginWindows.open[insert] = nil
    }
}

/// Sliders for a plugin without a view of its own.
struct GenericPluginView: View {
    let unit: PluginInstance
    @State private var tick = 0

    var body: some View {
        let params = unit.au.parameterTree?.allParameters ?? []
        Form {
            if params.isEmpty { Text("This plugin has no parameters to show.").foregroundStyle(.secondary) }
            ForEach(params, id: \.keyPath) { p in
                LabeledContent(p.displayName) {
                    HStack {
                        Slider(value: Binding(get: { Double(p.value) }, set: { p.value = AUValue($0); tick += 1 }),
                               in: Double(p.minValue)...Double(max(p.maxValue, p.minValue + 0.0001)))
                            .frame(width: 200)
                            .accessibilityLabel(p.displayName)
                            .accessibilityValue(p.string(fromValue: nil))
                        Text(p.string(fromValue: nil)).monospacedDigit().frame(width: 80, alignment: .trailing)
                    }
                }
                .id("\(p.keyPath)-\(tick)")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .frame(minHeight: 120)
    }
}

/// Sliders for a VST 3 or CLAP plugin, from its parameter list (the plugin itself lives in a
/// helper process, so there is no view of its own to embed).
struct HostedPluginView: View {
    let unit: any InsertUnit
    var changed: () -> Void
    @State private var params: [PluginParameter] = []
    @State private var problem: String?

    var body: some View {
        Form {
            if params.isEmpty { Text("This plugin has no parameters to show.").foregroundStyle(.secondary) }
            ForEach(params, id: \.identifier) { p in
                LabeledContent(p.name) {
                    HStack {
                        Slider(value: Binding(get: { p.value }, set: { set(p, $0) }), in: p.min...max(p.max, p.min + 0.0001))
                            .frame(width: 200)
                            .accessibilityLabel(p.name)
                            .accessibilityValue(p.value.formatted(.number.precision(.fractionLength(0...3))))
                        Text(p.value.formatted(.number.precision(.fractionLength(0...3)))).monospacedDigit().frame(width: 80, alignment: .trailing)
                    }
                }
            }
            if let problem { Text(problem).foregroundStyle(.orange) }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .frame(minHeight: 120)
        .onAppear { params = unit.parameters }
    }

    private func set(_ p: PluginParameter, _ value: Double) {
        do {
            try unit.set(p.identifier, to: value)
            if let i = params.firstIndex(where: { $0.identifier == p.identifier }) { params[i].value = value }
            problem = nil
            changed()
        } catch {
            problem = error.localizedDescription
        }
    }
}
