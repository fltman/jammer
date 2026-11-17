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
    /// What a lane moves (docs/MIXER.md, "Automation"): a strip's level, pan or mute, or the level of one
    /// of its sends (`to` then names the bus the send goes to). A VCA group has a level and a mute, and
    /// its lanes are added to its members' when the plan is made, as its fader is.
    /// `plugin`: one parameter of one plugin on the strip (`insert` and `parameter` then say which), in the
    /// parameter's own unit, a straight line between points.
    /// azimuth and elevation: a track's place in a layout wider than stereo (the surround panner), in degrees.
    public enum Param: String, Codable, Sendable, CaseIterable { case gain, pan, mute, send, plugin, azimuth, elevation }
    public enum Shape: String, Codable, Sendable { case linear, hold }

    /// The track, bus or VCA group, or `Master.id`.
    public var strip: UUID
    public var param: Param
    /// For a send's level: the bus the send goes to.
    public var to: UUID?
    /// For a plugin's parameter: the insert's id on the strip, and the parameter's identifier in that plugin.
    public var insert: UUID?
    public var parameter: String?
    public var shape: Shape
    /// False: kept, but not heard.
    public var enabled: Bool
    /// Sorted by frame, at most one at a frame.
    public var points: [AutomationPoint]

    public init(strip: UUID, param: Param = .gain, to: UUID? = nil, insert: UUID? = nil, parameter: String? = nil, shape: Shape = .linear, enabled: Bool = true, points: [AutomationPoint]) {
        self.strip = strip
        self.param = param
        self.to = to
        self.insert = insert
        self.parameter = parameter
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
    /// How long an automated mute takes to close or open, in seconds: long enough that it never clicks,
    /// short enough to be a mute. It begins at the point. (The mute button has no ramp: it changes the
    /// whole plan between two blocks. A point in the middle of a sound needs one.)
    public static let muteRamp = 0.005
    /// The values a lane of each kind may have.
    public static func range(of param: AutomationLane.Param) -> ClosedRange<Double> {
        switch param {
        case .gain, .send: gainRange
        case .pan: Mixer.panRange
        case .mute: 0...1
        // (A plugin's parameter has its own range, which only the plugin knows; the step that writes the lane asks it.)
        case .plugin: -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude
        // Past ±180 so that a place can move on round behind (170° to 190° goes behind, not back across the front).
        case .azimuth: -360...360
        case .elevation: SurroundPosition.elevationRange
        }
    }
    static func unit(of param: AutomationLane.Param) -> Said {
        switch param {
        case .gain, .send: Said("automation.unit.gain", "a gain is %1$@ to %2$@ dB", "\(Int(gainRange.lowerBound))", "\(Int(gainRange.upperBound))")
        case .pan: Said("automation.unit.pan", "a pan is −1 (left) to 1 (right)")
        case .mute: Said("automation.unit.mute", "a mute is 1 (muted) or 0 (heard)")
        case .plugin: Said("automation.unit.plugin", "a plugin's parameter has its own range")
        case .azimuth: Said("automation.unit.azimuth", "an azimuth is −360 to 360 degrees, positive to the left (past ±180 it goes on round behind)")
        case .elevation: Said("automation.unit.elevation", "an elevation is 0 to 90 degrees up")
        }
    }
    /// The longest timeline a point may be on: 24 hours at 192 kHz.
    public static let maxFrame: Frame = 24 * 3600 * 192_000

    public enum Failure: Error, LocalizedError, Equatable {
        case noStrip(String), notBuilt(String), badValue(Said), tooMany, mono, noPan, noSend(String), groupHasNoPan, noInsert
        /// A place (azimuth, elevation) automated on something that has none: in mono or stereo, or on anything but a track.
        case noPlace(String)
        /// Pan automation in a document wider than stereo. The value is the layout.
        case wide(String)

        public var reason: String {
            switch self {
            case .noStrip: "not_found"
            case .notBuilt: "not_available"
            case .badValue: "bad_request"
            case .tooMany: "too_many"
            case .mono, .wide: "needs_stereo"
            case .noPlace: "needs_surround"
            case .noPan, .groupHasNoPan: "bad_request"
            case .noSend, .noInsert: "not_found"
            }
        }
        public var errorDescription: String? {
            switch self {
            case .noStrip(let id): "there is no track, bus or VCA group with id \(id) (the master is \"master\")."
            case .notBuilt(let what): "automation of \(what) isn't built yet; gain, pan and mute are."
            case .mono: "a mono document has no pan to automate."
            case .wide(let layout): "a \(layout) document has no stereo pan to automate; its surround panner isn't built yet."
            case .noPlace(let what): "\(what) has no place to automate: azimuth and elevation are a track's, in documents wider than stereo."
            case .noPan: "the master has a level to automate, not a pan, a mute or a send."
            case .groupHasNoPan: "a VCA group has a level and a mute to automate, not a pan or a send."
            case .noSend(let to): "that strip has no send to \(to); make the send first (set_send)."
            case .noInsert: "that strip has no plugin with that id; a parameter lane names a plugin on the strip (`insert`) and one of its parameters (`parameter`)."
            case .badValue(let m): m.text
            case .tooMany: "a lane can have \(Automation.maxPoints) points at most."
            }
        }
        /// The same message by its key in the app's string catalogue (see `KeyedMessage`).
        public var keyed: KeyedMessage? {
            switch self {
            case .noStrip(let id): KeyedMessage("error.automation.noStrip", ["\(id)"])
            case .notBuilt(let what): KeyedMessage("error.automation.notBuilt", ["\(what)"])
            case .mono: KeyedMessage("error.automation.mono")
            case .wide(let layout): KeyedMessage("error.automation.wide", ["\(layout)"])
            case .noPlace(let what): KeyedMessage("error.automation.noPlace", ["\(what)"])
            case .noPan: KeyedMessage("error.automation.noPan")
            case .groupHasNoPan: KeyedMessage("error.automation.groupHasNoPan")
            case .noSend(let to): KeyedMessage("error.automation.noSend", ["\(to)"])
            case .noInsert: KeyedMessage("error.automation.noInsert")
            case .badValue(let m): m.keyed
            case .tooMany: KeyedMessage("error.automation.tooMany", ["\(Automation.maxPoints)"])
            }
        }
    }
}

