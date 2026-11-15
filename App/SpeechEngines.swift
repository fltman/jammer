import Foundation
import JammerCore
import JammerParakeet
import JammerSpeech
import JammerWhisper

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
