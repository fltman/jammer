import Foundation
import JammerCore

/// POST /api/v1/transcribe: one short turn of speech, for a sibling's live captions (Drömmer; the coordinator approved
/// the direction 2026-11-25). No document and no window. The audio stays in memory: it is never written to disk and
/// never logged, and neither is the text. One turn at a time (409 busy); at most 15 s of 16 kHz mono PCM16 (413).
/// The window says while it works ("Transcribing for Drömmer"), and Settings can turn it off (403).
public enum TurnTranscription {
    public static let maxSeconds = 15.0
    public static let sampleRate = 16_000

    public enum Engine: String, CaseIterable, Sendable { case auto, whisper, pianissimo }

    public struct Request: Sendable {
        public var samples: [Float]
        public var language: String
        public var engine: Engine
        public var seconds: Double { Double(samples.count) / Double(sampleRate) }
    }

    /// Reads the query and the WAV body. 400 for what isn't one turn of 16 kHz mono PCM16, 413 for more than 15 s.
    public static func parse(query: [String: String], body: Data) throws(AgentAPI.APIError) -> Request {
        let language = query["language"] ?? "sv-SE"
        guard Locale(identifier: language).language.languageCode != nil, !language.isEmpty else {
            throw .badRequest("language must be a BCP 47 tag such as sv-SE.")
        }
        guard let engine = Engine(rawValue: query["engine"] ?? "auto") else {
            throw .badRequest("engine must be one of: \(Engine.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return Request(samples: try samples(fromWAV: body), language: language, engine: engine)
    }

    /// The samples of a 16 kHz mono 16-bit PCM WAV, as floats in −1…1.
    public static func samples(fromWAV data: Data) throws(AgentAPI.APIError) -> [Float] {
        let want = "The body must be a WAV file: 16 kHz, mono, 16-bit PCM."
        let bytes = [UInt8](data)
        func u32(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24 }
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        guard bytes.count >= 12, bytes[0..<4] == [0x52, 0x49, 0x46, 0x46], bytes[8..<12] == [0x57, 0x41, 0x56, 0x45] else {
            throw .badRequest(want)
        }
        var at = 12
        var format: (tag: Int, channels: Int, rate: Int, bits: Int)?
        while at + 8 <= bytes.count {
            let id = String(decoding: bytes[at..<at + 4], as: UTF8.self), size = u32(at + 4)
            let start = at + 8
            if id == "fmt ", size >= 16, start + 16 <= bytes.count {
                format = (u16(start), u16(start + 2), u32(start + 4), u16(start + 14))
            } else if id == "data" {
                guard let f = format else { throw .badRequest(want) }
                // WAVE_FORMAT_PCM, or WAVE_FORMAT_EXTENSIBLE carrying PCM.
                guard f.tag == 1 || f.tag == 0xFFFE, f.channels == 1, f.rate == sampleRate, f.bits == 16 else {
                    throw .badRequest(want + " This one is \(f.rate) Hz, \(f.channels) channel(s), \(f.bits)-bit.")
                }
                let end = min(bytes.count, start + size)
                let count = (end - start) / 2
                guard count > 0 else { throw .badRequest("The WAV file holds no audio.") }
                guard Double(count) / Double(sampleRate) <= maxSeconds + 0.001 else {
                    throw .tooLarge("A turn is at most \(Int(maxSeconds)) s; this one is \(String(format: "%.1f", Double(count) / Double(sampleRate))) s.")
                }
                var out = [Float](repeating: 0, count: count)
                for i in 0..<count {
                    out[i] = Float(Int16(bitPattern: UInt16(u16(start + 2 * i)))) / 32_768
                }
                return out
            }
            at = start + size + (size & 1)
        }
        throw .badRequest(want)
    }

    /// A word of the answer, its times in seconds from the start of the turn.
    public struct Word: Sendable, Equatable {
        public var text: String
        public var start: Double, end: Double
        public var confidence: Double?
        public init(text: String, start: Double, end: Double, confidence: Double?) {
            self.text = text; self.start = start; self.end = end; self.confidence = confidence
        }
    }

    /// `{"text", "words": [{"text", "start", "end", "confidence"}], "engine", "model", "ms"}`.
    public static func json(words: [Word], engine: String, model: String, ms: Int) -> [String: Any] {
        func r(_ v: Double) -> Double { (v * 1_000).rounded() / 1_000 }
        return ["text": words.map(\.text).joined(separator: " "),
                "words": words.map { w -> [String: Any] in
                    var d: [String: Any] = ["text": w.text, "start": r(w.start), "end": r(w.end)]
                    d["confidence"] = w.confidence.map { r($0) } ?? NSNull()
                    return d
                },
                "engine": engine, "model": model, "ms": ms]
    }

    /// One turn at a time: a second while one runs is 409 busy (no queue; the caller sends the next when it has
    /// the answer).
    public final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var busy = false
        public init() {}
        public func enter() throws(AgentAPI.APIError) {
            let ok = lock.withLock { () -> Bool in
                if busy { return false }
                busy = true
                return true
            }
            guard ok else { throw AgentAPI.APIError(409, "busy", "A turn is already being transcribed. Send the next one when it has been answered.") }
        }
        public func leave() { lock.withLock { busy = false } }
    }

    /// Settings › Agents can turn siblings' use of the transcription off; on by default.
    public static func off() -> AgentAPI.APIError {
        AgentAPI.APIError(403, "sibling_transcription_off", "Transcription for other apps is turned off in Jämmer › Settings › Agents.")
    }
}
