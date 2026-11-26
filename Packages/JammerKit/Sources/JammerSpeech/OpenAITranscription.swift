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

    /// 16 kHz mono 16-bit WAV.
    static func wav(_ samples: ArraySlice<Float>) -> Data {
        var d = Data(capacity: 44 + samples.count * 2)
        func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); le(UInt32(36 + samples.count * 2)); d.append(contentsOf: Array("WAVEfmt ".utf8))
        le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(SpeechAudio.rate)); le(UInt32(SpeechAudio.rate * 2)); le(UInt16(2)); le(UInt16(16))
        d.append(contentsOf: Array("data".utf8)); le(UInt32(samples.count * 2))
        d.append(SpeechAudio.pcm16(samples))
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

    public func transcribe(_ source: SourceRef, pool: SourcePool, locale: Locale,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> SourceTranscript {
        guard let key = key(), !key.isEmpty else { throw TranscriptionError.failed("there is no OpenAI key. Add it under Jämmer › Settings.") }
        guard !model.isEmpty else { throw TranscriptionError.failed("no OpenAI model is chosen.") }
        let samples = try SpeechAudio.mono16k(source, pool: pool)
        let limit = min(Int(maxSeconds * Double(SpeechAudio.rate)), (maxBytes - 44) / 2)
        guard limit > SpeechAudio.rate else { throw TranscriptionError.failed("the size limit is too small to send anything.") }
        let cuts = SpeechAudio.cuts(samples, limit: limit, search: Int(searchSeconds * Double(SpeechAudio.rate)))
        let scale = source.info.sampleRate / Double(SpeechAudio.rate)
        var words: [Word] = []
        var before = ""
        var heard: Frame = 0
        // Stopped after some pieces were answered: those words are paid for and go back with the stop.
        func stopped(_ e: CancellationError) -> Error {
            words.isEmpty ? e : TranscriptionStopped(partial: SourceTranscript(sourceID: source.id, language: locale.identifier(.bcp47), engine: id, words: words, textOnly: true),
                                                     covers: 0..<heard)
        }
        for i in 0..<(cuts.count - 1) {
            if Task.isCancelled { throw stopped(CancellationError()) }
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
            do { (data, response) = try await KeyedRequest.data(for: req, session: session) } catch let e as CancellationError { throw stopped(e) } catch {
                if Task.isCancelled { throw stopped(CancellationError()) }
                throw TranscriptionError.failed("OpenAI couldn't be reached (\(error.localizedDescription)). Nothing was changed.")
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw TranscriptionError.failed("OpenAI answered \(status): \(Self.said(data))") }
            guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let text = o["text"] as? String else {
                throw TranscriptionError.failed("OpenAI's answer wasn't in the form its documentation shows.")
            }
            let range = Frame(Double(cuts[i]) * scale)..<min(source.info.frames, Frame(Double(cuts[i + 1]) * scale))
            words += SpeechAudio.spread(text, over: range)
            heard = range.upperBound
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
