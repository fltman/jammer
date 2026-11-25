import Foundation
import JammerCore

public enum VoiceTrackTranscription {
    /// A mono analysis file in project frames, containing just this track's selected speech spans.
    /// It is temporary. The project continues using its original source files.
    public static func writeInput(_ track: TrackSpeech, sampleRate: Double, pool: SourcePool, to url: URL) throws -> SourceRef {
        let writer = try WAVWriter(url: url, options: .init(encoding: .float32, channels: 1, sampleRate: sampleRate))
        var cursor: Frame = 0
        for span in track.spans {
            try Task.checkCancellation()
            if cursor < span.input.lowerBound {
                try writer.write([Float](repeating: 0, count: Int(span.input.lowerBound - cursor)))
                cursor = span.input.lowerBound
            }
            let channels = span.source.info.channels
            while cursor < span.input.upperBound {
                try Task.checkCancellation()
                let count = Int(min(16_384, span.input.upperBound - cursor))
                let start = span.sourceStart + cursor - span.input.lowerBound
                let samples = pool.read(span.source, from: start, count: count)
                guard samples.count == count * channels else { throw TranscriptionError.unreadableSource }
                if channels == 1 {
                    try writer.write(samples)
                } else {
                    var mono = [Float](repeating: 0, count: count)
                    for frame in mono.indices {
                        for channel in 0..<channels { mono[frame] += samples[frame * channels + channel] }
                        mono[frame] /= Float(channels)
                    }
                    try writer.write(mono)
                }
                cursor += Frame(count)
            }
        }
        try writer.finish()
        return SourceRef(name: track.track.name, path: url.path, info: try AudioFileReader.info(at: url))
    }

    /// Accept only explicit first-person introductions. A title-cased name has to follow
    /// the phrase, and competing names make the result ambiguous.
    public static func introducedName(_ words: [Word], language: String) -> String? {
        let names = selfNames(words, language: language)
        return names.count == 1 ? names.first : nil
    }

