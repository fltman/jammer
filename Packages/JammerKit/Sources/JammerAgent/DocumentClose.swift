import Foundation

extension AgentAPI {
    /// The calls a closed connection stops (the coordinator, 2026-11-25: an agent can stop what it is waiting for):
    /// a short turn, an export and a run of steps. A stopped run applies nothing and a stopped export leaves nothing
    /// behind; the window says "Stopped by the agent". Every other call finishes what it began.
    public static func stopsOnHangUp(method: String, segments s: [String]) -> Bool {
        guard method == "POST" else { return false }
        return s == ["api", "v1", "transcribe"] || (s.count == 5 && Array(s.prefix(3)) == ["api", "v1", "documents"] && ["export", "steps"].contains(s[4]))
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
