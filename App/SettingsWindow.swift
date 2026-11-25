import AppKit
import JammerAgent
import JammerCore
import JammerDiarize
import JammerParakeet
import JammerSpeech
import JammerStems
import SwiftUI

/// Jämmer › Settings… (⌘,): the speech models, each with its size and licence shown
/// before anything is downloaded, and a way to remove it again.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    /// The tab shown: "models", "agents", "paid" or "voiceProfiles".
    @MainActor @Observable final class Pane { var selected = "models" }
    static let pane = Pane()

    /// `pane`: the tab to bring forward (the agent API's settings.open asks for "models").
    static func show(pane: String? = nil) {
        if let pane { self.pane.selected = pane }
        if let window { window.makeKeyAndOrderFront(nil); return }
        let w = EscClosingWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = L10n.text("settings.title")
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: SettingsTabs())
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
    }
}

/// Closes on Esc, like the series' other small windows.
final class EscClosingWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

/// One downloadable model as the settings list shows it.
struct ModelRow: Identifiable {
    var id: String
    var title: String
    var use: String
    var bytes: Int64
    var licence: String
    var installed: () -> Bool
    var install: (@escaping @Sendable (Double) -> Void) async throws -> Void
    var remove: @MainActor () async throws -> Void
}

@MainActor
@Observable
final class ModelsModel {
    var progress: [String: Double] = [:]
    var errors: [String: String] = [:]
    var tick = 0
    var removing: Set<String> = []

    let rows: [ModelRow]

    init() {
        rows = Self.makeRows()
    }

    private static func makeRows() -> [ModelRow] {
        let store = SpeechEngines.store
        var rows = ModelSpec.catalogue.map { spec in
            ModelRow(id: spec.id, title: spec.id.contains("medium") ? L10n.text("settings.models.whisperMedium.title") : L10n.text("settings.models.whisperSmall.title"), use: L10n.text("settings.models.whisper.use"), bytes: spec.size, licence: spec.licence,
                     installed: { store.isInstalled(spec) },
                     install: { p in try await store.install(spec, progress: p) },
                     remove: { try store.remove(spec) })
        }
        let multilingual = ModelSpec.multilingualWhisper
        rows.append(ModelRow(id: multilingual.id, title: L10n.text("settings.models.whisperMultilingual.title"),
                             use: L10n.text("settings.models.whisperMultilingual.use"), bytes: multilingual.size, licence: multilingual.licence,
                             installed: { store.isInstalled(multilingual) },
                             install: { p in try await store.install(multilingual, progress: p) },
                             remove: { try store.remove(multilingual) }))
        let parakeet = SpeechEngines.parakeet
        rows.append(ModelRow(id: "parakeet", title: L10n.text("settings.models.parakeet.title"), use: L10n.text("settings.models.parakeet.use"),
                             bytes: ParakeetEngine.downloadBytes, licence: ParakeetEngine.licence,
                             installed: { parakeet.isInstalled },
                             install: { p in try await parakeet.install(progress: p) },
                             remove: { try parakeet.remove() }))
        for variant in PianissimoModel.allCases {
            guard let engine = SpeechEngines.pianissimo[variant] else { continue }
            let title = variant == .swedish ? L10n.text("settings.models.pianissimo.sv") : L10n.text("settings.models.pianissimo.da")
            rows.append(ModelRow(id: variant.id, title: title, use: L10n.text("settings.models.pianissimo.use"),
                                 bytes: variant.downloadBytes, licence: "CC-BY-4.0",
                                 installed: { engine.isInstalled },
                                 install: { p in try await engine.install(progress: p) },
                                 remove: { try await engine.remove() }))
        }
        if let d = Diarization.engine as? FluidDiarizer {
            rows.append(ModelRow(id: "diarisation", title: L10n.text("settings.models.diarisation.title"), use: L10n.text("settings.models.diarisation.use"),
                                 bytes: Requirements.all.first { $0.id == "diarisation" }?.sizeBytes ?? 21_599_417, licence: "CC-BY-4.0 (pyannote, WeSpeaker, BUT Speech@FIT; Core ML by Fluid Inference)",
                                 installed: { d.isInstalled },
                                 install: { p in try await d.install(progress: p) },
                                 remove: { try d.remove() }))
        }
        let stems = Stems.model
        rows.append(ModelRow(id: "stems", title: L10n.text("settings.models.stems.title"), use: L10n.text("settings.models.stems.use"),
                             bytes: StemModel.downloadBytes, licence: StemModel.licence,
                             installed: { stems.isInstalled },
                             install: { p in try await stems.install(progress: p) },
                             remove: { Stems.forget(); try stems.remove() }))
        let soundtrack = Stems.soundtrack
        rows.append(ModelRow(id: "soundtrack", title: L10n.text("settings.models.soundtrack.title"), use: L10n.text("settings.models.soundtrack.use"),
                             bytes: StemModel.Soundtrack.downloadBytes, licence: StemModel.Soundtrack.licence,
                             installed: { soundtrack.isInstalled },
                             install: { p in try await soundtrack.install(progress: p) },
                             remove: { Stems.forget(); try soundtrack.remove() }))
        return rows
    }

