import Foundation

/// A lane as a window shows it. The line is the curve the plan compiler hands the engine for the strip
/// (`gainCurve`, `panCurve`, `muteCurve`, `sendCurve`: the same calls, not a second reading of the
/// points), so what is drawn is what plays: a member of a VCA group has the group's lane in its line,
/// and an automated mute has its ramps. What is not in the line is said beside it (`onTopDB`).
public struct ShownLane: Sendable, Equatable {
    public var strip: UUID
    public var param: AutomationLane.Param
    public var to: UUID?
    /// The compiled curve: for a level or a send dB added to the fader, for a pan −1…1, for a mute the
    /// amplitude the strip is held to (1 heard, 0 muted).
    public var frames: [Frame]
    public var values: [Double]
    /// False: the lane is switched off. Nothing of it plays; the line is then its own points, to be drawn as such.
    public var plays: Bool
    /// The VCA group whose lane is part of the line, if one is.
    public var group: UUID?
    /// Whether the strip has a lane of its own in the line (false: the line is the group's alone).
    public var own: Bool
    /// For a level: the fader (and the group's fader), which the engine adds on top of the line.
    public var onTopDB: Double
    /// What a reader is told as the lane's points: the line's corners, or for a mute each change (1 muted, 0 heard).
    public var points: [AutomationPoint]

    /// The line at a frame, as the engine reads it: the first value before the first corner, the last
    /// after the last, a straight line between two.
    public func value(at frame: Frame) -> Double {
        guard let first = frames.first, let last = frames.last else { return 0 }
        if frame <= first { return values[0] }
        if frame >= last { return values[values.count - 1] }
        var lo = 0, hi = frames.count - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if frames[mid] <= frame { lo = mid } else { hi = mid } }
        return values[lo] + (values[hi] - values[lo]) * Double(frame - frames[lo]) / Double(frames[hi] - frames[lo])
    }

    /// The points inside a stretch of the timeline, at most `limit` of them, and how many there are in it.
    public func points(in range: ClosedRange<Frame>, limit: Int) -> (shown: ArraySlice<AutomationPoint>, count: Int) {
        var lo = 0, hi = points.count
        while lo < hi { let mid = (lo + hi) / 2; if points[mid].frame < range.lowerBound { lo = mid + 1 } else { hi = mid } }
        let start = lo
        hi = points.count
        while lo < hi { let mid = (lo + hi) / 2; if points[mid].frame <= range.upperBound { lo = mid + 1 } else { hi = mid } }
        return (points[start..<min(lo, start + limit)], lo - start)
    }
}

extension Automation {
    /// Where a value sits in a lane's height, 0 (bottom) to 1 (top). A level is not drawn straight in
    /// dB: 0 dB is at 0.7 and −24 dB at 0.3, so the stretch people work in has most of the height, and
    /// the rest down to the lowest value shares what is left. A pan has left at the top.
    public static func height(of value: Double, _ param: AutomationLane.Param) -> Double {
        switch param {
        case .gain, .send:
            let v = min(gainRange.upperBound, max(gainRange.lowerBound, value))
            if v >= 0 { return 0.7 + 0.3 * v / gainRange.upperBound }
            if v >= -24 { return 0.3 + 0.4 * (v + 24) / 24 }
            return 0.3 * (v - gainRange.lowerBound) / (-24 - gainRange.lowerBound)
        case .pan: return (1 - min(1, max(-1, value))) / 2
        case .mute: return min(1, max(0, value))
        }
    }
    /// The value at a height: the other way round.
    public static func value(atHeight h: Double, _ param: AutomationLane.Param) -> Double {
        let h = min(1, max(0, h))
        switch param {
        case .gain, .send:
            if h >= 0.7 { return (h - 0.7) / 0.3 * gainRange.upperBound }
            if h >= 0.3 { return -24 + (h - 0.3) / 0.4 * 24 }
            return gainRange.lowerBound + h / 0.3 * (-24 - gainRange.lowerBound)
        case .pan: return 1 - 2 * h
        case .mute: return h
        }
    }
}

extension Project {
    /// The lane of one kind to show on a strip, or nil when nothing of that kind is written for it (nor,
    /// for a level or a mute, for its VCA group). A VCA group itself is shown with its own lane.
    public func shownLane(_ param: AutomationLane.Param, of strip: UUID, to: UUID? = nil) -> ShownLane? {
        let own = lane(strip: strip, param: param, to: param == .send ? to : nil)
        let isGroup = vca(strip) != nil
        let groupID = param == .gain || param == .mute ? group(of: strip) : nil
        let groups = groupID.flatMap { lane(strip: $0, param: param) }.flatMap { $0.enabled ? $0 : nil }
        func made(_ frames: [Int64], _ values: [Float], plays: Bool, points: [AutomationPoint]? = nil) -> ShownLane {
            let v = values.map(Double.init)
            return ShownLane(strip: strip, param: param, to: to, frames: frames, values: v, plays: plays,
                             group: plays ? groups.map { _ in groupID! } : nil, own: own?.enabled == true || !plays,
                             onTopDB: param == .gain ? (level(of: strip, at: 0)?.faderDB ?? 0) : 0,
                             points: points ?? zip(frames, v).map { AutomationPoint(frame: $0, value: $1) })
        }
        // What the engine is given, when it is given anything. (A group is given nothing itself: its lane
        // goes to its members. It is shown as written.)
        if !isGroup {
            switch param {
            case .gain: if let c = gainCurve(of: strip) { return made(c.frames, c.db, plays: true) }
            case .pan: if let c = panCurve(of: strip) { return made(c.frames, c.values, plays: true) }
            case .send: if let to, let c = sendCurve(from: strip, to: to) { return made(c.frames, c.db, plays: true) }
            case .mute:
                if let c = muteCurve(of: strip) {
                    let lanes = [own, groups].compactMap { $0 }.filter(\.enabled)
                    let at = Array(Set(lanes.flatMap { $0.points.map(\.frame) })).sorted()
                    var changes: [AutomationPoint] = []
                    for f in at {
                        let muted = lanes.contains { ($0.value(at: f) ?? 0) >= 0.5 } ? 1.0 : 0.0
                        if changes.last?.value != muted { changes.append(AutomationPoint(frame: f, value: muted)) }
                    }
                    return made(c.frames, c.values, plays: true, points: changes)
                }
            }
        }
        // Switched off, a pan in a document that isn't stereo, or a group's own lane: the points as written.
        guard let own else { return nil }
        guard param == .mute else {
            return made(own.points.map(\.frame), own.points.map { Float($0.value) }, plays: isGroup && own.enabled, points: own.points)
        }
        // A mute as written holds each value until the next point: a step, drawn as one (no ramp is claimed).
        var frames: [Int64] = [], values: [Float] = []
        for (i, p) in own.points.enumerated() {
            let v: Float = p.value >= 0.5 ? 0 : 1
            if i > 0, values.last != v { frames.append(p.frame - 1); values.append(values.last!) }
            if frames.last.map({ $0 < p.frame }) ?? true { frames.append(p.frame); values.append(v) } else { values[values.count - 1] = v }
        }
        return made(frames, values, plays: isGroup && own.enabled, points: own.points)
    }
}
