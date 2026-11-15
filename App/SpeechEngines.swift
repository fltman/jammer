import Foundation
import JammerCore
import JammerParakeet
import JammerSpeech
import JammerStems
import JammerWhisper

/// The stem model and its loaded network (built once; loading takes a few seconds).
enum Stems {
    static let model = StemModel(modelsFolder: ModelStore.standard().folder)
    nonisolated(unsafe) private static var cached: SpleeterNet?
    private static let lock = NSLock()
    static func net() throws -> SpleeterNet {
        try lock.withLock {
            if let cached { return cached }
            let n = try model.loadNet()
            cached = n
            return n
        }
    }
    static func forget() { lock.withLock { cached = nil; cachedSoundtrack = nil } }

    static let soundtrack = StemModel.Soundtrack(modelsFolder: ModelStore.standard().folder)
    nonisolated(unsafe) private static var cachedSoundtrack: MRXNet?
    static func soundtrackNet() throws -> MRXNet {
        try lock.withLock {
            if let cachedSoundtrack { return cachedSoundtrack }
            let n = try soundtrack.loadNet()
            cachedSoundtrack = n
            return n
        }
    }

    /// "music4" (Spleeter) or "dialog" (MRX).
    static func isInstalled(_ model: String) -> Bool { model == "dialog" ? soundtrack.isInstalled : Stems.model.isInstalled }
    static func engine(_ model: String) throws -> StemEngine {
        model == "dialog" ? SoundtrackEngine(try soundtrackNet()) : MaskingEngine(try net())
    }
}

/// Which recogniser transcribes: chosen per request ("auto", "apple", "parakeet",
/// "whisper"); models are installed by the user under Jämmer › Settings › Models.
@MainActor
enum SpeechEngines {
    static let store = ModelStore.standard()
    /// One Parakeet, so its model stays loaded between transcriptions.
    static let parakeet = ParakeetEngine(folder: store.folder, source: store.source)

    enum Choice: String, CaseIterable { case auto, apple, parakeet, whisper }

    struct Unavailable: Error, LocalizedError {
        var reason: String
        var message: String
        var errorDescription: String? { message }
    }

    static var installedWhisper: ModelSpec? { ModelSpec.catalogue.first { store.isInstalled($0) } }

    /// auto: KB-Whisper for Swedish when installed, else Parakeet for its 25 languages when
    /// installed, else Apple's recognisers.
    static func engine(_ choice: Choice, for locale: Locale) throws -> any TranscriptionEngine {
        let lang = locale.language.languageCode?.identifier ?? ""
        let whereToInstall = "Install it under Jämmer › Settings › Models."
        switch choice {
        case .apple:
            return AppleSpeechEngine()
        case .whisper:
            guard let kb = installedWhisper else { throw Unavailable(reason: "model_missing", message: "KB-Whisper isn't installed. \(whereToInstall)") }
            guard lang == "sv" else { throw Unavailable(reason: "unsupported_language", message: "KB-Whisper is for Swedish.") }
            return WhisperEngine(model: kb, path: store.path(for: kb))
        case .parakeet:
            guard parakeet.isInstalled else { throw Unavailable(reason: "model_missing", message: "Parakeet isn't installed. \(whereToInstall)") }
            guard ParakeetEngine.languages.contains(lang) else {
                throw Unavailable(reason: "unsupported_language", message: "Parakeet doesn't do \(locale.identifier(.bcp47)); it covers 25 European languages.")
            }
            return parakeet
        case .auto:
            if lang == "sv", let kb = installedWhisper { return WhisperEngine(model: kb, path: store.path(for: kb)) }
            if parakeet.isInstalled, ParakeetEngine.languages.contains(lang) { return parakeet }
            return AppleSpeechEngine()
        }
    }
}
