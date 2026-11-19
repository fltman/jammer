import AppKit
import JammerAgent
import JammerCore
import JammerDiarize
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
            guard let kind = Restoration.Kind(rawValue: step.params["kind"]?.string ?? "") else { throw BatchError("bad_request", Said("error.batch.restore_needs_kind", "restore needs kind.")) }
            if kind == .denoise, Restoration.denoiser == nil { throw BatchError("not_available", Said("error.batch.noise_reduction_isn_t", "Noise reduction isn't available in this build.")) }
            if kind == .dereverb, Restoration.dereverber == nil { throw BatchError("not_available", Said("error.batch.reverb_reduction_isn_t", "Reverb reduction isn't available in this build.")) }
            let settings = Restoration.Settings(kind: kind, amount: Float(step.params["amount"]?.double ?? Double(kind.defaultAmount)), humFrequency: step.params["humFrequency"]?.double,
                                                sensitivity: step.params["sensitivity"]?.double ?? 1)
            do { return try Restoration.apply(settings, to: project, pool: pool, media: MediaStore.folder).0 } catch {
                // Nothing to repair (no hum found, say) isn't a failure for a batch.
                return project
            }
        case "transcribe":
            let locale = Locale(identifier: step.params["language"]?.string ?? Locale.current.identifier(.bcp47))
            let choice = SpeechEngines.Choice(rawValue: step.params["engine"]?.string ?? "auto") ?? .auto
            // Never a paid engine without the request's word (BatchRequest.parse sets it after allowPaid and
            // allowUnknownPrice; the window asks first).
            if choice.paid, !step.paidAllowed {
                throw BatchError("paid_not_allowed", Said("error.batch.paidNotAllowed", "The job transcribe with engine %@ uploads the audio to its provider, which charges the user's account. Pass \"allowPaid\": true to run it.", choice.rawValue))
            }
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
                guard Diarization.engine != nil else { throw BatchError("model_unavailable", Said("error.batch.speaker_model_isn_t", "The speaker model isn't available.")) }
                // An agent's batch never fetches a model (SIBLINGS): the user downloads it in Settings › Models.
                if let d = Diarization.engine as? FluidDiarizer, !d.isInstalled {
                    throw BatchError("model_missing", Said("error.batch.diarisationMissing", "The diarisation model (requirement \"diarisation\") isn't on this Mac; the user downloads it in Settings › Models."))
                }
                let n = step.params["speakers"]?.double.map { Int($0) }
                p.applyDiarization(try await Diarization.model(p, pool: pool, tracks: tracks, minSpeakers: n, maxSpeakers: n), engine: Diarization.engine?.engineName ?? "model")
            }
            return p
        case "separate":
            let model = step.params["model"]?.string ?? "music4"
            guard Stems.isInstalled(model) else { throw BatchError("model_missing", wrapping: StemError.modelMissing) }
            do { return try project.separatingStems(engine: try Stems.engine(model), pool: pool, media: MediaStore.folder).0 } catch let e as StemError {
                throw BatchError(e.reason, wrapping: e)
            }
        default:
            throw BatchError("bad_request", Said("error.batch.unknown_job", "Unknown job %@.", "\(step.op)"))
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
        .init(name: L10n.text("batch.recipe.podcast"), body: ["jobs": [["op": "restore", "params": ["kind": "dehum"]]],
                                                                     "steps": [["op": "loudness_preset", "params": ["preset": "spotify"]]]]),
        .init(name: L10n.text("batch.recipe.apple"), body: ["steps": [["op": "loudness_preset", "params": ["preset": "apple_podcasts"]]]]),
        .init(name: L10n.text("batch.recipe.ebu"), body: ["steps": [["op": "loudness_preset", "params": ["preset": "ebu_r128"]]]]),
        .init(name: L10n.text("batch.recipe.denoise"), body: ["jobs": [["op": "restore", "params": ["kind": "denoise", "amount": 0.6]]],
                                                                  "steps": [["op": "normalize", "params": ["target": "loudness", "level": -16]]]]),
        .init(name: L10n.text("batch.recipe.convert"), body: [:]),
    ]

    static var folder: URL {
        let u = AppData.folder.appending(path: "Recipes")
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
        p.message = L10n.text("batch.panel.files")
        guard p.runModal() == .OK else { return }
        files = p.urls.flatMap { url -> [URL] in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return [url] }
            return ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .filter { BatchRequest.audioExtensions.contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
        }
    }

    /// The question before a run with paid jobs: what is uploaded and to whom, that the price is unknown and why.
    private func askPaid(_ paid: [[String: Any]]) -> Bool {
        let lines = paid.map { j -> String in
            let p = j["params"] as? [String: Any] ?? [:]
            return L10n.text("batch.paid.job", p["engine"] as? String ?? "", p["language"] as? String ?? Locale.current.identifier(.bcp47))
        }.joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = L10n.text("openai.ask.title")
        alert.informativeText = L10n.text("batch.paid.text", recipe.name, lines, L10n.count("storage.files", files.count))
        alert.addButton(withTitle: L10n.text("button.send"))
        alert.addButton(withTitle: L10n.text("button.cancel"))
        let unknown = UnknownPriceBox(service: "openai.transcription", name: "OpenAI")
        UnknownPriceBox.place([unknown.view], in: alert)
        unknown.gate(alert.buttons[0])
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        unknown.sent()
        return true
    }

    func chooseOutput() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.message = L10n.text("batch.panel.output")
        if p.runModal() == .OK { output = p.url }
    }

    func run() {
        guard let output, !files.isEmpty else { return }
        var body = recipe.body
        body["files"] = files.map(\.path)
        body["output"] = output.path
        body["export"] = ["format": format.rawValue]
        // A paid job (transcribe at OpenAI): asked once for the whole run, every paid job named, before anything
        // is sent (SIBLINGS, "Betalt kräver alltid en fråga"); the request carries the answer, and nothing else does.
        let jobs = (body["jobs"] as? [[String: Any]]) ?? []
        let paid = jobs.filter { j in (j["op"] as? String) == "transcribe" && BatchRequest.paidEngines.contains(((j["params"] as? [String: Any])?["engine"] as? String) ?? "auto") }
        if !paid.isEmpty {
            guard askPaid(paid) else { status = L10n.text("batch.paid.notSent"); return }
            body["allowPaid"] = true
            body["allowUnknownPrice"] = true
        }
        do {
            // The user picked these files and this folder here, so no agent-folder check.
            let request = try BatchRequest.parse(body, policy: nil)
            running = true
            status = L10n.text("batch.starting")
            let job = JobRegistry.shared.startBatch(request) { [weak self] result in
                self?.running = false
                var parts = [L10n.text("batch.result.done", String(result.outputs.count))]
                let short = zip(result.outputs, zip(result.loudness, result.limitedByPeak)).filter { $0.1.1 }
                if !short.isEmpty {
                    parts.append(L10n.text("batch.result.short", String(short.count), short.map { ($0.0 as NSString).lastPathComponent + " " + L10n.number($0.1.0 ?? 0, 1) + " LUFS" }.joined(separator: ", ")))
                }
                if !result.skipped.isEmpty { parts.append(L10n.text("batch.result.skipped", String(result.skipped.count))) }
                if !result.failed.isEmpty { parts.append(L10n.text("batch.result.failed", String(result.failed.count), result.failed.map { "\(($0.file as NSString).lastPathComponent) (\($0.message))" }.joined(separator: "; "))) }
                self?.status = parts.joined(separator: ", ") + "."
            }
            _ = job
        } catch {
            status = L10n.error(error)
        }
    }
}

