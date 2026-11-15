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
        w.title = "Settings"
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: ModelsSettings())
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
            ModelRow(id: spec.id, title: spec.title, use: "Transcription in Swedish; the best Swedish engine here.", bytes: spec.size, licence: spec.licence,
                     installed: { store.isInstalled(spec) },
                     install: { p in try await store.install(spec, progress: p) },
                     remove: { try store.remove(spec) })
        }
        let parakeet = SpeechEngines.parakeet
        rows.append(ModelRow(id: "parakeet", title: ParakeetEngine.title, use: "Transcription in 25 European languages, Swedish and English among them.",
                             bytes: ParakeetEngine.downloadBytes, licence: ParakeetEngine.licence,
                             installed: { parakeet.isInstalled },
                             install: { p in try await parakeet.install(progress: p) },
                             remove: { try parakeet.remove() }))
        if let d = Diarization.engine as? FluidDiarizer {
            rows.append(ModelRow(id: "diarisation", title: "Speaker diarisation (pyannote Community-1)", use: "Find Speakers on a mixed recording. Also fetched by itself the first time it's used.",
                                 bytes: 21_000_000, licence: "CC-BY-4.0 (pyannote, WeSpeaker, BUT Speech@FIT; Core ML by Fluid Inference)",
                                 installed: { d.isInstalled },
                                 install: { p in try await d.install(progress: p) },
                                 remove: { try d.remove() }))
        }
        let stems = Stems.model
        rows.append(ModelRow(id: "stems", title: StemModel.title, use: "Audio › Separate Stems: vocals, drums, bass and other from a music track. From Deezer's own release.",
                             bytes: StemModel.downloadBytes, licence: StemModel.licence,
                             installed: { stems.isInstalled },
                             install: { p in try await stems.install(progress: p) },
                             remove: { Stems.forget(); try stems.remove() }))
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
                errors[row.id] = "The download didn't finish (\(error.localizedDescription)). Check the network and try again; everything else in Jämmer works without one."
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
            Text("Models").font(.title2.bold())
            HStack(alignment: .firstTextBaseline) {
                Text("Models run on this Mac. Each is downloaded once from its publisher (speech models from \(SpeechEngines.store.source.host() ?? "the model source")), and can be removed again.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Show in Finder") {
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
                        if let e = model.errors[row.id] { Text(e).font(.caption).foregroundStyle(.orange) }
                    }
                    Spacer()
                    if let p = model.progress[row.id] {
                        ProgressView(value: p).frame(width: 90).accessibilityLabel("Downloading \(row.title)")
                    } else if row.installed() {
                        Button("Remove") { model.remove(row) }.accessibilityLabel("Remove \(row.title)")
                    } else {
                        Button("Download") { model.install(row) }.accessibilityLabel("Download \(row.title)")
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
