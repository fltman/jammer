import Foundation
import JammerCore

/// OpenAI's file transcription, as its documentation describes it (read 2026-11-16):
/// `POST {endpoint}/audio/transcriptions`, multipart with `file` and `model`, `languages[]` for the
/// expected language (ISO 639-1) and `prompt` for "carrying context from a previous chunk"; the answer
/// is `{"text": …, "languages": [{"code": …}]}`. "Files can be up to 25 MB."
///
/// The recommended model gives the text and no times, so the transcript is marked `textOnly` and its
/// words are spread evenly over the piece they were heard in. Long recordings are cut into pieces here,
/// each under the limit, at the quietest moment near the end of the piece so that a sentence is not cut
/// in the middle ("Avoid splitting in the middle of a sentence").
///
/// The audio leaves the Mac and the call costs money: the app asks first, and the agent API needs
/// `allowPaid`. Nothing here has been run against OpenAI; it is tested against a stand-in server.
public struct OpenAITranscription: TranscriptionEngine {
    public var endpoint: URL
    public var model: String
    public var key: @Sendable () -> String?
    public var session: URLSession
    /// The provider's limit for one file, in bytes.
    public var maxBytes = 25_000_000
    /// The longest piece sent, in seconds (16 kHz mono 16-bit: 10 minutes is 19.2 MB).
    public var maxSeconds = 600.0
    /// How far back from the end of a piece the quietest moment is looked for.
    public var searchSeconds = 30.0

    public static let defaultEndpoint = URL(string: "https://api.openai.com/v1")!

    public init(endpoint: URL = OpenAITranscription.defaultEndpoint, model: String, key: @escaping @Sendable () -> String?, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.model = model
        self.key = key
        self.session = session
    }

    public var id: String { "openai \(model)" }
    /// The documentation gives no list of languages to check against; the provider answers for itself.
    public func supports(_ locale: Locale) async -> Bool { true }

    static let rate = 16_000

    /// Where to cut `samples` into pieces of at most `limit` samples: each cut at the quietest 0.4 s
    /// within `search` samples before the limit. Returns the piece boundaries, first 0, last `count`.
    static func cuts(_ samples: [Float], limit: Int, search: Int) -> [Int] {
        var out = [0]
        let window = max(1, rate * 4 / 10), hop = max(1, window / 4)
        while samples.count - out.last! > limit {
            let end = out.last! + limit
            let from = max(out.last! + limit / 2, end - search)
            var best = end, quietest = Float.greatestFiniteMagnitude
            var at = from
            while at + window <= end {
                var e: Float = 0
                for i in at..<(at + window) { e += samples[i] * samples[i] }
                if e < quietest { quietest = e; best = at + window / 2 }
                at += hop
            }
            out.append(best)
        }
        out.append(samples.count)
        return out
    }