extension Project {
    /// Whether anything in the project is automated. Such a project is saved as format 3.
    public var usesAutomation: Bool { !liveLanes.isEmpty }

    /// The lanes of strips (and sends) that exist, with points. (A lane whose strip or send was removed is not saved.)
    public var liveLanes: [AutomationLane] {
        automation.filter { l in
            guard !l.points.isEmpty, canAutomate(l.strip) else { return false }
            if l.param == .plugin { return l.insert.map { hasInsert($0, on: l.strip) } == true && l.parameter?.isEmpty == false }
            return l.param != .send || l.to.map { hasSend(from: l.strip, to: $0) } == true
        }
    }
    func canAutomate(_ strip: UUID) -> Bool { strip == Master.id || tracks.contains { $0.id == strip } || bus(strip) != nil || vca(strip) != nil }
    public func hasSend(from strip: UUID, to: UUID) -> Bool {
        (tracks.first { $0.id == strip }?.sends ?? bus(strip)?.sends ?? []).contains { $0.to == to }
    }
    /// The plugins on a strip: a track's, a bus's or the master's.
    public func inserts(of strip: UUID) -> [Insert] {
        strip == Master.id ? master.inserts : tracks.first { $0.id == strip }?.inserts ?? bus(strip)?.inserts ?? []
    }
    func hasInsert(_ insert: UUID, on strip: UUID) -> Bool { inserts(of: strip).contains { $0.id == insert } }
    /// The enabled lanes on a strip's plugins' parameters.
    public func pluginLanes(of strip: UUID) -> [AutomationLane] { liveLanes.filter { $0.strip == strip && $0.param == .plugin && $0.enabled } }
    /// The VCA group a track or bus belongs to, if any.
    func group(of strip: UUID) -> UUID? { tracks.first { $0.id == strip }?.vca ?? bus(strip)?.vca }

    public func lanes(of strip: UUID) -> [AutomationLane] { liveLanes.filter { $0.strip == strip } }

