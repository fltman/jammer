import AppKit
import JammerAgent
import JammerCore
import JammerSpeech
import JammerStems
import SwiftUI

/// Folders the user lets agents read from and write to (batch). Empty until the user adds
/// one in Settings › Agents; stored as bookmarks.
@MainActor
enum AgentFolders {
    private static let key = "agents.folders"

    static var urls: [URL] {
        var list = (UserDefaults.standard.array(forKey: key) as? [Data] ?? []).compactMap { data -> URL? in
            var stale = false
            return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        #if DEBUG
        // Scripted tests can't work the folder dialog: `-agentFolder /path` on a debug build.
        if let test = UserDefaults.standard.string(forKey: "agentFolder"), !test.isEmpty { list.append(URL(fileURLWithPath: test)) }
        #endif
        return list
    }
    static var policy: FolderPolicy { FolderPolicy(allowed: urls) }

    static func add(_ url: URL) {
        guard let data = try? url.bookmarkData(), !urls.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { return }
        UserDefaults.standard.set((UserDefaults.standard.array(forKey: key) as? [Data] ?? []) + [data], forKey: key)
    }
    static func remove(_ url: URL) {
        let keep = (UserDefaults.standard.array(forKey: key) as? [Data] ?? []).filter { data in
            var stale = false
            return (try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))?.standardizedFileURL != url.standardizedFileURL
        }
        UserDefaults.standard.set(keep, forKey: key)
    }
}

/// The jobs batch can run on a document without a window.
enum BatchJobs {
    static let hook: BatchRunner.JobHook = { step, project, pool in
        switch step.op {
        case "restore":
            guard let kind = Restoration.Kind(rawValue: step.params["kind"]?.string ?? "") else { throw BatchError("bad_request", "restore needs kind.") }
            if kind == .denoise, Restoration.denoiser == nil { throw BatchError("not_available", "Noise reduction isn't available in this build.") }
            let settings = Restoration.Settings(kind: kind, amount: Float(step.params["amount"]?.double ?? 1), humFrequency: step.params["humFrequency"]?.double,
                                                sensitivity: step.params["sensitivity"]?.double ?? 1)
            do { return try Restoration.apply(settings, to: project, pool: pool, media: MediaStore.folder).0 } catch {
                // Nothing to repair (no hum found, say) isn't a failure for a batch.
                return project
            }
        case "transcribe":
            let locale = Locale(identifier: step.params["language"]?.string ?? Locale.current.identifier(.bcp47))
            let choice = SpeechEngines.Choice(rawValue: step.params["engine"]?.string ?? "auto") ?? .auto
            let engine: any TranscriptionEngine
            do { engine = try await MainActor.run { try SpeechEngines.engine(choice, for: locale) } } catch let e as SpeechEngines.Unavailable { throw BatchError(e.reason, e.message) }
            var p = project
            let used = Set(p.tracks.flatMap { $0.clips.map(\.sourceID) })
            for src in p.sources where used.contains(src.id) { p.setTranscript(try await engine.transcribe(src, pool: pool, locale: locale) { _ in }) }
            return p
        case "diarize":
            var p = project
            let tracks = p.tracks.filter { !$0.clips.isEmpty }.map(\.id)
            let byTrack = step.params["mode"]?.string == "by_track" || (step.params["mode"] == nil && p.hasOverlappingTracks)
            if byTrack {
                p.applyDiarization(Diarization.byTrack(p, pool: pool, tracks: tracks), engine: "by-track")
            } else {
                guard Diarization.engine != nil else { throw BatchError("model_unavailable", "The speaker model isn't available.") }
                let n = step.params["speakers"]?.double.map { Int($0) }
                p.applyDiarization(try await Diarization.model(p, pool: pool, tracks: tracks, minSpeakers: n, maxSpeakers: n), engine: Diarization.engine?.engineName ?? "model")
            }
            return p
        case "separate":
            let model = step.params["model"]?.string ?? "music4"
            guard Stems.isInstalled(model) else { throw BatchError("model_missing", StemError.modelMissing.localizedDescription) }
            do { return try project.separatingStems(engine: try Stems.engine(model), pool: pool, media: MediaStore.folder).0 } catch let e as StemError {
                throw BatchError(e.reason, e.localizedDescription)
            }
        default:
            throw BatchError("bad_request", "Unknown job \(step.op).")
        }
    }
}

/// A saved list of steps and jobs for batch (File › Batch…), as the API takes them.
@MainActor
struct BatchRecipe: @preconcurrency Identifiable, @preconcurrency Hashable {
    var id: String { name }
    var name: String
    var steps: [[String: Any]] { (body["steps"] as? [[String: Any]]) ?? [] }
    var body: [String: Any]

