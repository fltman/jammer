import Foundation

/// A call's checks in the series' one order (SIBLINGS 0e3ae19): first the schema and the ranges (400, 422), then what
/// it needs installed or configured (model_missing, model_unavailable, a key), then the price (paid_not_allowed,
/// unknown_price), and only then does anything run. A route lists its checks by stage, in any order; `run` keeps
/// the order, so an agent that is told to pay has first been told the call can work at all.
public enum CallChecks {
    public enum Stage: Int, Comparable, Sendable {
        case schema, requirements, price
        public static func < (a: Stage, b: Stage) -> Bool { a.rawValue < b.rawValue }
    }

    /// Every operation with a requirement (`Requirements.all`'s neededBy) or a price (paid operations, and the calls
    /// that can choose a paid engine): each one's route runs its checks through `run`.
    public static let gated: Set<String> = ["transcribe", "transcribe_voice_tracks", "diarize", "split_speakers", "request_voice_profile",
                                            "separate", "add_insert", "clone_voice", "overdub", "batch"]

    public static func run(_ op: String, _ checks: [(Stage, () throws -> Void)]) throws {
        assert(gated.contains(op), "\(op) isn't in CallChecks.gated")
        for (_, check) in checks.enumerated().sorted(by: { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }).map(\.element) {
            try check()
        }
    }
}
