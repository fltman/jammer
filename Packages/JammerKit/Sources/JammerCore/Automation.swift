import Foundation

/// A point of automation: a value at a place on the timeline.
public struct AutomationPoint: Codable, Hashable, Sendable {
    public var frame: Frame
    public var value: Double
    public init(frame: Frame, value: Double) {
        self.frame = frame
        self.value = value
    }
}

/// A lane of automation: one thing on one strip that changes over the timeline. The lane belongs to the
/// strip and is in timeline time, like the faders of a console; it is not part of any clip.
///
/// A gain lane is **added to the fader** (the fader is the trim): 0 dB everywhere is nothing, and a
/// strip without lanes is played exactly as it was before there was automation. Between points the value
/// goes in a straight line in dB; before the first point it is the first point's, after the last the last's.
public struct AutomationLane: Codable, Hashable, Sendable {
    /// What a lane moves. Only `gain` is built so far (docs/MIXER.md, "Automation"); the others are
    /// named here so that a project that has them is known for what it is.
    public enum Param: String, Codable, Sendable, CaseIterable { case gain, pan, mute, send }
    public enum Shape: String, Codable, Sendable { case linear, hold }

    /// The track or bus, or `Master.id`.
    public var strip: UUID
    public var param: Param
    /// For a send's level: the bus the send goes to.
    public var to: UUID?
    public var shape: Shape
    /// False: kept, but not heard.
    public var enabled: Bool
    /// Sorted by frame, at most one at a frame.
    public var points: [AutomationPoint]

    public init(strip: UUID, param: Param = .gain, to: UUID? = nil, shape: Shape = .linear, enabled: Bool = true, points: [AutomationPoint]) {
        self.strip = strip
        self.param = param
        self.to = to
        self.shape = shape
        self.enabled = enabled
        self.points = points
    }

    /// The lane's value at a frame, as the engine reads it.
    public func value(at frame: Frame) -> Double? {
        guard let first = points.first, let last = points.last else { return nil }
        if frame <= first.frame { return first.value }
        if frame >= last.frame { return last.value }
        let i = points.firstIndex { $0.frame > frame }!
        let a = points[i - 1], b = points[i]
        if shape == .hold { return a.value }
        return a.value + (b.value - a.value) * Double(frame - a.frame) / Double(b.frame - a.frame)
    }
}

public enum Automation {
    public static let maxPoints = 10_000
    public static let maxLanesPerStrip = 64
    /// What a gain lane may add to the fader, in dB.
    public static let gainRange = Mixer.gainRange
    /// The longest timeline a point may be on: 24 hours at 192 kHz.
    public static let maxFrame: Frame = 24 * 3600 * 192_000

    public enum Failure: Error, LocalizedError, Equatable {
        case noStrip(String), notBuilt(String), badValue(String), tooMany

        public var reason: String {
            switch self {
            case .noStrip: "not_found"
            case .notBuilt: "not_available"
            case .badValue: "bad_request"
            case .tooMany: "too_many"
            }
        }
        public var errorDescription: String? {
            switch self {
            case .noStrip(let id): "there is no track or bus with id \(id) (the master is \"master\")."
            case .notBuilt(let what): "automation of \(what) isn't built yet; only gain is."
            case .badValue(let m): m
            case .tooMany: "a lane can have \(Automation.maxPoints) points at most."
            }
        }
    }
}

extension Project {
    /// Whether anything in the project is automated. Such a project is saved as format 3.
    public var usesAutomation: Bool { !liveLanes.isEmpty }

    /// The lanes of strips that exist, with points. (A lane whose strip was removed is not saved.)
    public var liveLanes: [AutomationLane] {
        automation.filter { l in !l.points.isEmpty && (l.strip == Master.id || tracks.contains { $0.id == l.strip } || bus(l.strip) != nil) }
    }

    public func lanes(of strip: UUID) -> [AutomationLane] { liveLanes.filter { $0.strip == strip } }

    public func lane(strip: UUID, param: AutomationLane.Param, to: UUID? = nil) -> AutomationLane? {
        liveLanes.first { $0.strip == strip && $0.param == param && $0.to == to }
    }

    /// What the engine is given for a strip's level: the enabled gain lane's points, or nil.
    func gainCurve(of strip: UUID) -> (frames: [Int64], db: [Float])? {
        guard let l = lane(strip: strip, param: .gain), l.enabled, l.shape == .linear else { return nil }
        return (l.points.map(\.frame), l.points.map { Float($0.value) })
    }