    public func lane(strip: UUID, param: AutomationLane.Param, to: UUID? = nil, insert: UUID? = nil, parameter: String? = nil) -> AutomationLane? {
        liveLanes.first { $0.strip == strip && $0.param == param && $0.to == to && $0.insert == insert && $0.parameter == parameter }
    }

    /// What the engine is given for a strip's level: the enabled gain lane's points, or nil. A strip in a
    /// VCA group gets the group's lane added to its own: two straight lines in dB add to a straight line
    /// between the points of both, so the sum is exact, and is what setting those values by hand on the
    /// member would give.
    func gainCurve(of strip: UUID) -> (frames: [Int64], db: [Float])? {
        let own = lane(strip: strip, param: .gain).flatMap { $0.enabled ? $0 : nil }
        let groups = group(of: strip).flatMap { lane(strip: $0, param: .gain) }.flatMap { $0.enabled ? $0 : nil }
        guard own != nil || groups != nil else { return nil }
        guard let a = own, let b = groups else {
            let l = (own ?? groups)!
            return (l.points.map(\.frame), l.points.map { Float($0.value) })
        }
        let frames = Array(Set(a.points.map(\.frame) + b.points.map(\.frame))).sorted()
        return (frames, frames.map { Float((a.value(at: $0) ?? 0) + (b.value(at: $0) ?? 0)) })
    }
    /// A send's enabled level lane.
    func sendCurve(from strip: UUID, to: UUID) -> (frames: [Int64], db: [Float])? {
        guard let l = lane(strip: strip, param: .send, to: to), l.enabled else { return nil }
        return (l.points.map(\.frame), l.points.map { Float($0.value) })
    }
    /// Whether a strip is muted by automation at a frame: by its own mute lane or its VCA group's.
    func mutedByLane(_ strip: UUID, at frame: Frame) -> Bool {
        (automated(.mute, of: strip, at: frame) ?? 0) >= 0.5 || (group(of: strip).flatMap { automated(.mute, of: $0, at: frame) } ?? 0) >= 0.5
    }
    /// The enabled pan lane's points, in a stereo document.
    func panCurve(of strip: UUID) -> (frames: [Int64], values: [Float])? {
        guard channels == 2, let l = lane(strip: strip, param: .pan), l.enabled else { return nil }
        return (l.points.map(\.frame), l.points.map { Float($0.value) })
    }
    /// The enabled mute lane as the amplitude the engine follows: 1 while heard, 0 while muted, and at
    /// every change a straight ramp of `Automation.muteRamp` beginning at the point, so that a mute in
    /// the middle of a sound doesn't click. A change that comes before the ramp of the one before has
    /// ended starts from where that ramp had got to.
    func muteCurve(of strip: UUID) -> (frames: [Int64], values: [Float])? {
        // The strip's own mute lane and its VCA group's, as one: muted when either says so.
        let lanes = ([strip] + [group(of: strip)].compactMap { $0 }).compactMap { lane(strip: $0, param: .mute) }.filter(\.enabled)
        guard !lanes.isEmpty else { return nil }
        let at = Array(Set(lanes.flatMap { $0.points.map(\.frame) })).sorted()
        let merged = AutomationLane(strip: strip, param: .mute, shape: .hold, points: at.map { f in
            AutomationPoint(frame: f, value: lanes.contains { ($0.value(at: f) ?? 0) >= 0.5 } ? 1 : 0)
        })
        let l = merged
        guard let first = l.points.first else { return nil }
        let ramp = max(1, Frame((Automation.muteRamp * sampleRate).rounded()))
        var frames: [Int64] = [], values: [Float] = []
        var level: Double = first.value >= 0.5 ? 0 : 1   // before the first point: the first point's state
        func add(_ f: Frame, _ v: Double) {
            if let last = frames.last, f <= last { values[values.count - 1] = Float(v); return }
            frames.append(f); values.append(Float(v))
        }
        add(first.frame, level)
        for (i, p) in l.points.enumerated().dropFirst() {
            let target: Double = p.value >= 0.5 ? 0 : 1
            guard target != (l.points[i - 1].value >= 0.5 ? 0 : 1) else { continue }
            // Where the ramp before this one had got to when this point comes.
            if let lastFrame = frames.last, p.frame < lastFrame, frames.count >= 2 {
                let a = frames[frames.count - 2], va = Double(values[values.count - 2]), vb = Double(values[values.count - 1])
                level = va + (vb - va) * Double(p.frame - a) / Double(lastFrame - a)
                frames.removeLast(); values.removeLast()
            }
            add(p.frame, level)
            add(p.frame + ramp, target)
            level = target
        }
        return (frames, values)
    }