    /// 16 kHz mono 16-bit WAV.
    static func wav(_ samples: ArraySlice<Float>) -> Data {
        var d = Data(capacity: 44 + samples.count * 2)
        func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); le(UInt32(36 + samples.count * 2)); d.append(contentsOf: Array("WAVEfmt ".utf8))
        le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(rate)); le(UInt32(rate * 2)); le(UInt16(2)); le(UInt16(16))
        d.append(contentsOf: Array("data".utf8)); le(UInt32(samples.count * 2))
        for s in samples { le(Int16(max(-1, min(1, s)) * 32_767)) }
        return d
    }

    static func multipart(_ fields: [(String, String)], file: Data, name: String, boundary: String) -> Data {
        var d = Data()
        for (k, v) in fields {
            d.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8))
        }
        d.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        d.append(file)
        d.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return d
    }

    /// The provider's own words for what went wrong, without anything of ours added.
    static func said(_ data: Data) -> String {
        if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let e = o["error"] as? [String: Any], let m = e["message"] as? String { return m }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }

    /// The words of a piece, spread over it by their length: there are no times to go by.
    static func spread(_ text: String, over range: Range<Frame>) -> [Word] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let total = tokens.reduce(0) { $0 + $1.count }
        guard total > 0, !range.isEmpty else { return [] }
        var out: [Word] = []
        var done = 0
        for t in tokens {
            let a = range.lowerBound + Frame(Double(range.count) * Double(done) / Double(total))
            done += t.count
            let b = range.lowerBound + Frame(Double(range.count) * Double(done) / Double(total))
            out.append(Word(text: t, start: a, end: max(a + 1, b), untimed: true))
        }
        return out
    }

    public func transcribe(_ source: SourceRef, pool: SourcePool, locale: Locale,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> SourceTranscript {
        guard let key = key(), !key.isEmpty else { throw TranscriptionError.failed("there is no OpenAI key. Add it under Jämmer › Settings.") }
        guard !model.isEmpty else { throw TranscriptionError.failed("no OpenAI model is chosen.") }
        let samples = try SpeechAudio.mono16k(source, pool: pool)
        let limit = min(Int(maxSeconds * Double(Self.rate)), (maxBytes - 44) / 2)
        guard limit > Self.rate else { throw TranscriptionError.failed("the size limit is too small to send anything.") }
        let cuts = Self.cuts(samples, limit: limit, search: Int(searchSeconds * Double(Self.rate)))
        let scale = source.info.sampleRate / Double(Self.rate)
        var words: [Word] = []
        var before = ""
        for i in 0..<(cuts.count - 1) {
            try Task.checkCancellation()
            let piece = samples[cuts[i]..<cuts[i + 1]]
            guard !piece.isEmpty else { continue }
            let file = Self.wav(piece)
            guard file.count <= maxBytes else { throw TranscriptionError.failed("a piece came out larger than the provider's limit.") }
            var fields = [("model", model)]
            if let code = locale.language.languageCode?.identifier, code.count == 2 { fields.append(("languages[]", code)) }
            // The end of what was heard so far, so that names and style carry over to the next piece.
            if !before.isEmpty { fields.append(("prompt", String(before.suffix(200)))) }
            let boundary = "jammer-\(UUID().uuidString)"
            var req = URLRequest(url: endpoint.appending(path: "audio/transcriptions"))
            req.httpMethod = "POST"
            req.timeoutInterval = 600
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req.httpBody = Self.multipart(fields, file: file, name: "part-\(i + 1).wav", boundary: boundary)
            let data: Data, response: URLResponse
            do { (data, response) = try await KeyedRequest.data(for: req, session: session) } catch let e as CancellationError { throw e } catch {
                throw TranscriptionError.failed("OpenAI couldn't be reached (\(error.localizedDescription)). Nothing was changed.")
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw TranscriptionError.failed("OpenAI answered \(status): \(Self.said(data))") }
            guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let text = o["text"] as? String else {
                throw TranscriptionError.failed("OpenAI's answer wasn't in the form its documentation shows.")
            }
            let range = Frame(Double(cuts[i]) * scale)..<min(source.info.frames, Frame(Double(cuts[i + 1]) * scale))
            words += Self.spread(text, over: range)
            before += " " + text
            progress(Double(cuts[i + 1]) / Double(max(1, samples.count)))
        }
        return SourceTranscript(sourceID: source.id, language: locale.identifier(.bcp47), engine: id, words: words, textOnly: true)
    }

    /// The provider's transcription models, from its own list: nothing is written into the app. The list
    /// carries no word for what a model does, so the id has to say it ("transcribe"); models for live
    /// audio and the one that answers in another form (speaker labels) are left out.
    public static func models(endpoint: URL = defaultEndpoint, key: String, session: URLSession = .shared) async throws -> [String] {
        var req = URLRequest(url: endpoint.appending(path: "models"))
        req.timeoutInterval = 15
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await KeyedRequest.data(for: req, session: session)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw TranscriptionError.failed("OpenAI answered \(status): \(said(data))") }
        let ids = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        return ids.filter { id in id.contains("transcribe") && !["live", "realtime", "diarize"].contains { id.contains($0) } }.sorted()
    }
}
