import Foundation
import JammerAgent
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

    static let pianissimo = Dictionary(uniqueKeysWithValues: PianissimoModel.allCases.map {
        ($0, PianissimoEngine(model: $0, store: store))
    })

    static let multilingualWhisper = WhisperEngine(model: .multilingualWhisper,
                                                     path: store.path(for: .multilingualWhisper), language: nil)

    typealias Choice = TranscriptionChoice

    static var bergetKey: String? {
        #if DEBUG
        if bergetEndpoint != BergetPianissimo.defaultEndpoint,
           let key = UserDefaults.standard.string(forKey: "bergetTestKey"), !key.isEmpty { return key }
        #endif
        return Keychain.get("berget")
    }

    static var bergetEndpoint: URL {
        #if DEBUG
        if let value = UserDefaults.standard.string(forKey: "bergetEndpoint"), let url = URL(string: value),
           url.scheme == "ws", url.host() == "127.0.0.1" { return url }
        #endif
        return BergetPianissimo.defaultEndpoint
    }

    static func bergetPriceLine(_ price: Choice.Price) -> String {
        L10n.text("berget.transcription.price", L10n.number(price.amount, 4), price.source, price.asOf)
    }

    /// The key, from the Keychain. A debug build started with `-openaiTestKey` and `-openaiEndpoint` on
    /// this Mac uses those instead, so the whole flow can be tried against a stand-in server without a
    /// key and without a request to the provider; a release build has neither argument.
    static var openAIKey: String? {
        #if DEBUG
        if openAIEndpoint != OpenAITranscription.defaultEndpoint, let k = UserDefaults.standard.string(forKey: "openaiTestKey"), !k.isEmpty { return k }
        #endif
        return Keychain.get("openai")
    }
    static var openAIEndpoint: URL {
        #if DEBUG
        if let s = UserDefaults.standard.string(forKey: "openaiEndpoint"), let u = URL(string: s), u.host() == "127.0.0.1" { return u }
        #endif
        return OpenAITranscription.defaultEndpoint
    }

    /// The model for OpenAI, chosen from the provider's own list (`OpenAITranscription.models`); no id is written into the app.
    static var openAIModel: String { UserDefaults.standard.string(forKey: "transcribe.openai.model") ?? "" }

    struct Unavailable: Error, LocalizedError, KeyedFailure {
        var reason: String
        var said: Said
        var requirement: String?
        init(reason: String, message: Said, requirement: String? = nil) {
            self.reason = reason
            said = message
            self.requirement = requirement
        }
        var message: String { said.text }
        var errorDescription: String? { said.text }
        var keyed: KeyedMessage? { said.keyed }
    }

    static var installedWhisper: ModelSpec? { ModelSpec.catalogue.first { store.isInstalled($0) } }

    /// auto: KB-Whisper for Swedish when installed, else Parakeet for its 25 languages when
    /// installed, else Apple's recognisers.
    static func engine(_ choice: Choice, for locale: Locale, model: String? = nil) throws -> any TranscriptionEngine {
        let lang = locale.language.languageCode?.identifier ?? ""
        switch choice {
        case .pianissimo:
            guard let model = PianissimoModel(rawValue: lang), let engine = pianissimo[model] else {
                throw Unavailable(reason: "unsupported_language", message: Said("engine.pianissimo.language", "Local Pianissimo supports Swedish and Danish."))
            }
            guard engine.isInstalled else {
                throw Unavailable(reason: "model_missing", message: Said("engine.pianissimo.missing", "Install the matching Klang Pianissimo model in Jämmer › Settings › Models."), requirement: model.id)
            }
            return engine
        case .bergetPianissimo:
            guard lang == "sv" else {
                throw Unavailable(reason: "unsupported_language", message: Said("engine.berget.language", "Pianissimo at Berget AI supports Swedish."))
            }
            guard let key = bergetKey, !key.isEmpty else {
                throw Unavailable(reason: "missing_key", message: Said("engine.berget.key", "Add your Berget AI key in Jämmer › Settings › Paid Services."))
            }
            return BergetPianissimo(key: key, endpoint: bergetEndpoint)
        case .openai:
            guard let key = openAIKey, !key.isEmpty else { throw Unavailable(reason: "missing_key", message: Said("engine.there_openai_key_add", "There is no OpenAI key. Add it in the assistant's settings.")) }
            let model = model ?? openAIModel
            guard !model.isEmpty else { throw Unavailable(reason: "model_missing", message: Said("engine.openai_transcription_model_chosen", "No OpenAI transcription model is chosen. Pass \"model\" with one of the provider's transcription models.")) }
            return OpenAITranscription(endpoint: openAIEndpoint, model: model, key: { key })
        case .apple:
            return AppleSpeechEngine()
        case .whisper:
            guard let kb = installedWhisper else { throw Unavailable(reason: "model_missing", message: Said("engine.whisper.missing", "KB-Whisper isn't installed. Install it under Jämmer › Settings › Models.")) }
            guard lang == "sv" else { throw Unavailable(reason: "unsupported_language", message: Said("engine.kb_whisper_swedish", "KB-Whisper is for Swedish.")) }
            return WhisperEngine(model: kb, path: store.path(for: kb))
        case .parakeet:
            guard parakeet.isInstalled else { throw Unavailable(reason: "model_missing", message: Said("engine.parakeet.missing", "Parakeet isn't installed. Install it under Jämmer › Settings › Models.")) }
            guard ParakeetEngine.languages.contains(lang) else {
                throw Unavailable(reason: "unsupported_language", message: Said("engine.parakeet_doesn_t_do", "Parakeet doesn't do %@; it covers 25 European languages.", "\(locale.identifier(.bcp47))"))
            }
            return parakeet
        case .auto:
            if lang == "sv", let kb = installedWhisper { return WhisperEngine(model: kb, path: store.path(for: kb)) }
            if parakeet.isInstalled, ParakeetEngine.languages.contains(lang) { return parakeet }
            return AppleSpeechEngine()
        }
    }
}
