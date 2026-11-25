import Foundation

/// How a peak meter's bar moves (the window's meters; COMFORT 28): up at once, held, then down 20 dB a second. The bar
/// stays up at least a third of a second after it rose before it falls, so no part of it (the red top above all)
/// can light and go out more than three times a second, whatever the signal does (WCAG 2.3.1, SIBLINGS 9d56b54).
public enum MeterBallistics {
    public static let floor = -60.0
    public static let fall = 20.0         // dB a second
    public static let hold = 1.5          // seconds, the held peak's line
    public static let minimumOn = 1.0 / 3 // seconds the bar stays up after it rose

    public struct Level: Equatable, Sendable {
        public var db = -Double.infinity
        public var held = -Double.infinity
        public var heldAt = Date.distantPast
        /// When the bar last rose.
        public var roseAt = Date.distantPast
        public var clipped = false
        public init() {}
    }

    /// The level after `dt` seconds in which the peak was `db` (dBFS), at `now`.
    public static func next(_ l: Level, peak db: Double, dt: Double, now: Date) -> Level {
        var l = l
        if db >= l.db {
            l.db = db
            l.roseAt = now
        } else if now.timeIntervalSince(l.roseAt) >= minimumOn {
            let fallen = l.db - fall * dt
            l.db = max(db, fallen < floor ? -.infinity : fallen)
        }
        if db >= l.held || now.timeIntervalSince(l.heldAt) > hold { l.held = db; l.heldAt = now }
        if db >= 0 { l.clipped = true }
        return l
    }
}
