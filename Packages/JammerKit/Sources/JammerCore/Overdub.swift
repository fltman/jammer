import Foundation

/// Overdub: a word or a sentence said again in a speaker's own voice, made by a voice service from text, with
/// the voice cloned from the recording (the-apps/PROVIDERS.md, rule 9; Anders, 2026-11-17: ElevenLabs, with the
/// user's own key).
///
/// The order is the rule's: the user attests first (the voice is their own, or its owner has given explicit
/// consent), and the person whose voice it is says the consent sentence in the recording itself; Jämmer hears
/// it in the transcript before anything is uploaded. Then the samples go to the service, which returns a
/// voice; a voice is kept in the project with its attestation, the consent's place and words, and the
/// provider's terms as read. Every piece of speech made from it is a source marked as made by that voice
/// (`SourceRef.synthetic`), and an export that contains one says so in its metadata. The service's own file is
/// kept as it came (its watermark with it); Jämmer plays a decoded copy.

/// What the user said before anything was recorded or uploaded.
public struct VoiceAttestation: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// The voice is the user's own.
        case own
        /// The voice's owner has given the user explicit and informed consent.
        case ownerConsent = "owner_consent"
    }
    public var kind: Kind
    /// The person is 18 or older (the provider takes no recordings of anyone younger).
    public var adult: Bool
    /// The consent sentence as Jämmer asked for it, and the place on the timeline where it was heard, with the
    /// words the transcript has there.
    public var sentence: String
    public var heardAt: ClosedRange<Double>
    public var heard: String
    /// When, and which wording of the terms was shown (the date of the provider's terms as read).
    public var date: Date
    public var termsRead: String

    public init(kind: Kind, adult: Bool, sentence: String, heardAt: ClosedRange<Double>, heard: String, date: Date, termsRead: String) {
        self.kind = kind; self.adult = adult; self.sentence = sentence; self.heardAt = heardAt; self.heard = heard; self.date = date; self.termsRead = termsRead
    }
}

/// A voice cloned at a provider for this project.
public struct ClonedVoice: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// The provider's slug ("elevenlabs") and its id for the voice.
    public var provider: String
    public var providerVoiceID: String
    /// The name the user gave (whose voice it is).
    public var name: String
    public var attestation: VoiceAttestation
    /// Seconds of the recording sent as samples, and where they were on the timeline.
    public var samples: [ClosedRange<Double>]
    public var created: Date
    /// Set when the voice was deleted at the provider; the record of consent is kept (the provider's terms ask
    /// for records of consents to be kept).
    public var deleted: Date?

    public init(id: UUID = UUID(), provider: String, providerVoiceID: String, name: String, attestation: VoiceAttestation, samples: [ClosedRange<Double>], created: Date) {
        self.id = id; self.provider = provider; self.providerVoiceID = providerVoiceID; self.name = name
        self.attestation = attestation; self.samples = samples; self.created = created
    }
}

/// Speech a voice service made: the mark a source carries.
public struct SyntheticSpeech: Codable, Hashable, Sendable {
    /// The cloned voice (`ClonedVoice.id`) and its name, the provider and model, the text, and when.
    public var voice: UUID
    public var voiceName: String
    public var provider: String
    public var model: String
    public var text: String
    public var made: Date
    /// Always true for Overdub: the voice is a clone of a person's.
    public var cloned: Bool

    public init(voice: UUID, voiceName: String, provider: String, model: String, text: String, made: Date, cloned: Bool = true) {
        self.voice = voice; self.voiceName = voiceName; self.provider = provider; self.model = model; self.text = text; self.made = made; self.cloned = cloned
    }
}

public enum Overdub {
    /// The sentence the person whose voice it is says in the recording, in the recording's language.
    public static func consentSentence(language: String) -> String {
        language.lowercased().hasPrefix("sv")
            ? "Jag samtycker till att min röst klonas med ElevenLabs för att redigera den här inspelningen."
            : "I consent to my voice being cloned with ElevenLabs to edit this recording."
    }

