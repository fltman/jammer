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
        let pick = try choose(request.engine, for: locale)
        let slug = r.headers["x-sibling"]?.lowercased()
        let who = slug.map { AgentRouter.siblingNames[$0] ?? $0.capitalized } ?? L10n.text("turn.anotherApp")
        // Shown while it works; the user can stop it from any window.
        let task = Task { try await pick.run(request.samples, locale) }
        let waits = AgentRegistry.shared.sessions.map { s in (s, s.beginWait(L10n.text("turn.working", who)) { task.cancel() }) }
        AgentServer.shared.turnFor = who
        defer {
            for (s, w) in waits { s.endWait(w) }
            AgentServer.shared.turnFor = nil
        }
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

    private static func whisper(_ spec: ModelSpec, language: String?) -> WhisperEngine {
        if let w = whispers[spec.id] { return w }
        let w = WhisperEngine(model: spec, path: SpeechEngines.store.path(for: spec), language: language)
        whispers[spec.id] = w
        return w
    }

    /// auto: KB-Whisper for Swedish, then local Pianissimo for its language, then Whisper small (multilingual).
    private static func choose(_ engine: TurnTranscription.Engine, for locale: Locale) throws -> Pick {
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
            if let p = kb() ?? pianissimo() ?? small() { return p }
            throw AgentAPI.APIError.modelMissing(lang == "sv" ? "kb-whisper-small" : ModelSpec.multilingualWhisper.id,
                                                 "No local speech model for \(locale.identifier(.bcp47)) is installed. The user installs one under Jämmer › Settings › Models; the API never installs it.")
        }
    }
}