    /// Writes a lane. `points` replace the whole lane, or with `range` only the points inside it (its ends
    /// included); points outside the range are never touched. A lane left without points is gone.
    /// Refused, with the name of what was wrong: a strip that isn't there, a point before 0 or after the
    /// document's end, a value outside the fader's range, two points at one frame, too many points.
    /// For a plugin's parameter (`param` plugin): `insert` and `parameter` say which, and `values` is the
    /// range the plugin itself gives for it (asked of the plugin by whoever writes the lane; without it the
    /// values are taken as they are, and the plugin holds them to its range when they are set).
    public mutating func setAutomation(strip: UUID, param: AutomationLane.Param = .gain, to: UUID? = nil, insert: UUID? = nil, parameter: String? = nil,
                                       values: ClosedRange<Double>? = nil, points new: [AutomationPoint],
                                       range: ClosedRange<Frame>? = nil, shape: AutomationLane.Shape? = nil, enabled: Bool? = nil) throws {
        guard canAutomate(strip) else { throw Automation.Failure.noStrip(strip.uuidString) }
        if param == .plugin {
            guard vca(strip) == nil, let insert, hasInsert(insert, on: strip), parameter?.isEmpty == false else { throw Automation.Failure.noInsert }
        } else if insert != nil || parameter != nil {
            throw Automation.Failure.badValue(Said("error.value.insert_parameter_name_plugin", "`insert` and `parameter` name a plugin's parameter and go with param plugin only."))
        }
        if strip == Master.id, param != .gain, param != .plugin { throw Automation.Failure.noPan }
        if vca(strip) != nil, param == .pan || param == .send { throw Automation.Failure.groupHasNoPan }
        if param == .send {
            guard let to, hasSend(from: strip, to: to) else { throw Automation.Failure.noSend(to.flatMap { bus($0)?.name } ?? "that bus") }
        } else if to != nil {
            throw Automation.Failure.badValue(Said("error.value.names_send_s_bus", "`to` names a send's bus and goes with a send lane only."))
        }
        if param == .pan, channels != 2 { throw channels == 1 ? Automation.Failure.mono : Automation.Failure.wide(layout.rawValue) }
        if param == .azimuth || param == .elevation {
            guard channels > 2 else { throw Automation.Failure.noPlace("a \(layout.rawValue) document") }
            // A track's place; a bus's turn (azimuth only, in a loudspeaker layout).
            let onBus = param == .azimuth && bus(strip) != nil && !layout.isAmbisonic
            guard tracks.contains(where: { $0.id == strip }) || onBus else {
                throw Automation.Failure.noPlace(strip == Master.id ? "the master" : bus(strip) != nil ? "a bus (its turn is an azimuth, in a loudspeaker layout)" : "that strip")
            }
        }
        // A mute holds its value until the next point; a level and a pan go in a straight line.
        if let shape, shape != (param == .mute ? .hold : .linear) {
            throw Automation.Failure.badValue(param == .mute ? Said("error.value.muteHold", "a mute lane holds each value until the next point (shape hold).")
                                              : Said("error.value.linear", "a %@ lane goes in a straight line between points (shape linear).", param.rawValue))
        }
        let allowed = values ?? Automation.range(of: param)
        let end = length
        for (i, p) in new.enumerated() {
            guard p.frame >= 0, p.frame <= end else {
                throw Automation.Failure.badValue(Said("error.value.points_1_2_s", "points[%1$@] is at %2$@ s, outside the document (0 to %3$@ s).", "\(i)", "\(seconds(p.frame))", "\(seconds(end))"))
            }
            guard p.value.isFinite, allowed.contains(p.value), param != .mute || p.value == 0 || p.value == 1 else {
                throw Automation.Failure.badValue(Said("error.value.pointValue", "points[%1$@] has the value %2$@; %3$@.", "\(i)", "\(p.value)", inner: values.map { Said("automation.unit.parameter", "the parameter takes %1$@ to %2$@", $0.lowerBound.formatted(), $0.upperBound.formatted()) } ?? Automation.unit(of: param)))
            }
            if let r = range, !r.contains(p.frame) {
                throw Automation.Failure.badValue(Said("error.value.points_1_2_s2", "points[%1$@] is at %2$@ s, outside the range given (%3$@ to %4$@ s).", "\(i)", "\(seconds(p.frame))", "\(seconds(r.lowerBound))", "\(seconds(r.upperBound))"))
            }
        }
        let sorted = new.sorted { $0.frame < $1.frame }
        for (a, b) in zip(sorted, sorted.dropFirst()) where a.frame == b.frame {
            throw Automation.Failure.badValue(Said("error.value.two_points_s_lane", "two points are at %@ s; a lane has one value at a time.", "\(seconds(a.frame))"))
        }
        var lane = lane(strip: strip, param: param, to: to, insert: insert, parameter: parameter)
            ?? AutomationLane(strip: strip, param: param, to: to, insert: insert, parameter: parameter, shape: param == .mute ? .hold : .linear, points: [])
        if let range { lane.points = (lane.points.filter { !range.contains($0.frame) } + sorted).sorted { $0.frame < $1.frame } }
        else { lane.points = sorted }
        if let shape { lane.shape = shape }
        if let enabled { lane.enabled = enabled }
        guard lane.points.count <= Automation.maxPoints else { throw Automation.Failure.tooMany }
        automation.removeAll { $0.strip == strip && $0.param == param && $0.to == to && $0.insert == insert && $0.parameter == parameter }
        if !lane.points.isEmpty { automation.append(lane) }
    }