    /// Letters and digits only, lower case, without accents and spaces: "Eleven Labs" and "ElevenLabs" alike.
    static func folded(_ s: String) -> [Character] {
        let plain = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return Array(plain.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Whether `heard` (a transcript's words) says `sentence`: at least `share` of the sentence's letters, in
    /// order (the longest common subsequence), and not much more than it, so a sentence buried in a long
    /// passage, or a few words of it, doesn't count.
    public static func says(_ heard: String, sentence: String, share: Double = 0.85) -> Bool {
        let a = folded(sentence), b = folded(heard)
        guard !a.isEmpty, !b.isEmpty, Double(b.count) <= Double(a.count) * 1.6 else { return false }
        var row = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var diagonal = 0
            for j in 1...b.count {
                let up = row[j]
                row[j] = x == b[j - 1] ? diagonal + 1 : max(row[j], row[j - 1])
                diagonal = up
            }
        }
        return Double(row[b.count]) >= share * Double(a.count)
    }

    /// The provider's limits for samples, from its help pages (read 2026-11-17): "each file must be at least 5
    /// seconds long, and all your samples together must add up to at least 10 seconds"; "1–2 minutes of good
    /// audio" is what it recommends. Jämmer sends at most 3 minutes.
    public static let minSample = 5.0, minTotal = 10.0, maxTotal = 180.0
    /// ElevenLabs' models for this, by its models page (read 2026-11-17): "Use `eleven_v4` or
    /// `eleven_multilingual_v2`" for quality; both list Swedish. The first is the default.
    public static let models = ["eleven_multilingual_v2", "eleven_v4"]
}

public enum OverdubError: Error, LocalizedError, Equatable, KeyedFailure {
    case notAttested, notAdult, noTranscript, consentNotHeard(String), samplesTooShort, samplesTooLong, sampleOutside
    case noVoice, voiceDeleted, emptyText, textTooLong(Int), noTrack

    public var reason: String {
        switch self {
        case .notAttested: "not_attested"
        case .notAdult: "not_adult"
        case .noTranscript: "no_transcript"
        case .consentNotHeard: "consent_not_heard"
        case .samplesTooShort: "samples_too_short"
        case .samplesTooLong: "samples_too_long"
        case .sampleOutside: "sample_outside"
        case .noVoice: "no_voice"
        case .voiceDeleted: "voice_deleted"
        case .emptyText: "empty_text"
        case .textTooLong: "text_too_long"
        case .noTrack: "no_track"
        }
    }
    var said: Said {
        switch self {
        case .notAttested: Said("error.overdub.notAttested", "Before anything is uploaded, say whose voice it is: your own, or one whose owner has given you explicit consent.")
        case .notAdult: Said("error.overdub.notAdult", "A voice is cloned only from someone 18 or older.")
        case .noTranscript: Said("error.overdub.noTranscript", "Transcribe the recording first: Jämmer listens for the consent sentence in its transcript.")
        case .consentNotHeard(let sentence): Said("error.overdub.consentNotHeard", "The consent sentence isn't heard there. The person whose voice it is says, in the recording: “%@”", sentence)
        case .samplesTooShort: Said("error.overdub.samplesTooShort", "The voice needs at least 10 seconds of the speaker, in pieces of at least 5 seconds.")
        case .samplesTooLong: Said("error.overdub.samplesTooLong", "At most 3 minutes of the speaker are sent.")
        case .sampleOutside: Said("error.overdub.sampleOutside", "A piece of the speaker lies outside the document.")
        case .noVoice: Said("error.overdub.noVoice", "This document has no cloned voice by that id.")
        case .voiceDeleted: Said("error.overdub.voiceDeleted", "That voice was deleted at the provider.")
        case .emptyText: Said("error.overdub.emptyText", "Write what the voice should say.")
        case .textTooLong(let n): Said("error.overdub.textTooLong", "The text is longer than the model takes (%@ characters).", values: [Said.n(Double(n), 0)])
        case .noTrack: Said("error.overdub.noTrack", "No track has speech where the words are to be replaced.")
        }
    }
    public var errorDescription: String? { said.text }
    public var keyed: KeyedMessage? { said.keyed }
}

extension Project {
    /// Pieces of the speaker who says the consent sentence, for a voice's samples (seconds on the timeline):
    /// that speaker's words (by diarisation; without it, the words on the same track), run together where
    /// they follow within 0.7 s, each run at least `Overdub.minSample` long, nearest the consent first, up to
    /// two minutes ("1–2 minutes of good audio" is what the provider asks for). Untimed words are never used.
    public func voiceSamples(around consent: ClosedRange<Double>) -> [ClosedRange<Double>] {
        let consentFrames = frames(consent.lowerBound)..<frames(consent.upperBound)
        let said = placedWords(in: consentFrames).filter { $0.word.untimed != true }
        guard let first = said.first else { return [] }
        let speaker = said.compactMap(\.word.speaker).first
        let words = placedWords().filter { w in
            w.word.untimed != true && w.track == first.track && (speaker == nil || w.word.speaker == speaker)
        }
        var runs: [ClosedRange<Double>] = []
        var a: Frame?, b: Frame = 0
        let gap = frames(0.7)
        for w in words {
            if let s = a, w.start - b <= gap { b = max(b, w.end); _ = s } else {
                if let s = a { runs.append(seconds(s)...seconds(b)) }
                a = w.start; b = w.end
            }
        }
        if let s = a { runs.append(seconds(s)...seconds(b)) }
        let middle = (consent.lowerBound + consent.upperBound) / 2
        var out: [ClosedRange<Double>] = [], total = 0.0
        for r in runs.filter({ $0.upperBound - $0.lowerBound >= Overdub.minSample })
            .sorted(by: { abs(($0.lowerBound + $0.upperBound) / 2 - middle) < abs(($1.lowerBound + $1.upperBound) / 2 - middle) }) {
            let room = 120 - total
            guard room >= Overdub.minSample else { break }
            let piece = r.lowerBound...min(r.upperBound, r.lowerBound + room)
            out.append(piece)
            total += piece.upperBound - piece.lowerBound
        }
        return out.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Replaces `range` on the timeline with a piece of made speech on `track`, closing and opening the gap as
    /// a cut does on every track (what follows moves with the new length); the source comes with its words,
    /// spread over it (the service gives no times).
    public mutating func overdub(_ range: Range<Frame>, track: Int, with source: SourceRef, words text: String, language: String) throws {
        guard tracks.indices.contains(track) else { throw OverdubError.noTrack }
        let length = source.info.frames
        guard length > 0 else { throw EditError.emptyRange }
        if !range.isEmpty { try delete(range) }
        insertGap(at: range.lowerBound, length: length)
        sources.append(source)
        tracks[track].clips.append(Clip(sourceID: source.id, start: range.lowerBound, length: length))
        tracks[track].clips.sort { $0.start < $1.start }
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let total = max(1, tokens.reduce(0) { $0 + $1.count })
        var done = 0, words: [Word] = []
        for t in tokens {
            let a = Frame(Double(length) * Double(done) / Double(total))
            done += t.count
            let b = Frame(Double(length) * Double(done) / Double(total))
            words.append(Word(text: t, start: a, end: max(a + 1, b), untimed: true))
        }
        transcripts.append(SourceTranscript(sourceID: source.id, language: language, engine: "overdub", words: words, textOnly: true))
    }

    /// Made speech in `range`: the voices and providers to name in an export's metadata.
    public func syntheticSpeech(in range: Range<Frame>) -> [SyntheticSpeech] {
        var out: [SyntheticSpeech] = []
        for t in tracks {
            for c in t.clips where c.start < range.upperBound && c.end > range.lowerBound {
                if let s = source(c.sourceID)?.synthetic, !out.contains(where: { $0.voice == s.voice }) { out.append(s) }
            }
        }
        return out
    }

    /// The line an export carries when it contains made speech (WAV: LIST/INFO ICMT), in English, as metadata is.
    public func syntheticNote(in range: Range<Frame>) -> String? {
        let made = syntheticSpeech(in: range)
        guard !made.isEmpty else { return nil }
        let names = made.map { "\($0.voiceName) (\($0.provider), \($0.model))" }.joined(separator: "; ")
        return "Contains speech made with a cloned voice: \(names). Made by Jammer's Overdub with the voice owner's consent recorded in the project."
    }
}
