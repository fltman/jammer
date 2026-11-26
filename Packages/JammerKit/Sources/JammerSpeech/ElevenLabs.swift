import Foundation
import JammerCore

/// ElevenLabs' voice cloning and speech, as its API reference describes them (read 2026-11-17):
/// - Instant Voice Cloning: `POST {base}/v1/voices/add`, multipart with `name` and `files`; the answer has
///   `voice_id` and `requires_verification` (a voice that matches a protected one needs verification first).
/// - Speech: `POST {base}/v1/text-to-speech/{voice_id}?output_format=…`, JSON `text`, `model_id`,
///   `previous_text`, `next_text`; the answer is the audio file ("File download"); the header `character-cost`
///   says what it cost in characters.
/// - `DELETE {base}/v1/voices/{voice_id}` answers `{"status": "ok"}`.
/// The key goes in the header `xi-api-key` (the reference's examples). It is the user's own, from the Keychain.
///
/// The output is MP3 at 44.1 kHz, 128 kbit/s, the default every plan may use (the reference: 192 kbit/s needs
/// Creator, PCM and WAV at 44.1 kHz need Pro; 48 kHz isn't said). The file is kept as ElevenLabs sent it, with
/// the watermark ElevenLabs embeds in what it generates; Jämmer plays a decoded copy.
///
/// Nothing here has been run against ElevenLabs; it is tested against a stand-in server.
public struct ElevenLabs: Sendable {
    public var base: URL
    public var key: @Sendable () -> String?
    public var session: URLSession

    public static let defaultBase = URL(string: "https://api.elevenlabs.io")!
    /// What ElevenLabs recommends for quality ("Use `eleven_v4` or `eleven_multilingual_v2`"); both say Swedish.
    public static let defaultModel = "eleven_multilingual_v2"
    public static var models: [String] { Overdub.models }
    /// Characters per request by model (the models page): 10 000 for both.
    public static let maxCharacters = 10_000
    public static let outputFormat = "mp3_44100_128"

    public init(base: URL = ElevenLabs.defaultBase, key: @escaping @Sendable () -> String?, session: URLSession? = nil) {
        self.base = base; self.key = key; self.session = session ?? LocalSession.session(for: base)
    }

    public struct Failure: Error, LocalizedError, Equatable {
        public var status: Int
        /// The provider's own words, or ours where it said nothing.
        public var message: String
        public var reason: String { status == 401 ? "key_rejected" : "provider_error" }
        public var errorDescription: String? { "ElevenLabs answered \(status): \(message)" }
    }
    public struct NoKey: Error, LocalizedError {
        public init() {}
        public var errorDescription: String? { "There is no ElevenLabs key. Add your own under Jämmer › Settings › Paid Services." }
    }

    func request(_ path: String, method: String) throws -> URLRequest {
        guard let key = key(), !key.isEmpty else { throw NoKey() }
        var r = URLRequest(url: base.appending(path: path))
        r.httpMethod = method
        r.setValue(key, forHTTPHeaderField: "xi-api-key")
        r.timeoutInterval = 120
        return r
    }

    /// The provider's words for what went wrong: `detail` as text, as `{message}`, or as a list of `{msg}`.
    static func said(_ data: Data) -> String {
        if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let d = o["detail"] as? String { return d }
            if let d = o["detail"] as? [String: Any], let m = d["message"] as? String { return m }
            if let d = o["detail"] as? [[String: Any]] { return d.compactMap { $0["msg"] as? String }.joined(separator: "; ") }
            if let m = o["message"] as? String { return m }
        }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }

    func send(_ r: URLRequest, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        let data: Data, response: URLResponse
        if let body { (data, response) = try await session.upload(for: r, from: body) } else { (data, response) = try await session.data(for: r) }
        guard let http = response as? HTTPURLResponse else { throw Failure(status: 0, message: "no HTTP answer") }
        guard (200..<300).contains(http.statusCode) else { throw Failure(status: http.statusCode, message: Self.said(data)) }
        return (data, http)
    }

    /// Clones a voice from `samples` (WAV files). Returns the provider's voice id, and whether it must be
    /// verified at the provider before it can speak.
    public func clone(name: String, description: String, samples: [Data]) async throws -> (voiceID: String, needsVerification: Bool) {
        var r = try request("v1/voices/add", method: "POST")
        let boundary = "jammer-\(UUID().uuidString)"
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ k: String, _ v: String) { body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8)) }
        field("name", name)
        field("description", description)
        for (i, s) in samples.enumerated() {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"sample\(i + 1).wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
            body.append(s)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        // Sent in a task of its own, so a Stop can't cut it off: once the samples have gone, ElevenLabs may make the
        // voice (and charge for it) whatever happens here, and only its answer says which voice to delete.
        let request = r, payload = body
        let (data, _) = try await Task.detached { try await self.send(request, body: payload) }.value
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = o["voice_id"] as? String, !id.isEmpty else {
            throw Failure(status: 200, message: "no voice_id in the answer")
        }
        return (id, (o["requires_verification"] as? Bool) ?? false)
    }

    /// Speech in a voice: the MP3 file as sent, and its cost in characters when the provider says it.
    public func speak(voiceID: String, text: String, model: String, previous: String?, next: String?) async throws -> (audio: Data, characters: Int?) {
        var r = try request("v1/text-to-speech/\(voiceID)", method: "POST")
        r.url = r.url.flatMap { u in
            var c = URLComponents(url: u, resolvingAgainstBaseURL: false)
            c?.queryItems = [URLQueryItem(name: "output_format", value: Self.outputFormat)]
            return c?.url
        }
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        var json: [String: Any] = ["text": text, "model_id": model]
        if let previous, !previous.isEmpty { json["previous_text"] = previous }
        if let next, !next.isEmpty { json["next_text"] = next }
        let (data, http) = try await send(r, body: try JSONSerialization.data(withJSONObject: json))
        guard !data.isEmpty else { throw Failure(status: http.statusCode, message: "the answer had no audio") }
        return (data, (http.value(forHTTPHeaderField: "character-cost")).flatMap { Int($0) })
    }

    /// Deletes a voice at the provider.
    public func delete(voiceID: String) async throws {
        _ = try await send(try request("v1/voices/\(voiceID)", method: "DELETE"))
    }

    /// Mono 16-bit WAV of `samples` at `rate`, for the clone's samples.
    public static func wav(_ samples: [Float], rate: Int) -> Data {
        var d = Data(capacity: 44 + samples.count * 2)
        func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); le(UInt32(36 + samples.count * 2)); d.append(contentsOf: Array("WAVEfmt ".utf8))
        le(UInt32(16)); le(UInt16(1)); le(UInt16(1)); le(UInt32(rate)); le(UInt32(rate * 2)); le(UInt16(2)); le(UInt16(16))
        d.append(contentsOf: Array("data".utf8)); le(UInt32(samples.count * 2))
        for s in samples { le(Int16(max(-1, min(1, s)) * 32_767)) }
        return d
    }
}
