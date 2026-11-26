import Foundation

extension AgentAPI {
    /// The calls a closed connection stops (the coordinator, 2026-11-25: an agent can stop what it is waiting for):
    /// a short turn, an export and a run of steps. A stopped run applies nothing and a stopped export leaves nothing
    /// behind; the window says "Stopped by the agent". Every other call finishes what it began.
    public static func stopsOnHangUp(method: String, segments s: [String]) -> Bool {
        guard method == "POST" else { return false }
        return s == ["api", "v1", "transcribe"] || (s.count == 5 && Array(s.prefix(3)) == ["api", "v1", "documents"] && ["export", "steps"].contains(s[4]))
    }

    /// What `DELETE …/voices/{voice}` answers since it went (404 `route_gone`).
    public static let deleteVoiceGone = "Deleting a cloned voice is the user's own, in the window: Speech › Delete Cloned Voice…. It can only be made again by paying again. GET …/voices lists them; suggest which one to delete."

    /// Watches a connection while its call runs, and says when the caller has gone: the connection's end, or an
    /// error. Bytes the caller sends after its request (a pipelined request, a stray newline) are read and dropped,
    /// and the watch goes on: before 2026-11-26 one receive decided, so any such byte ended the watch for good and
    /// a hang-up after it went unseen. The end of the caller's sending side counts as the caller gone (TCP can't tell
    /// it from a close until something is written; nginx's 499 takes it the same way): the guide says not to
    /// half-close while waiting.
    /// - Parameter receive: one read of at most a few bytes, answering (data, the end, an error).
    public static func watchForHangUp(receive: @escaping @Sendable (@escaping @Sendable (Data?, Bool, Error?) -> Void) -> Void,
                                      gone: @escaping @Sendable () -> Void) {
        receive { data, isComplete, error in
            if isComplete || error != nil { gone(); return }
            // Something more came: dropped, and the watch goes on.
            _ = data
            watchForHangUp(receive: receive, gone: gone)
        }
    }
}

/// DELETE /api/v1/documents/{id}: File › Close for an agent (the coordinator, 2026-11-25). A document with no unsaved
/// changes closes, whoever opened it. One with changes answers 409 unsaved_changes: the API never discards changes and
/// never saves without being asked. A linked document follows its close alert's rule: where the alert would ask
/// (changes not yet saved back), the API answers 409 instead.
public enum DocumentClose {
    public struct State: Sendable {
        public var edited: Bool
        /// Linked to a sibling's file that is still there (`saveBack` would write it).
        public var linkedFile: String?
        /// Was linked, and the file can no longer be written: why.
        public var lostLink: String?
        /// A sheet or alert is shown on the window: the user answers it first.
        public var sheet: Bool
        public init(edited: Bool, linkedFile: String? = nil, lostLink: String? = nil, sheet: Bool = false) {
            self.edited = edited; self.linkedFile = linkedFile; self.lostLink = lostLink; self.sheet = sheet
        }
    }

    /// Why the document can't close now, or nil: it may.
    public static func refusal(_ s: State) -> AgentAPI.APIError? {
        if s.sheet {
            return AgentAPI.APIError(409, "sheet_open", "A sheet is open on the document's window; the user answers it first.")
        }
        guard s.edited else { return nil }
        if let file = s.linkedFile {
            return AgentAPI.APIError(409, "unsaved_changes", "The document has changes not yet saved back to \(file). Save them back first (POST …/save); Jämmer never discards changes for an agent.")
        }
        if let why = s.lostLink {
            return AgentAPI.APIError(409, "unsaved_changes", "The document has changes, and its linked file can't be written (\(why)). The user decides in the window what happens to them.")
        }
        return AgentAPI.APIError(409, "unsaved_changes", "The document has unsaved changes. Save it first (POST …/save; a document never saved is saved the first time by the user, in the window). Jämmer never discards changes for an agent.")
    }
}
