import Foundation

/// POST /api/v1/transcribe/file: a whole file of speech for another app (Drömmer's film captions; the coordinator
/// approved it 2026-11-25), as a job with no document and no window, under the same terms as short turns
/// (TurnTranscription): Settings › Agents can turn it off (403), the window says while it works with a Stop, one
/// transcription for another app at a time (409 busy, shared with turns), local engines only.
///
/// The audio comes in the body or as an upload (POST /api/v1/uploads), never as a path: a path would let any local
/// process have Jämmer read any file. It lies in a private temporary folder only while the job runs and is removed
/// when it finishes, is stopped or fails. The words are kept in memory, given once, and then forgotten. Nothing of the
/// audio or the text is logged.
public enum FileTranscription {
    public static let kind = "transcribe_file"
    /// At most two hours of audio (413).
    public static let maxSeconds = 7_200.0
    /// Words nobody fetched are forgotten this long after the job finished.
    public static let keepUnfetched: TimeInterval = 600

    public enum Body: Equatable, Sendable {
        case bytes(Data)
        case upload(String)
    }

    /// Audio bytes (Content-Type audio/… or application/octet-stream) or `{"upload": "<id>"}`. A path is refused.
    public static func body(contentType: String?, data: Data) throws(AgentAPI.APIError) -> Body {
        let type = (contentType ?? "").lowercased()
        if type.hasPrefix("audio/") || type == "application/octet-stream" {
            guard !data.isEmpty else { throw .badRequest("The audio body is empty.") }
            return .bytes(data)
        }
        let ask = "Send the audio itself (Content-Type: audio/…), or {\"upload\": \"<id>\"} from POST /api/v1/uploads for a large file."
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw .badRequest(ask) }
        if obj["path"] != nil || obj["file"] != nil || obj["url"] != nil {
            throw .badRequest("Jämmer doesn't read a file named by a path here. " + ask)
        }
        guard let id = obj["upload"] as? String, !id.isEmpty else { throw .badRequest(ask) }
        return .upload(id)
    }

    /// 413 over two hours, 400 for a file with no sound.
    public static func checkLength(seconds: Double) throws(AgentAPI.APIError) {
        guard seconds > 0 else { throw .badRequest("The file holds no audio.") }
        guard seconds <= maxSeconds + 0.001 else {
            throw .tooLarge("A file is at most \(Int(maxSeconds / 3_600)) hours; this one is \(String(format: "%.1f", seconds / 60)) minutes.")
        }
    }

    /// `{"text", "words": [{"text", "start", "end", "confidence"}], "engine", "model", "language"}`, times in seconds
    /// from the start of the file.
    public static func json(words: [TurnTranscription.Word], engine: String, model: String, language: String) -> [String: Any] {
        var d = TurnTranscription.json(words: words, engine: engine, model: model, ms: 0)
        d["ms"] = nil
        d["language"] = language
        return d
    }

    /// The finished jobs' words: the first read of the job takes them, and later reads say they are gone.
    public final class Results: @unchecked Sendable {
        public enum Taken {
            case words([String: Any])
            /// Given already, or forgotten after `keepUnfetched`.
            case gone(fetched: Bool)
            /// Not a file job this store has seen.
            case none
        }

        private let lock = NSLock()
        private var waiting: [String: (json: [String: Any], at: Date)] = [:]
        private var gone: [String: (fetched: Bool, at: Date)] = [:]
        public init() {}

        public func put(_ id: String, _ json: [String: Any], at now: Date = Date()) {
            lock.withLock { waiting[id] = (json, now) }
        }

        public func take(_ id: String, now: Date = Date()) -> Taken {
            lock.withLock {
                sweep(now)
                if let w = waiting.removeValue(forKey: id) {
                    gone[id] = (true, now)
                    return .words(w.json)
                }
                if let g = gone[id] { return .gone(fetched: g.fetched) }
                return .none
            }
        }

        /// What waits unread (a stop or the app quitting forgets it all).
        public var count: Int { lock.withLock { waiting.count } }

        public func removeAll() { lock.withLock { waiting.removeAll() } }

        private func sweep(_ now: Date) {
            for (id, w) in waiting where now.timeIntervalSince(w.at) > FileTranscription.keepUnfetched {
                waiting[id] = nil
                gone[id] = (false, now)
            }
            // The record that words were here lasts as long as the job does (JobRegistry keeps an hour).
            for (id, g) in gone where now.timeIntervalSince(g.at) > 3_600 { gone[id] = nil }
        }
    }

    /// The job's JSON with what the store holds for it: the words on the first read, then `{"gone": true}`.
    public static func merged(_ job: [String: Any], id: String, results: Results, now: Date = Date()) -> [String: Any] {
        var j = job
        switch results.take(id, now: now) {
        case .words(let w):
            j["result"] = w
        case .gone(let fetched):
            j["result"] = ["gone": true, "why": fetched ? "fetched" : "expired",
                           "message": fetched ? "The words were given on an earlier read, and Jämmer has forgotten them."
                               : "Nobody fetched the words within \(Int(keepUnfetched / 60)) minutes, so Jämmer forgot them."]
        case .none:
            break
        }
        return j
    }
}