    /// Takes a lane's points away: all of them, or those inside `range`. Answers how many went.
    @discardableResult
    public mutating func clearAutomation(strip: UUID, param: AutomationLane.Param, to: UUID? = nil, insert: UUID? = nil, parameter: String? = nil,
                                         range: ClosedRange<Frame>? = nil) throws -> Int {
        guard canAutomate(strip) else { throw Automation.Failure.noStrip(strip.uuidString) }
        guard let i = automation.firstIndex(where: { $0.strip == strip && $0.param == param && $0.to == to && $0.insert == insert && $0.parameter == parameter }) else { return 0 }
        let before = automation[i].points.count
        if let range { automation[i].points.removeAll { range.contains($0.frame) } } else { automation[i].points = [] }
        let gone = before - automation[i].points.count
        if automation[i].points.isEmpty { automation.remove(at: i) }
        return gone
    }

    /// A strip's whole level at a frame, in dB: its fader, its VCA group and its gain lane together.
    /// nil for a strip that isn't there.
    /// A lane's value at a frame when the lane is there and switched on.
    public func automated(_ param: AutomationLane.Param, of strip: UUID, at frame: Frame) -> Double? {
        lane(strip: strip, param: param).flatMap { $0.enabled ? $0.value(at: frame) : nil }
    }

    public func level(of strip: UUID, at frame: Frame) -> (faderDB: Double, automationDB: Double?, totalDB: Double, muted: Bool)? {
        let fader: (gainDB: Double, muted: Bool)
        if let t = tracks.first(where: { $0.id == strip }) { fader = heard(gainDB: t.gainDB, muted: t.isMuted, vca: t.vca) }
        else if let b = bus(strip) { fader = heard(gainDB: b.gainDB, muted: b.isMuted, vca: b.vca) }
        else if strip == Master.id { fader = (master.gainDB, false) }
        else if let v = vca(strip) { fader = (v.gainDB, v.isMuted) }
        else { return nil }
        // The strip's own lane, and its VCA group's added to it.
        let own = automated(.gain, of: strip, at: frame), groups = group(of: strip).flatMap { automated(.gain, of: $0, at: frame) }
        let lane: Double? = own == nil && groups == nil ? nil : (own ?? 0) + (groups ?? 0)
        // Muted by the button, by the group, or by a mute lane (the strip's or the group's) at that time.
        let muted = fader.muted || mutedByLane(strip, at: frame)
        return (fader.gainDB, lane, fader.gainDB + (lane ?? 0), muted)
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

extension Automation.Failure: KeyedFailure {}
