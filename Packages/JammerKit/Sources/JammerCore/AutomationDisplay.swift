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
        case .plugin: return 0.5      // a plugin's parameter has its own range: not drawn on this scale
        // A place: left (positive) at the top as for pan, behind at either edge; up from level to overhead.
        case .azimuth: return (min(180, max(-180, value)) + 180) / 360
        case .elevation: return min(90, max(0, value)) / 90
        // A field's turn: as an azimuth (left at the top); a pitch and a roll from their least to their most.
        case .yaw: return (min(180, max(-180, value)) + 180) / 360
        case .pitch: return (min(90, max(-90, value)) + 90) / 180
        case .roll: return (min(180, max(-180, value)) + 180) / 360
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
        case .plugin: return 0
        case .azimuth: return h * 360 - 180
        case .elevation: return h * 90
        case .yaw, .roll: return h * 360 - 180
        case .pitch: return h * 180 - 90
        }
    }
}

extension Project {
    /// The lane of one kind to show on a strip, or nil when nothing of that kind is written for it (nor,
    /// for a level or a mute, for its VCA group). A VCA group itself is shown with its own lane.
    public func shownLane(_ param: AutomationLane.Param, of strip: UUID, to: UUID? = nil, insert: UUID? = nil, parameter: String? = nil) -> ShownLane? {
        let own = lane(strip: strip, param: param, to: param == .send ? to : nil,
                       insert: param == .plugin ? insert : nil, parameter: param == .plugin ? parameter : nil)
        // A plugin's parameter and a track's place are applied as written: switched on, they play.
        let direct = param == .plugin || param == .azimuth || param == .elevation || param == .yaw || param == .pitch || param == .roll
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
            case .plugin, .azimuth, .elevation, .yaw, .pitch, .roll: break       // shown from their own points, below
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
            return made(own.points.map(\.frame), own.points.map { Float($0.value) }, plays: (isGroup || direct) && own.enabled, points: own.points)
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

// MARK: Changing a lane by hand

extension AutomationLane {
    /// Where point `i` lands when it is asked to go to `frame` and `value`: never onto or past a
    /// neighbour (it stops one frame short), never off the timeline (`0...limit`), and never outside
    /// the values a lane of its kind may have. A mute is 1 or 0.
    public func placed(_ i: Int, frame: Frame, value: Double, limit: Frame) -> AutomationPoint {
        let lo = i > 0 ? points[i - 1].frame + 1 : 0
        let hi = i < points.count - 1 ? points[i + 1].frame - 1 : max(limit, points[i].frame)
        let range = Automation.range(of: param)
        let v = param == .mute ? (value >= 0.5 ? 1 : 0) : min(range.upperBound, max(range.lowerBound, value))
        // Neighbours on the frames next to it: there is nowhere to go in time.
        guard lo <= hi else { return AutomationPoint(frame: points[i].frame, value: v) }
        return AutomationPoint(frame: min(max(frame, lo), hi), value: v)
    }
    /// The lane with point `i` moved, as `placed` says.
    public func moving(_ i: Int, frame: Frame, value: Double, limit: Frame) -> AutomationLane {
        var out = self
        out.points[i] = placed(i, frame: frame, value: value, limit: limit)
        return out
    }
    /// The lane with several points moved together, by the same time and the same value: as one piece.
    /// The piece stops when any of its points is one frame short of a neighbour that isn't moving, or
    /// at an end of the timeline, or when one of its values reaches the edge of what the lane may have;
    /// so the points keep their distances and their shape, and nothing passes anything. A mute's values stay.
    public func moving(_ indices: Set<Int>, byFrames: Frame, byValue: Double, limit: Frame) -> AutomationLane {
        let chosen = indices.filter { points.indices.contains($0) }.sorted()
        guard !chosen.isEmpty else { return self }
        var lo = Frame.min, hi = Frame.max
        for i in chosen {
            if !indices.contains(i - 1) { lo = max(lo, (i > 0 ? points[i - 1].frame + 1 : 0) - points[i].frame) }
            if !indices.contains(i + 1) { hi = min(hi, (i < points.count - 1 ? points[i + 1].frame - 1 : max(limit, points[i].frame)) - points[i].frame) }
        }
        let df = lo <= hi ? min(max(byFrames, lo), hi) : 0
        let range = Automation.range(of: param), values = chosen.map { points[$0].value }
        let dv = param == .mute ? 0 : min(max(byValue, range.lowerBound - values.min()!), range.upperBound - values.max()!)
        var out = self
        for i in chosen { out.points[i] = AutomationPoint(frame: points[i].frame + df, value: points[i].value + dv) }
        return out
    }
    /// The lane with a point more, and where it is; nil when there is a point at that frame already.
    public func adding(frame: Frame, value: Double) -> (lane: AutomationLane, index: Int)? {
        guard !points.contains(where: { $0.frame == frame }) else { return nil }
        let range = Automation.range(of: param)
        let v = param == .mute ? (value >= 0.5 ? 1 : 0) : min(range.upperBound, max(range.lowerBound, value))
        var out = self
        let i = points.firstIndex { $0.frame > frame } ?? points.count
        out.points.insert(AutomationPoint(frame: frame, value: v), at: i)
        return (out, i)
    }
    /// The value the lane has at a frame when it has points, or what a strip without a lane has there:
    /// nothing added, the centre, heard.
    public func valueOrRest(at frame: Frame) -> Double { value(at: frame) ?? 0 }
}

extension Automation {
    /// A value one step of the keys away: `by` in the lane's own unit, landing on whole steps of
    /// `grain` (0.1 dB, 1 %), so that the keys give exact values. A mute flips.
    public static func stepped(_ value: Double, by: Double, grain: Double, _ param: AutomationLane.Param) -> Double {
        if param == .mute { return value >= 0.5 ? 0 : 1 }
        let range = range(of: param)
        let v = ((value + by) / grain).rounded() * grain
        return min(range.upperBound, max(range.lowerBound, (v * 1_000).rounded() / 1_000))
    }
}

// MARK: Written from a fader while the sound plays

extension Automation {
    /// How far the written line may be from what was heard, in dB.
    public static let writeTolerance = 0.1
    /// How long a level takes to go back to the lane when a fader in Touch is let go, in seconds.
    public static let writeGlide = 0.25

    /// Fewer points for the same line: the straight lines through the points that are kept are never
    /// more than `tolerance` (in the lane's unit, measured straight up and down, which is how a level is
    /// heard) from any point that was left out. The first and the last are always kept.
    ///
    /// One walk along the points, so a pass of any length costs in proportion to its length (a method
    /// that splits at the worst point, tried first, took minutes on a long restless pass): from the last
    /// kept point, each next point is taken as the far end for as long as the line to it stays within
    /// the tolerance of every point between; when one can't be, the point before it is kept, and the
    /// walk goes on from there. What "stays within" needs is only the span of slopes that all the points
    /// so far allow, which narrows as points are passed.
    public static func thinned(_ points: [AutomationPoint], tolerance: Double) -> [AutomationPoint] {
        guard points.count > 2 else { return points }
        var out = [points[0]]
        var anchor = points[0]
        var lo = -Double.infinity, hi = Double.infinity      // the slopes from the anchor that every passed point allows
        var i = 1
        while i < points.count {
            let p = points[i]
            let dt = Double(p.frame - anchor.frame)
            guard dt > 0 else { i += 1; continue }
            let slope = (p.value - anchor.value) / dt
            if slope >= lo && slope <= hi {
                // The line from the anchor to this point is within the tolerance of all between: it may be the far end.
                lo = max(lo, (p.value - tolerance - anchor.value) / dt)
                hi = min(hi, (p.value + tolerance - anchor.value) / dt)
                i += 1
            } else {
                // It can't be: the point before it is kept (the line to that one was within the tolerance), and is the new anchor.
                anchor = points[i - 1]
                out.append(anchor)
                lo = -.infinity
                hi = .infinity
            }
        }
        if out.last != points[points.count - 1] { out.append(points[points.count - 1]) }
        return out
    }
}

extension AutomationLane {
    /// The lane after a pass of writing: `heard` is the level the engine put on the strip in the lane's
    /// place, block by block, in the order it was played (frames rising). Between its first and its last
    /// frame the lane becomes that line, thinned to within `tolerance` of it; outside that stretch the
    /// lane is what it was, at every frame, held there by a point just before and just after. A pass of
    /// nothing changes nothing. If the result would have more points than a lane may, the pass is
    /// thinned further (the tolerance doubled until it fits), and the tolerance that was used is given back.
    public func written(_ heard: [AutomationPoint], tolerance: Double = Automation.writeTolerance) -> (lane: AutomationLane, tolerance: Double) {
        guard let first = heard.first, let last = heard.last, last.frame >= first.frame else { return (self, tolerance) }
        let outside = points.filter { $0.frame < first.frame - 1 || $0.frame > last.frame + 1 }
        // What the lane was just outside the stretch (nothing added, where there was no lane).
        var edges: [AutomationPoint] = []
        if first.frame > 0 { edges.append(AutomationPoint(frame: first.frame - 1, value: valueOrRest(at: first.frame - 1))) }
        edges.append(AutomationPoint(frame: last.frame + 1, value: valueOrRest(at: last.frame + 1)))
        var used = tolerance
        var inside = Automation.thinned(heard, tolerance: used)
        while outside.count + edges.count + inside.count > Automation.maxPoints, inside.count > 2 {
            used *= 2
            inside = Automation.thinned(heard, tolerance: used)
        }
        var out = self
        out.points = (outside + edges + inside).sorted { $0.frame < $1.frame }
        return (out, used)
    }
}
