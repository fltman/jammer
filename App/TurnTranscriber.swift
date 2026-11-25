import AVFAudio
import Foundation
import JammerAgent
import JammerCore
import JammerParakeet
import JammerSpeech
import JammerWhisper

/// POST /api/v1/transcribe in the app: picks the engine, keeps it loaded between turns, and says in Jämmer's own
/// windows while it works for another app (each open document's status bar, with a Stop, and the splash). The audio
/// and the text live only in this call: never written, never logged (TurnTranscription).
@MainActor
enum TurnTranscriber {
    static let allowedKey = "agents.siblingTranscription"
    /// Settings › Agents: on unless the user turned it off.
    static var allowed: Bool { UserDefaults.standard.object(forKey: allowedKey) as? Bool ?? true }

    private static let gate = TurnTranscription.Gate()
    /// One Whisper per model file, so its model stays loaded from the second turn on.
    private static var whispers: [String: WhisperEngine] = [:]

    private struct Pick {
        let engine: String
        let model: String
        let run: ([Float], Locale) async throws -> [RecognisedRun]
    }

    static func handle(_ r: AgentAPI.Request) async throws -> AgentAPI.Response {
        guard allowed else { throw TurnTranscription.off() }
        let request = try TurnTranscription.parse(query: r.query, body: r.body)
        try gate.enter()
        defer { gate.leave() }
        let locale = Locale(identifier: request.language)
        let pick = try await choose(request.engine, for: locale)
        let who = caller(r)
        // Shown while it works; the user can stop it from any window.
        let task = Task { try await pick.run(request.samples, locale) }
        AgentServer.shared.sibling = .init(label: L10n.text("turn.working", who)) { task.cancel() }
        defer { AgentServer.shared.sibling = nil }
        let started = Date()
        let runs: [RecognisedRun]
        do {
            runs = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch is CancellationError {
            throw AgentAPI.APIError(409, "stopped", "The user stopped this turn in Jämmer's window (or the connection closed).")
        } catch let e as TranscriptionError {
            if case .unsupportedLanguage = e { throw AgentAPI.APIError.unprocessable("unsupported_language", "\(pick.model) doesn't do \(request.language).") }
            var err = AgentAPI.APIError(503, "model_unavailable", "\(pick.model) is installed but didn't answer: \(e.localizedDescription)")
            err.requirement = pick.model
            throw err
        } catch {
            var err = AgentAPI.APIError(503, "model_unavailable", "\(pick.model) is installed but didn't answer: \(error.localizedDescription)")
            err.requirement = pick.model
            throw err
        }
        let ms = Int(Date().timeIntervalSince(started) * 1_000)
        let words = runs.map { TurnTranscription.Word(text: $0.text, start: $0.start, end: $0.end, confidence: $0.confidence) }
        return .json(TurnTranscription.json(words: words, engine: pick.engine, model: pick.model, ms: ms))
    }

    /// The app named by X-Sibling, as the window says it.
    private static func caller(_ r: AgentAPI.Request) -> String {
        let slug = r.headers["x-sibling"]?.lowercased()
        return slug.map { AgentRouter.siblingNames[$0] ?? $0.capitalized } ?? L10n.text("turn.anotherApp")
    }

    private static func whisper(_ spec: ModelSpec, language: String?) -> WhisperEngine {
        if let w = whispers[spec.id] { return w }
        let w = WhisperEngine(model: spec, path: SpeechEngines.store.path(for: spec), language: language)
        whispers[spec.id] = w
        return w
    }

    /// auto: local Pianissimo once its model is loaded (measured with Drömmer 2026-11-25: about twice as fast as
    /// KB-Whisper, 1.3 % against 0–2.7 % WER on Swedish turns), else KB-Whisper for Swedish while Pianissimo is
    /// warmed in the background (its first load takes some 16 s), else Whisper small (multilingual).
    private static var warming: Task<Void, Never>?
    private static func choose(_ engine: TurnTranscription.Engine, for locale: Locale) async throws -> Pick {
        let lang = locale.language.languageCode?.identifier ?? ""
        let store = SpeechEngines.store
        func kb() -> Pick? {
            guard lang == "sv", let spec = SpeechEngines.installedWhisper else { return nil }
            let w = whisper(spec, language: "sv")
            return Pick(engine: "whisper", model: spec.id) { try await w.transcribeTurn($0, locale: $1) }
        }
        func small() -> Pick? {
            guard store.isInstalled(.multilingualWhisper) else { return nil }
            let w = whisper(.multilingualWhisper, language: nil)
            return Pick(engine: "whisper", model: ModelSpec.multilingualWhisper.id) { try await w.transcribeTurn($0, locale: $1) }
        }
        func pianissimo() -> Pick? {
            guard let model = PianissimoModel(rawValue: lang), let p = SpeechEngines.pianissimo[model], p.isInstalled else { return nil }
            return Pick(engine: "pianissimo", model: model.id) { try await p.transcribeTurn($0, locale: $1) }
        }
        switch engine {
        case .whisper:
            if let p = kb() ?? small() { return p }
            throw AgentAPI.APIError.modelMissing(lang == "sv" ? "kb-whisper-small" : ModelSpec.multilingualWhisper.id,
                                                 "No Whisper model is installed. The user installs one under Jämmer › Settings › Models; the API never installs it.")
        case .pianissimo:
            guard let model = PianissimoModel(rawValue: lang) else {
                throw AgentAPI.APIError.unprocessable("unsupported_language", "Local Pianissimo does Swedish and Danish.")
            }
            if let p = pianissimo() { return p }
            throw AgentAPI.APIError.modelMissing(model.id, "\(model.id) isn't installed. The user installs it under Jämmer › Settings › Models; the API never installs it.")
        case .auto:
            if let model = PianissimoModel(rawValue: lang), let engine = SpeechEngines.pianissimo[model], engine.isInstalled {
                if await engine.isLoaded, let p = pianissimo() { return p }
                if warming == nil { warming = Task { try? await engine.warm(); warming = nil } }
            }
            if let p = kb() ?? pianissimo() ?? small() { return p }
            throw AgentAPI.APIError.modelMissing(lang == "sv" ? "kb-whisper-small" : ModelSpec.multilingualWhisper.id,
                                                 "No local speech model for \(locale.identifier(.bcp47)) is installed. The user installs one under Jämmer › Settings › Models; the API never installs it.")
        }
    }

    // MARK: Files (POST /api/v1/transcribe/file)

    /// The finished file jobs' words, given once (FileTranscription.Results).
    static let results = FileTranscription.Results()

    /// Checks what can be checked at once (the switch, the options, the engine, the audio, its length) and starts the
    /// job: 202. The audio goes into a private folder of its own that the job removes however it ends.
    static func handleFile(_ r: AgentAPI.Request) async throws -> AgentAPI.Response {
        guard allowed else { throw TurnTranscription.off() }
        let (language, choice) = try TurnTranscription.options(r.query)
        let body = try FileTranscription.body(contentType: r.headers["content-type"], data: r.body)
        try gate.enter(.file)
        var started = false
        defer { if !started { gate.leave() } }
        let locale = Locale(identifier: language)
        let pick = try fileEngine(choice, for: locale)
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appending(path: "jammer-sibling-" + UUID().uuidString.lowercased())
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            throw AgentAPI.APIError.internalError("Couldn't make a temporary folder: \(error.localizedDescription)")
        }
        defer { if !started { try? fm.removeItem(at: folder) } }
        let url: URL
        switch body {
        case .bytes(let data):
            try UploadStore.checkSpace(for: Int64(data.count), at: folder)
            url = folder.appending(path: "audio." + AgentRouter.fileExtension(for: data, contentType: r.headers["content-type"] ?? ""))
            do { try data.write(to: url) } catch { throw AgentAPI.APIError.internalError("Couldn't hold the audio: \(error.localizedDescription)") }
        case .upload(let id):
            guard let u = UploadStore.shared.get(id) else { throw AgentAPI.APIError.notFound("No upload with id \(id). They expire after an hour without chunks.") }
            let head = (try? FileHandle(forReadingFrom: u.url).read(upToCount: 12)) ?? Data()
            url = folder.appending(path: "audio." + AgentRouter.fileExtension(for: head, contentType: ""))
            do { try fm.moveItem(at: u.url, to: url) } catch { throw AgentAPI.APIError.internalError("Couldn't take the upload: \(error.localizedDescription)") }
            UploadStore.shared.remove(id)
        }
        let probe = url
        let seconds = try await Task.detached(priority: .userInitiated) { try FileAudio.seconds(of: probe) }.value
        try FileTranscription.checkLength(seconds: seconds)

        let who = caller(r)
        let job = JobRegistry.shared.startSibling(kind: FileTranscription.kind, work: { id, progress in
            // Compressed audio is decoded once, at 16 kHz (the rate both engines hear), into the same folder.
            let decoded = try await Task.detached(priority: .userInitiated) { () throws -> SourceRef in
                try AudioImporter.importFile(url, sampleRate: FileAudio.isPCM(url) ? nil : 16_000, mediaFolder: folder).source
            }.value
            try Task.checkCancellation()
            let transcript = try await pick.engine.transcribe(decoded, pool: SourcePool(), locale: locale) { p in
                progress(p)
                Task { @MainActor in
                    guard JobRegistry.shared.job(id)?.isFinished == false else { return }
                    AgentServer.shared.sibling?.label = L10n.text("turn.file.working", who, String(Int(p * 100)))
                }
            }
            try Task.checkCancellation()
            let rate = decoded.info.sampleRate
            let words = transcript.words.map {
                TurnTranscription.Word(text: $0.text, start: Double($0.start) / rate, end: Double($0.end) / rate, confidence: $0.confidence)
            }
            let lang = transcript.language.isEmpty ? language : transcript.language
            results.put(id, FileTranscription.json(words: words, engine: pick.name, model: pick.model, language: lang))
            // The job itself says only how much there is; the words come with the first GET of it.
            return ["words": .number(Double(words.count)), "seconds": .number((seconds * 1_000).rounded() / 1_000),
                    "engine": .string(pick.name), "model": .string(pick.model), "language": .string(lang)]
        }, ended: {
            try? FileManager.default.removeItem(at: folder)
            if AgentServer.shared.sibling?.id == jobWait { AgentServer.shared.sibling = nil }
            gate.leave()
        })
        let wait = EditorSession.Wait(label: L10n.text("turn.file.working", who, "0")) { _ = JobRegistry.shared.cancel(job.id); AgentServer.shared.sibling = nil }
        jobWait = wait.id
        AgentServer.shared.sibling = wait
        started = true
        return .json(["job": job.json], status: 202)
    }
    private static var jobWait: UUID?