    /// Writes a lane. `points` replace the whole lane, or with `range` only the points inside it (its ends
    /// included); points outside the range are never touched. A lane left without points is gone.
    /// Refused, with the name of what was wrong: a strip that isn't there, a point before 0 or after the
    /// document's end, a value outside the fader's range, two points at one frame, too many points.
    public mutating func setAutomation(strip: UUID, param: AutomationLane.Param = .gain, to: UUID? = nil, points new: [AutomationPoint],
                                       range: ClosedRange<Frame>? = nil, shape: AutomationLane.Shape? = nil, enabled: Bool? = nil) throws {
        guard strip == Master.id || tracks.contains(where: { $0.id == strip }) || bus(strip) != nil else { throw Automation.Failure.noStrip(strip.uuidString) }
        guard param == .gain, to == nil else { throw Automation.Failure.notBuilt(param == .gain ? "a send" : param.rawValue) }
        if let shape, shape != .linear { throw Automation.Failure.notBuilt("the hold shape") }
        let end = length
        for (i, p) in new.enumerated() {
            guard p.frame >= 0, p.frame <= end else {
                throw Automation.Failure.badValue("points[\(i)] is at \(seconds(p.frame)) s, outside the document (0 to \(seconds(end)) s).")
            }
            guard p.value.isFinite, Automation.gainRange.contains(p.value) else {
                throw Automation.Failure.badValue("points[\(i)] has the value \(p.value); a gain is \(Int(Automation.gainRange.lowerBound)) to \(Int(Automation.gainRange.upperBound)) dB.")
            }
            if let r = range, !r.contains(p.frame) {
                throw Automation.Failure.badValue("points[\(i)] is at \(seconds(p.frame)) s, outside the range given (\(seconds(r.lowerBound)) to \(seconds(r.upperBound)) s).")
            }
        }
        let sorted = new.sorted { $0.frame < $1.frame }
        for (a, b) in zip(sorted, sorted.dropFirst()) where a.frame == b.frame {
            throw Automation.Failure.badValue("two points are at \(seconds(a.frame)) s; a lane has one value at a time.")
        }
        var lane = lane(strip: strip, param: param, to: to) ?? AutomationLane(strip: strip, param: param, to: to, points: [])
        if let range { lane.points = (lane.points.filter { !range.contains($0.frame) } + sorted).sorted { $0.frame < $1.frame } }
        else { lane.points = sorted }
        if let shape { lane.shape = shape }
        if let enabled { lane.enabled = enabled }
        guard lane.points.count <= Automation.maxPoints else { throw Automation.Failure.tooMany }
        automation.removeAll { $0.strip == strip && $0.param == param && $0.to == to }
        if !lane.points.isEmpty { automation.append(lane) }
    }

    /// Takes a lane's points away: all of them, or those inside `range`. Answers how many went.
    @discardableResult
    public mutating func clearAutomation(strip: UUID, param: AutomationLane.Param, to: UUID? = nil, range: ClosedRange<Frame>? = nil) throws -> Int {
        guard strip == Master.id || tracks.contains(where: { $0.id == strip }) || bus(strip) != nil else { throw Automation.Failure.noStrip(strip.uuidString) }
        guard let i = automation.firstIndex(where: { $0.strip == strip && $0.param == param && $0.to == to }) else { return 0 }
        let before = automation[i].points.count
        if let range { automation[i].points.removeAll { range.contains($0.frame) } } else { automation[i].points = [] }
        let gone = before - automation[i].points.count
        if automation[i].points.isEmpty { automation.remove(at: i) }
        return gone
    }

    /// A strip's whole level at a frame, in dB: its fader, its VCA group and its gain lane together.
    /// nil for a strip that isn't there.
    public func level(of strip: UUID, at frame: Frame) -> (faderDB: Double, automationDB: Double?, totalDB: Double, muted: Bool)? {
        let fader: (gainDB: Double, muted: Bool)
        if let t = tracks.first(where: { $0.id == strip }) { fader = heard(gainDB: t.gainDB, muted: t.isMuted, vca: t.vca) }
        else if let b = bus(strip) { fader = heard(gainDB: b.gainDB, muted: b.isMuted, vca: b.vca) }
        else if strip == Master.id { fader = (master.gainDB, false) }
        else { return nil }
        let lane = lane(strip: strip, param: .gain).flatMap { $0.enabled ? $0.value(at: frame) : nil }
        return (fader.gainDB, lane, fader.gainDB + (lane ?? 0), fader.muted)
    }
}

extension AutomationLane {
    /// The lane with `pins` added wherever its value there is no longer what the pin says: used after
    /// points were moved, so that the level on each side of an edit is what it was.
    func pinned(_ pins: [AutomationPoint]) -> AutomationLane {
        var out = self
        for pin in pins where pin.frame >= 0 {
            if let v = out.value(at: pin.frame), abs(v - pin.value) < 1e-9 { continue }
            out.points.removeAll { $0.frame == pin.frame }
            out.points.append(pin)
            out.points.sort { $0.frame < $1.frame }
        }
        return out
    }

    /// After `range` was removed from the timeline and what followed moved left to close it: the points
    /// inside are gone, the later ones moved with the sound, and the level just before the cut and just
    /// after it is what it was (a point on each side where the line would otherwise have changed).
    func closing(_ range: Range<Frame>) -> AutomationLane {
        guard let before = value(at: range.lowerBound - 1), let after = value(at: range.upperBound) else { return self }
        var out = self
        out.points = points.compactMap { p in
            if range.contains(p.frame) { return nil }
            return p.frame >= range.upperBound ? AutomationPoint(frame: p.frame - Frame(range.count), value: p.value) : p
        }
        if out.points.isEmpty { out.points = [AutomationPoint(frame: range.lowerBound, value: after)] }
        return out.pinned((range.lowerBound > 0 ? [AutomationPoint(frame: range.lowerBound - 1, value: before)] : [])
                          + [AutomationPoint(frame: range.lowerBound, value: after)])
    }

    /// After a gap of `length` was opened at `t` and what followed moved right: the later points moved
    /// with the sound, and the level just before the gap and at the first frame after it is what it was.
    /// Through the gap the lane goes in a straight line from the one to the other.
    func opening(at t: Frame, length: Frame) -> AutomationLane {
        guard let before = value(at: t - 1), let after = value(at: t) else { return self }
        var out = self
        out.points = points.map { $0.frame >= t ? AutomationPoint(frame: $0.frame + length, value: $0.value) : $0 }
        return out.pinned((t > 0 ? [AutomationPoint(frame: t - 1, value: before)] : []) + [AutomationPoint(frame: t + length, value: after)])
    }
}