struct BatchView: View {
    @State private var model = BatchModel()

    var body: some View {
        Form {
            LabeledContent(L10n.text("batch.files")) {
                HStack {
                    Text(model.files.isEmpty ? L10n.text("batch.files.none") : L10n.count("storage.files", model.files.count)).foregroundStyle(.secondary)
                    Button(L10n.text("button.choose")) { model.chooseFiles() }.accessibilityLabel(L10n.text("batch.files.choose.ax"))
                }
            }
            Picker(L10n.text("batch.recipe"), selection: $model.recipe) { ForEach(model.recipes) { Text($0.name).tag($0) } }
            Picker(L10n.text("batch.format"), selection: $model.format) { ForEach(ExportFormat.available, id: \.self) { Text($0.rawValue.uppercased()).tag($0) } }
            LabeledContent(L10n.text("batch.saveIn")) {
                HStack {
                    Text(model.output?.lastPathComponent ?? L10n.text("batch.output.none")).foregroundStyle(.secondary)
                    Button(L10n.text("button.choose")) { model.chooseOutput() }.accessibilityLabel(L10n.text("batch.output.choose.ax"))
                }
            }
            Text(L10n.text("batch.text"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.status.isEmpty { Text(model.status).font(.callout).foregroundStyle(Theme.neonColor).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                if model.running { ProgressView().controlSize(.small) }
                Button(L10n.text("batch.run")) { model.run() }.keyboardShortcut(.defaultAction).disabled(model.files.isEmpty || model.output == nil || model.running)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 380)
    }
}

@MainActor
enum BatchWindow {
    private static var window: NSWindow?
    static func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let w = EscClosingWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = L10n.text("batch.title")
        w.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: BatchView())
        w.contentViewController = host
        // A grouped Form reports no height of its own, which left the window 32 points tall.
        w.setContentSize(NSSize(width: 520, height: max(380, host.view.fittingSize.height)))
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
    }
}