    /// How speakers name themselves, by language. `strong` names whatever title-cased name follows; `weak` ("I'm",
    /// "jag är") only a word that isn't one of the capitalised non-names (`notNames`: "I'm British"); `greeted` ("this
    /// is", "det här är") only after a greeting ("Hi, this is Anna"), since "This is London" names nobody.
    /// Measured on synthetic voices (IntroNamingEval, docs/TRANSCRIPTION.md).
    private static let selfPhrases: [String: (strong: String, weak: String, greeted: String)] = [
        "sv": (#"jag heter|mitt namn är"#, #"jag är"#, #"det här är|det är"#),
        "da": (#"jeg hedder|mit navn er"#, #"jeg er"#, #"det her er|det er"#),
        "en": (#"my name is|my name['’]s|i am called|i['’]m called"#, #"i['’]m|i am"#, #"this is|it['’]s"#),
        "de": (#"ich heiße|mein name ist"#, "", ""),
        "fr": (#"je m['’]appelle|mon nom est"#, "", ""),
        "es": (#"me llamo|mi nombre es"#, "", ""),
        "it": (#"mi chiamo|il mio nome è"#, "", ""),
        "no": (#"jeg heter|eg heiter|mitt namn er|mitt navn er"#, #"jeg er|eg er"#, #"dette er|det er"#),
        "nl": (#"ik heet|mijn naam is"#, "", ""),
        "pt": (#"me chamo|o meu nome é|meu nome é"#, "", ""),
    ]

    /// Capitalised words that follow "I'm" and aren't a name.
    static let notNames: Set<String> = [
        "I", "OK", "Okay", "Sorry", "English", "British", "American", "Canadian", "Australian", "Irish", "Scottish", "Welsh",
        "Swedish", "Danish", "Norwegian", "Finnish", "German", "French", "Spanish", "Italian", "Dutch", "Portuguese", "Polish",
        "Indian", "Chinese", "Japanese", "Korean", "African", "European", "Asian", "Jewish", "Muslim", "Christian", "Catholic",
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
        "January", "February", "March", "April", "June", "July", "August", "September", "October", "November", "December",
    ]

    private static func selfNames(_ words: [Word], language: String) -> Set<String> {
        let key = ["nb", "nn"].contains(language) ? "no" : language
        // A track whose language wasn't made out ("und") is read in every language that has phrases.
        let sets = selfPhrases[key].map { [$0] } ?? Array(selfPhrases.values)
        var names: Set<String> = []
        for p in sets {
            names.formUnion(extractNames(words, phrase: p.strong))
            names.formUnion(extractNames(words, phrase: p.weak).subtracting(notNames))
            names.formUnion(extractNames(words, phrase: p.greeted, greeting: true).subtracting(notNames))
        }
        return names
    }

    public struct Result: Sendable {
        public let track: TrackSpeech
        public let transcript: SourceTranscript

        public init(track: TrackSpeech, transcript: SourceTranscript) {
            self.track = track
            self.transcript = transcript
        }
    }

    public static func names(for results: [Result], sampleRate: Double) -> [UUID: String] {
        let byTrack = Dictionary(uniqueKeysWithValues: results.map { ($0.track.track.id, $0) })
        var names: [UUID: String] = [:]
        var knownOrAmbiguous: Set<UUID> = []
        var details: [UUID: [String]] = [:]
        for result in results where result.track.mayName {
            let id = result.track.track.id
            let candidates = selfNames(result.transcript.words, language: result.transcript.language)
            if !candidates.isEmpty { knownOrAmbiguous.insert(id) }
            if candidates.count == 1, let name = candidates.first {
                names[id] = name
                details[id] = introductionDetails(result.transcript.words, name: name, language: result.transcript.language)
            }
        }
        let placed = results.flatMap { result in
            result.track.timelineWords(result.transcript.words).map { (result.track.track.id, $0) }
        }.sorted { $0.1.start < $1.1.start }
        var runs: [(track: UUID, words: [Word])] = []
        for (id, word) in placed {
            if let last = runs.indices.last, runs[last].track == id { runs[last].words.append(word) }
            else { runs.append((id, [word])) }
        }
        var entered: Set<UUID> = []
        for i in runs.indices {
            let id = runs[i].track
            guard entered.insert(id).inserted, i > 0, !knownOrAmbiguous.contains(id),
                  byTrack[id]?.track.mayName == true,
                  let previous = runs[i - 1].words.last, let first = runs[i].words.first else { continue }
            let gap = Double(first.start - previous.end) / sampleRate
            guard gap >= -0.35, gap <= 12, let source = byTrack[runs[i - 1].track], source.track.mayName else { continue }
            let recent = runs[i - 1].words.suffix(24).filter { Double(first.start - $0.start) <= 16 * sampleRate }
            let candidates = guestNames(recent, language: source.transcript.language)
            guard candidates.count == 1, let name = candidates.first else { continue }
            names[id] = name
            details[id] = introductionDetails(recent, name: name, language: source.transcript.language)
        }

        let order = runs.reduce(into: [UUID]()) { if !$0.contains($1.track) { $0.append($1.track) } }
        let groups = Dictionary(grouping: order.filter { names[$0] != nil }) { names[$0, default: ""].folding(options: .caseInsensitive, locale: nil) }
        for ids in groups.values where ids.count > 1 {
            let counts = ids.reduce(into: [String: Int]()) { counts, id in
                for detail in Set(details[id, default: []].map { $0.lowercased() }) { counts[detail, default: 0] += 1 }
            }
            for (i, id) in ids.enumerated() {
                let label = details[id, default: []].first { counts[$0.lowercased()] == 1 } ?? String(i + 1)
                names[id] = "\(names[id, default: ""]) (\(label))"
            }
        }
        return names
    }

    private static func introductionDetails(_ words: [Word], name: String, language: String) -> [String] {
        let prefix = switch language {
        case "sv": #"jobbar (?:som|på|hos)|arbetar (?:som|på|hos)|är(?: en| ett)?|gillar|älskar|brinner för"#
        case "da": #"arbejder (?:som|hos|ved)|jobber (?:som|hos)|er(?: en| et)?|kan godt lide|elsker|interesserer mig for"#
        case "en": #"work(?:s)? (?:as(?: an?)?|at|for)|(?:am|is) an?|like(?:s)?|love(?:s)?|am interested in|is interested in|passionate about"#
        case "de": #"arbeite(?:t)? (?:als|bei)|bin (?:ein[ e]* )?|interessiere mich für"#
        case "fr": #"travaille chez|travaille comme|suis (?:un |une )?|aime|me passionne pour"#
        case "es": #"trabajo (?:en|como)|soy (?:un |una )?|me gusta|me interesa"#
        case "it": #"lavoro (?:per|alla|come)|sono (?:un |una )?|mi piace|mi interessa"#
        case "no", "nb", "nn": #"jobber (?:som|hos)|arbeider (?:som|hos)|er (?:en |eit )?|liker|brenn for|brenner for"#
        case "nl": #"werk (?:bij|als)|ben (?:een )?|houd van"#
        case "pt": #"trabalho (?:na|no|como)|sou (?:um |uma )?|gosto de"#
        default: ""
        }
        guard !prefix.isEmpty else { return [] }
        let text = words.map(\.text).joined(separator: " ")
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        guard let match = try? NSRegularExpression(pattern: #"(?i)\b"# + escapedName + #"\b"#)
            .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let location = Range(match.range, in: text) else { return [] }
        let context = String(text[location.upperBound...].split(whereSeparator: \.isWhitespace).prefix(32).joined(separator: " "))
        let pattern = #"(?i)\b(?:"# + prefix + #")\s+([^.!?,;:]{2,75})"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: context, range: NSRange(context.startIndex..., in: context)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: context) else { return nil }
            let value = context[range].trimmingCharacters(in: .whitespacesAndNewlines)
            let tokens = value.split(whereSeparator: \.isWhitespace)
            guard (1...6).contains(tokens.count), value.count <= 55, !value.lowercased().contains("://") else { return nil }
            return value
        }
    }

    private static func guestNames(_ words: [Word], language: String) -> Set<String> {
        let phrase = switch language {
        case "sv": #"välkommen|välkomna|vår gäst är|med oss har vi|nästa talare är|jag vill (?:välkomna|presentera)"#
        case "da": #"velkommen til|vores gæst er|næste taler er|jeg vil gerne (?:byde velkommen til|præsentere)"#
        case "en": #"please welcome|our guest is|joining us is|i['’]m joined by|our next speaker is|i['’]d like to introduce"#
        case "de": #"willkommen|unser gast ist|ich möchte vorstellen"#
        case "fr": #"bienvenue à|notre invitée? est|je vous présente"#
        case "es": #"damos la bienvenida a|nuestra invitada es|nuestro invitado es|les presento a"#
        case "it": #"diamo il benvenuto a|il nostro ospite è|vi presento"#
        case "no", "nb", "nn": #"velkommen til|vår gjest er|neste taler er"#
        case "nl": #"welkom|onze gast is|de volgende spreker is"#
        case "pt": #"damos as boas-vindas a|o nosso convidado é|nossa convidada é|apresento a vocês"#
        default: ""
        }
        return extractNames(words, phrase: phrase)
    }

    /// A greeting a speaker starts with: "Hi", "Good morning", "Hej allihop", "Hej och välkommen".
    static let greeting = #"(?:hej|hejsan|hallå|hello|hi|hey|hallo|bonjour|hola|ciao|olá|good\s+(?:morning|afternoon|evening)|god\s*(?:morgon|middag|kväll|dag))"#
        + #"(?:\s+(?:och\s+välkommen|and\s+welcome|everyone|everybody|all|there|allihop|allihopa|alla|alle))?[!,.]?\s+"#

    private static func extractNames(_ words: [Word], phrase: String, greeting needed: Bool = false) -> Set<String> {
        guard !phrase.isEmpty else { return [] }
        let name = #"\p{Lu}[\p{L}\p{M}]*(?:[’'\-]\p{L}[\p{L}\p{M}]*)*"#
        // At a sentence's start (a dash the transcriber put there aside), or after a greeting even when a comma
        // ends it ("Good morning, I'm Olivia"); never inside a sentence, which keeps out reported speech.
        let pattern = #"(?:^|[.!?]\s+)[-–—]?\s*(?i:"# + greeting + #")"# + (needed ? "" : "?") + #"(?i:"# + phrase
            + #")\s+("# + name + #"(?:\s+"# + name + #"){0,2})(?=\s*(?:[.!?,;]|$)|\s+\p{Ll})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let text = words.map(\.text).joined(separator: " ")
        let names = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }.filter { $0.count <= 80 }
        return Set(names)
    }
}