    static func == (a: Self, b: Self) -> Bool { a.name == b.name }
    func hash(into h: inout Hasher) { h.combine(name) }

    static let builtIn: [BatchRecipe] = [
        .init(name: "Podcast: remove hum, Spotify loudness", body: ["jobs": [["op": "restore", "params": ["kind": "dehum"]]],
                                                                     "steps": [["op": "loudness_preset", "params": ["preset": "spotify"]]]]),
        .init(name: "Loudness: Apple Podcasts", body: ["steps": [["op": "loudness_preset", "params": ["preset": "apple_podcasts"]]]]),
        .init(name: "Loudness: EBU R 128 (−23 LUFS)", body: ["steps": [["op": "loudness_preset", "params": ["preset": "ebu_r128"]]]]),
        .init(name: "Reduce noise, normalize to −16 LUFS", body: ["jobs": [["op": "restore", "params": ["kind": "denoise", "amount": 0.6]]],
                                                                  "steps": [["op": "normalize", "params": ["target": "loudness", "level": -16]]]]),
        .init(name: "Convert only", body: [:]),
    ]

    static var folder: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Jammer/Recipes")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Built-in recipes plus any `*.json` in Application Support/Jammer/Recipes ({"steps": […], "jobs": […]}).
    static var all: [BatchRecipe] {
        let saved = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }.compactMap { url -> BatchRecipe? in
            guard let d = try? Data(contentsOf: url), let body = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
            return BatchRecipe(name: url.deletingPathExtension().lastPathComponent, body: body)
        }
        return builtIn + saved.sorted { $0.name < $1.name }
    }
}

@MainActor
@Observable
final class BatchModel {
    var files: [URL] = []
    var output: URL?
    var recipe = BatchRecipe.builtIn[0]
    var format = ExportFormat.mp3
    var status = ""
    var running = false
    let recipes = BatchRecipe.all

    func chooseFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.message = "Choose audio files, or folders of them"
        guard p.runModal() == .OK else { return }
        files = p.urls.flatMap { url -> [URL] in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return [url] }
            return ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .filter { BatchRequest.audioExtensions.contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
        }
    }

    func chooseOutput() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.message = "Where the processed files go"
        if p.runModal() == .OK { output = p.url }
    }

    func run() {
        guard let output, !files.isEmpty else { return }
        var body = recipe.body
        body["files"] = files.map(\.path)
        body["output"] = output.path
        body["export"] = ["format": format.rawValue]
        do {
            // The user picked these files and this folder here, so no agent-folder check.
            let request = try BatchRequest.parse(body, policy: nil)
            running = true
            status = "Starting…"
            let job = JobRegistry.shared.startBatch(request) { [weak self] result in
                self?.running = false
                var parts = ["\(result.outputs.count) done"]
                if !result.skipped.isEmpty { parts.append("\(result.skipped.count) skipped (already there)") }
                if !result.failed.isEmpty { parts.append("\(result.failed.count) failed: " + result.failed.map { "\(($0.file as NSString).lastPathComponent) (\($0.message))" }.joined(separator: "; ")) }
                self?.status = parts.joined(separator: ", ") + "."
            }
            _ = job
        } catch {
            status = error.localizedDescription
        }
    }
}

struct BatchView: View {
    @State private var model = BatchModel()

    var body: some View {
        Form {
            LabeledContent("Files") {
                HStack {
                    Text(model.files.isEmpty ? "None chosen" : "\(model.files.count) file\(model.files.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                    Button("Choose…") { model.chooseFiles() }.accessibilityLabel("Choose files")
                }
            }
            Picker("Recipe", selection: $model.recipe) { ForEach(model.recipes) { Text($0.name).tag($0) } }
            Picker("Format", selection: $model.format) { ForEach(ExportFormat.available, id: \.self) { Text($0.rawValue.uppercased()).tag($0) } }
            LabeledContent("Save in") {
                HStack {
                    Text(model.output?.lastPathComponent ?? "Not chosen").foregroundStyle(.secondary)
                    Button("Choose…") { model.chooseOutput() }.accessibilityLabel("Choose output folder")
                }
            }
            Text("Each file is processed without opening a window and saved as “name (Jämmer)” in the folder you choose. Your files are never changed, and a file that's already there is skipped.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.status.isEmpty { Text(model.status).font(.callout).foregroundStyle(Theme.neonColor).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                if model.running { ProgressView().controlSize(.small) }
                Button("Run") { model.run() }.keyboardShortcut(.defaultAction).disabled(model.files.isEmpty || model.output == nil || model.running)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }
}

@MainActor
enum BatchWindow {
    private static var window: NSWindow?
    static func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let w = EscClosingWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Batch"
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: BatchView())
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
    }
}
