import Foundation
import JammerCore

/// Long work an agent starts and then follows: the series' shared job shape.
///
///     {"job": {"id", "kind", "status", "progress", "error"?: {code, message}, "result"?: {…}}}
///
/// POST that starts one answers 202 with it; GET /api/v1/jobs/{id} reads it;
/// DELETE /api/v1/jobs/{id} cancels it. Running jobs are listed in /api/v1/status.
public struct Job: Sendable, Equatable {
    public enum Status: String, Sendable { case queued, running, done, failed
        /// Written the American way in the API ("canceled"), as the interface's English is.
        case cancelled = "canceled"
    }

    public var id: String
    public var kind: String
    public var status: Status
    /// 0…1.
    public var progress: Double
    public var error: (code: String, message: String)?
    /// The failure by its key, for a window (`error.message` is its English, for the API).
    public var errorKeyed: KeyedMessage?
    /// Sets the failure from a sentence of ours or from an error (by its key when it has one).
    public mutating func fail(_ code: String, _ said: Said) { error = (code, said.text); errorKeyed = said.keyed }
    public mutating func fail(_ code: String, _ e: Error) { fail(code, Said.of(e)) }
    /// Small facts about the outcome (counts, seconds, names).
    public var result: [String: JSONValue]?
    /// The document it works on, if any.
    public var documentID: String?

    public init(id: String = UUID().uuidString, kind: String, documentID: String? = nil) {
        self.id = id
        self.kind = kind
        status = .queued
        progress = 0
        self.documentID = documentID
    }

    public var isFinished: Bool { status == .done || status == .failed || status == .cancelled }

    /// Canceled. A job whose paid request has left the app may have been charged, and says so in
    /// `result.mayHaveBeenCharged` (SIBLINGS.md §2, 2026-11-17): false only when the provider itself confirms
    /// the cancel came before the charge, which no provider Jämmer uses does; so true once a request has gone.
    /// Before any has gone, nothing is said about a charge: nothing reached the provider.
    public mutating func cancel(paidRequestLeft: Bool, providerConfirmedNoCharge: Bool = false) {
        status = .cancelled
        if paidRequestLeft { result = (result ?? [:]).merging(["mayHaveBeenCharged": .bool(!providerConfirmedNoCharge)]) { $1 } }
    }

    public var json: [String: Any] {
        var d: [String: Any] = ["id": id, "kind": kind, "status": status.rawValue, "progress": (progress * 1_000).rounded() / 1_000]
        if let error { d["error"] = ["code": error.code, "message": error.message] }
        if let result { d["result"] = result.mapValues(\.any) }
        if let documentID { d["document"] = documentID }
        return d
    }

    public static func == (a: Job, b: Job) -> Bool {
        a.id == b.id && a.kind == b.kind && a.status == b.status && a.progress == b.progress
            && a.error?.code == b.error?.code && a.error?.message == b.error?.message && a.result == b.result && a.documentID == b.documentID
    }
}

extension JSONValue {
    /// The value as JSONSerialization wants it.
    public var any: Any {
        switch self {
        case .number(let d): d
        case .string(let s): s
        case .bool(let b): b
        case .array(let a): a.map(\.any)
        case .null: NSNull()
        }
    }
}
