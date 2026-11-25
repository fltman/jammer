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
    /// The catalogue has been read once: an empty one then means none were found, not still looking (COMFORT 49).
    @State private var catalogueRead = false
    @State private var failed: [PluginCatalogue.Failure] = []
    @State private var scanning = false
    @State private var safeMode = EditorSession.pluginSafeMode

    /// What plugins sit on: a track or a bus.
    struct Strip: Identifiable {
        let id: UUID
        let name: String
        let inserts: [Insert]
        let isBus: Bool
    }
    private var strips: [Strip] {
        session.project.tracks.map { Strip(id: $0.id, name: $0.name, inserts: $0.inserts, isBus: false) }
            + session.project.buses.map { Strip(id: $0.id, name: $0.name, inserts: $0.inserts, isBus: true) }
            // The master is offered once the document has a mixer; before that a plugin on the one track is the same thing.
            + (session.project.usesMixer ? [Strip(id: Master.id, name: L10n.text("strip.master"), inserts: session.project.master.inserts, isBus: true)] : [])
    }
    private var track: Strip? {
        #if DEBUG
        // A debug build started with `-pluginsStrip <name>` opens the sheet on that strip (for a picture).
        if trackID == nil, let name = UserDefaults.standard.string(forKey: "pluginsStrip"), let s = strips.first(where: { $0.name == name }) { return s }
        #endif
        return strips.first { $0.id == trackID } ?? strips.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("plugins.title")).font(.title2.bold())
            if strips.count > 1 {
                Picker(session.project.buses.isEmpty ? L10n.text("plugins.strip.track") : L10n.text("plugins.strip.trackOrBus"), selection: Binding(get: { track?.id }, set: { trackID = $0 })) {
                    ForEach(strips) { Text($0.id == Master.id ? L10n.text("strip.master") : $0.isBus ? L10n.text("strip.bus.named", $0.name) : $0.name).tag(Optional($0.id)) }
                }
            }
            if let track {
                List {
                    if track.inserts.isEmpty {
                        Text(track.id == Master.id ? L10n.text("plugins.none.master")
                             : track.isBus ? L10n.text("plugins.none.bus", track.name)
                                         : L10n.text("plugins.none.track", track.name))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(track.inserts) { insert in row(track, insert) }
                }
                .frame(minHeight: 170)
                .id(session.pluginsVersion)
                Menu(L10n.text("plugins.add")) {
                    if catalogue.isEmpty { Text(catalogueRead ? L10n.text("plugins.noneFound") : L10n.text("plugins.looking")) }
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
                    Button(scanning ? L10n.text("plugins.scanning") : L10n.text("plugins.scan")) {
                        scanning = true
                        Task {
                            await HostedPluginsController.scan(force: true)
                            catalogue = await Task.detached { PluginCatalog.effects() }.value
                            failed = HostedPlugins.current().failed
                            scanning = false
                        }
                    }
                    .disabled(scanning)
                    .help(L10n.text("plugins.scan.help"))
                    Spacer()
                }
                ForEach(failed, id: \.name) { f in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        // Still listed from before: a warning. Not usable: an error. Told apart by the symbol.
                        Image(systemName: (f.kept ? StateKind.warning : .error).symbol).foregroundStyle((f.kept ? StateKind.warning : .error).color).accessibilityHidden(true)
                        Text(f.reason == "blocked" ? L10n.text("plugins.failed.blocked", f.name)
                             : f.kept ? L10n.text("plugins.failed.kept", f.name, f.reason == "timed_out" ? L10n.text("plugins.failed.why.timedOut") : f.reason == "scan_failed" ? L10n.text("plugins.failed.why.noAnswer") : f.reason)
                             : f.reason == "timed_out" ? L10n.text("plugins.failed.timedOut", f.name)
                             : f.reason == "scan_failed" ? L10n.text("plugins.failed.noAnswer", f.name)
                             : L10n.text("plugins.failed.other", f.name, f.reason))
                            .font(.callout)
                        Spacer()
                        if f.reason == "blocked", let key = HostedPlugins.current().blocked.first(where: { k in HostedPlugins.current().entries.flatMap(\.plugins).contains { PluginCatalogue.key($0) == k && $0.name == f.name } }) {
                            Button(L10n.text("plugins.switchOn")) {
                                HostedPluginsController.unblock(key)
                                failed = HostedPlugins.current().failed
                                Task { catalogue = await Task.detached { PluginCatalog.effects() }.value }
                            }
                        }
                    }
                }
            }
            Divider()
            Toggle(L10n.text("plugins.safeMode"), isOn: $safeMode)
                .onChange(of: safeMode) { _, on in
                    EditorSession.pluginSafeMode = on
                    session.restartPlugins()
                }
            Text((HostedPluginsController.available ? L10n.text("plugins.about.hosted") : L10n.text("plugins.about.audioUnits")) + " " + L10n.text("plugins.about.ahead"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L10n.text("button.done")) { done() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
        // Esc closes it as Done does (COMFORT 42): it changes nothing that isn't already a step.
        .onExitCommand { done() }
        .task {
            catalogue = await Task.detached { PluginCatalog.effects() }.value
            catalogueRead = true
            failed = HostedPlugins.current().failed
        }
    }

    private func row(_ track: Strip, _ insert: Insert) -> some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { !insert.bypass }, set: { on in
                session.perform("set_insert", ["track": .string(track.id.uuidString), "insert": .string(insert.id.uuidString), "bypass": .bool(!on)])
            })) { EmptyView() }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel(L10n.text("plugins.on.ax", insert.name))
            VStack(alignment: .leading, spacing: 2) {
                Text(insert.name)
                if let f = session.inserts.failure(insert.id) {
                    StateLine(kind: .error, text: L10n.error(f))
                }
            }
            Spacer()
            // A sidechain key, where the build has them and the plugin has the input: the track or bus the
            // plugin listens to. (Not on the master; and never the strip the plugin sits on.)
            if Operations.sidechain, track.id != Master.id, session.inserts.instance(insert.id)?.hasKeyInput == true {
                let sources = session.project.tracks.map { ($0.id, $0.name) } + session.project.buses.map { ($0.id, L10n.text("strip.bus.named", $0.name)) }
                let now = insert.key.flatMap { k in sources.first { $0.0 == k }?.1 }
                Menu(now.map { L10n.text("plugins.key", $0) } ?? L10n.text("plugins.key.none")) {
                    Button((insert.key == nil ? "✓ " : "") + L10n.text("plugins.key.choice.none")) {
                        session.perform("set_insert", ["track": .string(track.id.uuidString), "insert": .string(insert.id.uuidString), "key": .string("none")])
                    }
                    ForEach(sources.filter { $0.0 != track.id }, id: \.0) { source in
                        Button((insert.key == source.0 ? "✓ " : "") + source.1) {
                            session.perform("set_insert", ["track": .string(track.id.uuidString), "insert": .string(insert.id.uuidString), "key": .string(source.0.uuidString)])
                        }
                    }
                }
                .fixedSize()
                .accessibilityLabel(L10n.text("plugins.key.ax", insert.name))
                .accessibilityIdentifier("plugins.key")
                .help(L10n.text("plugins.key.help"))
            }
            Button(L10n.text("plugins.edit")) { PluginWindows.show(session, track: track.id, insert: insert.id) }
                .accessibilityLabel(L10n.text("plugins.edit.ax", insert.name))
                .disabled(session.inserts.instance(insert.id) == nil)
            Button { session.perform("remove_insert", ["track": .string(track.id.uuidString), "insert": .string(insert.id.uuidString)]) } label: {
                Label(L10n.text("button.remove.ax", insert.name), systemImage: "trash").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(L10n.text("button.remove.ax", insert.name))
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
              let t = session.project.strip(track),
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
    /// Something changed since the last commit. It is committed when the mouse comes up in this window, and when the
    /// window stops being key or closes: a drag with a pause in it is still one step (COMFORT 9), never a timer.
    private var dirty = false
    private var mouseUp: Any?

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
        mouseUp = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            if let self, event.window === self.window { DispatchQueue.main.async { self.commitIfChanged() } }
            return event
        }
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
        dirty = true
        // A change made with no mouse button held (a value typed in the plugin's own field): it goes when the window
        // stops being key or closes.
    }

    private func commitIfChanged() {
        guard dirty else { return }
        dirty = false
        session?.commitPluginState(track: track, insert: insert, state: unit.captureState())
    }

    func windowDidResignKey(_ notification: Notification) { commitIfChanged() }

    func windowWillClose(_ notification: Notification) {
        commitIfChanged()
        if let mouseUp { NSEvent.removeMonitor(mouseUp) }
        mouseUp = nil
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
            if params.isEmpty { Text(L10n.text("plugins.noParameters")).foregroundStyle(.secondary) }
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
            if params.isEmpty { Text(L10n.text("plugins.noParameters")).foregroundStyle(.secondary) }
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
            if let problem { StateLine(kind: .error, text: problem, font: .body) }
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
            problem = L10n.error(error)
        }
    }
}
