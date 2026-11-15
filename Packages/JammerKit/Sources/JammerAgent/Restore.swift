import Foundation
import JammerCore

/// The body of `restore` and `restore/preview` (and the query of
/// `analysis/restoration`), checked before anything runs: a bad value is a 400 and
/// no job is created.
public struct RestoreRequest: Sendable, Equatable {
    public var settings: Restoration.Settings
    public var start: Double?
    public var end: Double?
    /// Track ids; nil means every track.
    public var tracks: [UUID]?

    static let keys: Set<String> = ["kind", "amount", "start", "end", "tracks", "humFrequency", "sensitivity"]

    public static func parse(_ body: [String: Any]) throws(AgentAPI.APIError) -> RestoreRequest {
        if let unknown = body.keys.first(where: { !keys.contains($0) }) {
            throw .badRequest("Unknown field \"\(unknown)\". restore takes: \(keys.sorted().joined(separator: ", ")).")
        }
        guard let k = body["kind"] as? String else {
            throw .badRequest("kind is required: \(Restoration.Kind.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        guard let kind = Restoration.Kind(rawValue: k) else {
            throw .badRequest("kind must be one of \(Restoration.Kind.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        func number(_ key: String) throws(AgentAPI.APIError) -> Double? {
            guard let v = body[key] else { return nil }
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else {
                throw .badRequest("\(key) must be a number.")
            }
            return n.doubleValue
        }
        if kind == .denoise, Restoration.denoiser == nil { throw .notAvailable("denoise isn't available in this build.") }
        let amount = try number("amount") ?? 1
        guard (0...1).contains(amount) else { throw .badRequest("amount must be between 0 and 1.") }
        let hum = try number("humFrequency")
        if let hum, !(20...400).contains(hum) { throw .badRequest("humFrequency must be between 20 and 400 Hz.") }
        if hum != nil, kind != .dehum { throw .badRequest("humFrequency only applies to dehum.") }
        let sensitivity = try number("sensitivity") ?? 1
        guard (0.1...10).contains(sensitivity) else { throw .badRequest("sensitivity must be between 0.1 and 10.") }
        if body["sensitivity"] != nil, kind != .declick { throw .badRequest("sensitivity only applies to declick.") }
        let start = try number("start"), end = try number("end")
        if (start == nil) != (end == nil) { throw .badRequest("Give both start and end, or neither.") }
        if let start, let end {
            guard start >= 0, end > start else { throw .badRequest("end must be after start, and start can't be negative.") }
        }
        var tracks: [UUID]?
        if let t = body["tracks"] {
            guard let list = t as? [String], !list.isEmpty else { throw .badRequest("tracks must be a non-empty list of track ids.") }
            var ids: [UUID] = []
            for s in list {
                guard let id = UUID(uuidString: s) else { throw .badRequest("\"\(s)\" isn't a track id.") }
                ids.append(id)
            }
            tracks = ids
        }
        return RestoreRequest(settings: .init(kind: kind, amount: Float(amount), humFrequency: hum, sensitivity: sensitivity),
                              start: start, end: end, tracks: tracks)
    }

    /// For GET analysis/restoration: `?start=&end=&tracks=id,id`.
    public static func parseQuery(_ q: [String: String]) throws(AgentAPI.APIError) -> (start: Double?, end: Double?, tracks: [UUID]?) {
        let start = q["start"].flatMap(Double.init), end = q["end"].flatMap(Double.init)
        if q["start"] != nil && start == nil || q["end"] != nil && end == nil { throw .badRequest("start and end must be numbers.") }
        if (start == nil) != (end == nil) { throw .badRequest("Give both start and end, or neither.") }
        if let start, let end, !(start >= 0 && end > start) { throw .badRequest("end must be after start, and start can't be negative.") }
        var tracks: [UUID]?
        if let t = q["tracks"] {
            var ids: [UUID] = []
            for s in t.split(separator: ",") {
                guard let id = UUID(uuidString: String(s)) else { throw .badRequest("\"\(s)\" isn't a track id.") }
                ids.append(id)
            }
            tracks = ids
        }
        return (start, end, tracks)
    }
}