    /// Downloads under way, by row: Stop cancels one (COMFORT 7).
    @ObservationIgnored private var downloads: [String: Task<Void, Never>] = [:]
    var stopped: Set<String> = []

    func install(_ row: ModelRow) {
        errors[row.id] = nil
        stopped.remove(row.id)
        progress[row.id] = 0
        let id = row.id
        downloads[id] = Task {
            do {
                try await row.install { p in Task { @MainActor in self.progress[id] = p } }
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch {
                if !stopped.contains(id) { errors[id] = L10n.text("settings.models.failed", L10n.error(error)) }
            }
            progress[id] = nil
            downloads[id] = nil
            tick += 1
        }
    }

    func stopDownload(_ row: ModelRow) {
        stopped.insert(row.id)
        downloads[row.id]?.cancel()
    }

    func remove(_ row: ModelRow) {
        guard removing.insert(row.id).inserted else { return }
        Task {
            do { try await row.remove() } catch { errors[row.id] = L10n.error(error) }
            removing.remove(row.id)
            tick += 1
        }
    }
}

struct ModelsSettings: View {
    @State private var model = ModelsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("settings.models")).font(.title2.bold())
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("settings.models.text", SpeechEngines.store.source.host() ?? L10n.text("settings.models.source")))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(L10n.text("settings.models.showInFinder")) {
                    try? FileManager.default.createDirectory(at: SpeechEngines.store.folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([SpeechEngines.store.folder])
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.rows) { row in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.title).font(.headline)
                                Text(row.use).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("\(ByteCountFormatter.string(fromByteCount: row.bytes, countStyle: .file)) · \(row.licence)")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let e = model.errors[row.id] { StateLine(kind: .error, text: e) }
                                else if model.stopped.contains(row.id), model.progress[row.id] == nil, !row.installed() {
                                    StateLine(kind: .info, text: L10n.text("settings.models.stopped"))
                                }
                            }
                            Spacer()
                            if let p = model.progress[row.id] {
                                ProgressView(value: p).frame(width: 90).accessibilityLabel(L10n.text("settings.models.downloading.ax", row.title))
                                Button(L10n.text("job.stop")) { model.stopDownload(row) }
                                    .accessibilityLabel(L10n.text("settings.models.stop.ax", row.title))
                            } else if row.installed() {
                                Button(L10n.text("button.remove")) { model.remove(row) }
                                    .disabled(model.removing.contains(row.id))
                                    .accessibilityLabel(L10n.text("button.remove.ax", row.title))
                            } else {
                                Button(L10n.text("settings.models.download")) {
                                    // Size, publisher, source and license first; nothing is fetched before the sheet's Download.
                                    ModelDownloadSheet.ask(ModelDownloadSheet.requirementID(forRow: row.id), on: NSApp.keyWindow) { model.install(row) }
                                }.accessibilityLabel(L10n.text("settings.models.download.ax", row.title))
                            }
                        }
                        .id("\(row.id)-\(model.tick)")
                        Divider()
                    }
                }
            }
            .frame(height: 470)
        }
        .padding(20)
        .frame(width: 560)
    }
}

/// Settings › Agents: the folders agents may read from and write to.
struct AgentSettings: View {
    @State private var folders = AgentFolders.urls

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("settings.agents")).font(.title2.bold())
            Text(L10n.text("settings.agents.folders")).font(.headline)
            Text(L10n.text("settings.agents.text"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(folders, id: \.self) { url in
                HStack {
                    Image(systemName: "folder").accessibilityHidden(true)
                    Text(url.path).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(L10n.text("button.remove")) { AgentFolders.remove(url); folders = AgentFolders.urls }.accessibilityLabel(L10n.text("button.remove.ax", url.lastPathComponent))
                }
            }
            if folders.isEmpty { Text(L10n.text("settings.agents.none")).foregroundStyle(.secondary) }
            Button(L10n.text("settings.agents.add")) {
                let p = NSOpenPanel()
                p.canChooseDirectories = true
                p.canChooseFiles = false
                p.canCreateDirectories = true
                p.message = L10n.text("settings.agents.panel")
                if p.runModal() == .OK, let url = p.url { AgentFolders.add(url); folders = AgentFolders.urls }
            }
        }
        .padding(20)
        .frame(width: 560, alignment: .leading)
    }
}

struct SettingsTabs: View {
    @Bindable private var pane = SettingsWindow.pane

    var body: some View {
        TabView(selection: $pane.selected) {
            ModelsSettings().tabItem { Label(L10n.text("settings.models"), systemImage: "square.and.arrow.down") }.tag("models")
            AgentSettings().tabItem { Label(L10n.text("settings.agents"), systemImage: "terminal") }.tag("agents")
            PaidSettings().tabItem { Label(L10n.text("paid.settings.tab"), systemImage: "creditcard") }.tag("paid")
            VoiceProfileSettings().tabItem { Label(L10n.text("voiceProfiles.settings.tab"), systemImage: "person.wave.2") }.tag("voiceProfiles")
        }
    }
}