    private struct FilePick {
        let name: String
        let model: String
        let engine: any TranscriptionEngine
    }

    /// For a whole file, auto takes local Pianissimo whenever it is installed for the language (its load of some
    /// 16 s is small beside a file, and it heard Swedish best in Drömmer's bench), else KB-Whisper for Swedish, else
    /// Whisper small. Only engines on this Mac.
    private static func fileEngine(_ choice: TurnTranscription.Engine, for locale: Locale) throws -> FilePick {
        let lang = locale.language.languageCode?.identifier ?? ""
        func kb() -> FilePick? {
            guard lang == "sv", let spec = SpeechEngines.installedWhisper else { return nil }
            return FilePick(name: "whisper", model: spec.id, engine: whisper(spec, language: "sv"))
        }
        func small() -> FilePick? {
            guard SpeechEngines.store.isInstalled(.multilingualWhisper) else { return nil }
            return FilePick(name: "whisper", model: ModelSpec.multilingualWhisper.id, engine: whisper(.multilingualWhisper, language: nil))
        }
        func pianissimo() -> FilePick? {
            guard let model = PianissimoModel(rawValue: lang), let p = SpeechEngines.pianissimo[model], p.isInstalled else { return nil }
            return FilePick(name: "pianissimo", model: model.id, engine: p)
        }
        let missing = "The user installs it under Jämmer › Settings › Models; the API never installs it."
        switch choice {
        case .whisper:
            if let p = kb() ?? small() { return p }
            throw AgentAPI.APIError.modelMissing(lang == "sv" ? "kb-whisper-small" : ModelSpec.multilingualWhisper.id, "No Whisper model is installed. " + missing)
        case .pianissimo:
            guard let model = PianissimoModel(rawValue: lang) else {
                throw AgentAPI.APIError.unprocessable("unsupported_language", "Local Pianissimo does Swedish and Danish.")
            }
            if let p = pianissimo() { return p }
            throw AgentAPI.APIError.modelMissing(model.id, "\(model.id) isn't installed. " + missing)
        case .auto:
            if let p = pianissimo() ?? kb() ?? small() { return p }
            throw AgentAPI.APIError.modelMissing(lang == "sv" ? "kb-whisper-small" : ModelSpec.multilingualWhisper.id,
                                                 "No local speech model for \(locale.identifier(.bcp47)) is installed. " + missing)
        }
    }
}

/// What can be said of a file before it is decoded.
enum FileAudio {
    /// A WAV, RF64, BW64 or AIFF by its first bytes: read by Jämmer's own reader, never handed to the system's decoder.
    nonisolated static func isPCM(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return ["RIFF", "RF64", "BW64", "FORM"].contains(String(decoding: (try? h.read(upToCount: 4)) ?? Data(), as: UTF8.self))
    }

    /// How long it plays, from its header; 400 for what isn't audio Jämmer reads.
    nonisolated static func seconds(of url: URL) throws(AgentAPI.APIError) -> Double {
        let unreadable = AgentAPI.APIError.badRequest("That isn't audio Jämmer can read. Send WAV, AIFF, m4a, MP3, FLAC or CAF.")
        if isPCM(url) {
            guard let info = try? AudioFileReader.info(at: url), info.sampleRate > 0 else { throw unreadable }
            return Double(info.frames) / info.sampleRate
        }
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { throw unreadable }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
