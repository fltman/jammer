import AppKit
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

    static func show() {
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
    var remove: () throws -> Void
}

@MainActor
@Observable
final class ModelsModel {
    var progress: [String: Double] = [:]
    var errors: [String: String] = [:]
    var tick = 0

    let rows: [ModelRow] = {
        let store = SpeechEngines.store
        var rows = ModelSpec.catalogue.map { spec in
            ModelRow(id: spec.id, title: spec.title, use: L10n.text("settings.models.whisper.use"), bytes: spec.size, licence: spec.licence,
                     installed: { store.isInstalled(spec) },
                     install: { p in try await store.install(spec, progress: p) },
                     remove: { try store.remove(spec) })
        }
        let parakeet = SpeechEngines.parakeet
        rows.append(ModelRow(id: "parakeet", title: ParakeetEngine.title, use: L10n.text("settings.models.parakeet.use"),
                             bytes: ParakeetEngine.downloadBytes, licence: ParakeetEngine.licence,
                             installed: { parakeet.isInstalled },
                             install: { p in try await parakeet.install(progress: p) },
                             remove: { try parakeet.remove() }))
        if let d = Diarization.engine as? FluidDiarizer {
            rows.append(ModelRow(id: "diarisation", title: L10n.text("settings.models.diarisation.title"), use: L10n.text("settings.models.diarisation.use"),
                                 bytes: 21_000_000, licence: "CC-BY-4.0 (pyannote, WeSpeaker, BUT Speech@FIT; Core ML by Fluid Inference)",
                                 installed: { d.isInstalled },
                                 install: { p in try await d.install(progress: p) },
                                 remove: { try d.remove() }))
        }
        let stems = Stems.model
        rows.append(ModelRow(id: "stems", title: StemModel.title, use: L10n.text("settings.models.stems.use"),
                             bytes: StemModel.downloadBytes, licence: StemModel.licence,
                             installed: { stems.isInstalled },
                             install: { p in try await stems.install(progress: p) },
                             remove: { Stems.forget(); try stems.remove() }))
        let soundtrack = Stems.soundtrack
        rows.append(ModelRow(id: "soundtrack", title: StemModel.Soundtrack.title, use: L10n.text("settings.models.soundtrack.use"),
                             bytes: StemModel.Soundtrack.downloadBytes, licence: StemModel.Soundtrack.licence,
                             installed: { soundtrack.isInstalled },
                             install: { p in try await soundtrack.install(progress: p) },
                             remove: { Stems.forget(); try soundtrack.remove() }))
        return rows
    }()

    func install(_ row: ModelRow) {
        errors[row.id] = nil
        progress[row.id] = 0
        Task {
            do {
                let id = row.id
                try await row.install { p in Task { @MainActor in self.progress[id] = p } }
            } catch {
                errors[row.id] = L10n.text("settings.models.failed", error.localizedDescription)
            }
            progress[row.id] = nil
            tick += 1
        }
    }

    func remove(_ row: ModelRow) {
        do { try row.remove() } catch { errors[row.id] = error.localizedDescription }
        tick += 1
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
                    }
                    Spacer()
                    if let p = model.progress[row.id] {
                        ProgressView(value: p).frame(width: 90).accessibilityLabel(L10n.text("settings.models.downloading.ax", row.title))
                    } else if row.installed() {
                        Button(L10n.text("button.remove")) { model.remove(row) }.accessibilityLabel(L10n.text("button.remove.ax", row.title))
                    } else {
                        Button(L10n.text("settings.models.download")) { model.install(row) }.accessibilityLabel(L10n.text("settings.models.download.ax", row.title))
                    }
                }
                .id("\(row.id)-\(model.tick)")
                Divider()
            }
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
    var body: some View {
        TabView {
            ModelsSettings().tabItem { Label(L10n.text("settings.models"), systemImage: "square.and.arrow.down") }
            AgentSettings().tabItem { Label(L10n.text("settings.agents"), systemImage: "terminal") }
            PaidSettings().tabItem { Label(L10n.text("paid.settings.tab"), systemImage: "creditcard") }
        }
    }
}
