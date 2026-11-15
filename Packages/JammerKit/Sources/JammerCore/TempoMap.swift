import Foundation

/// A time signature: `beats` of 1/`unit` notes per bar.
public struct Meter: Codable, Hashable, Sendable, CustomStringConvertible {
    public var beats: Int
    public var unit: Int

    public init(_ beats: Int, _ unit: Int) {
        self.beats = beats
        self.unit = unit
    }

    public static let common = Meter(4, 4)

    public var isValid: Bool { (1...64).contains(beats) && [1, 2, 4, 8, 16, 32].contains(unit) }
    /// The length of one beat, in quarter notes.
    public var beatLength: Double { 4 / Double(unit) }
    /// The length of one bar, in quarter notes.
    public var barLength: Double { Double(beats) * beatLength }
    public var description: String { "\(beats)/\(unit)" }
}

/// From `position` on, the tempo is `bpm` quarter notes a minute in `meter`.
public struct TempoChange: Codable, Hashable, Sendable {
    public var position: Frame
    public var bpm: Double
    public var meter: Meter

    public init(position: Frame, bpm: Double, meter: Meter = .common) {
        self.position = position
        self.bpm = bpm
        self.meter = meter
    }
}

/// Bar, beat and tick, all as shown: bar and beat count from 1, ticks from 0.
public struct MusicalPosition: Hashable, Sendable, Comparable, CustomStringConvertible {
    public var bar: Int
    public var beat: Int
    public var tick: Int

    public init(bar: Int, beat: Int = 1, tick: Int = 0) {
        self.bar = bar
        self.beat = beat
        self.tick = tick
    }

    public static func < (a: Self, b: Self) -> Bool { (a.bar, a.beat, a.tick) < (b.bar, b.beat, b.tick) }
    public var description: String { "\(bar).\(beat).\(String(format: "%03d", tick))" }
}

public enum TempoError: Error, LocalizedError, Equatable {
    case badTempo
    case badMeter
    case noSuchChange
    case badPosition

    public var errorDescription: String? {
        switch self {
        case .badTempo: "Tempo must be between \(Int(TempoMap.bpmRange.lowerBound)) and \(Int(TempoMap.bpmRange.upperBound)) BPM."
        case .badMeter: "The time signature must be 1–64 beats of 1, 2, 4, 8, 16 or 32."
        case .noSuchChange: "There's no tempo change there. The first one can't be removed."
        case .badPosition: "That bar or beat doesn't exist in the time signature."
        }
    }
}

/// Tempo and time signature over the timeline. The audio stays in frames; the map
/// only translates frames to quarter notes and to bar.beat.tick and back.
///
/// Tempo is constant from one change to the next (no ramps yet). Changes are anchored
/// to frames, so they move with the audio in ripple edits, like markers.
/// A change of time signature starts a new bar; an unfinished bar before it still counts.
public struct TempoMap: Codable, Hashable, Sendable {
    public static let ticksPerBeat = 960
    public static let bpmRange = 10.0...999.0

    /// Sorted by position; the first is always at frame 0; none repeats the one before it.
    public private(set) var changes: [TempoChange]

    public init(bpm: Double = 120, meter: Meter = .common) {
        changes = [TempoChange(position: 0, bpm: bpm, meter: meter)]
    }

    public init(changes: [TempoChange]) throws {
        self.init(bpm: changes.first?.bpm ?? 120, meter: changes.first?.meter ?? .common)
        for c in changes { try set(bpm: c.bpm, meter: c.meter, at: c.position) }
    }

    public init(from decoder: Decoder) throws {
        struct Stored: Decodable { var changes: [TempoChange] }
        let stored = try Stored(from: decoder)
        do { try self.init(changes: stored.changes) } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid tempo map: \(error)"))
        }
    }

    public var isConstant: Bool { changes.count == 1 }

    // MARK: Changing the map

    /// Sets the tempo (and the time signature, when given) from `position` on.
    /// Without a meter, the one in effect there is kept.
    public mutating func set(bpm: Double, meter: Meter? = nil, at position: Frame = 0) throws {
        guard bpm.isFinite, Self.bpmRange.contains(bpm) else { throw TempoError.badTempo }
        let meter = meter ?? change(at: max(0, position)).meter
        guard meter.isValid else { throw TempoError.badMeter }
        let p = max(0, position)
        let c = TempoChange(position: p, bpm: bpm, meter: meter)
        if let i = changes.firstIndex(where: { $0.position == p }) {
            changes[i] = c
        } else {
            changes.append(c)
            changes.sort { $0.position < $1.position }
        }
        normalize()
    }

    /// Removes the change at `position`. The first change can only be replaced.
    public mutating func removeChange(at position: Frame) throws {
        guard position > 0, let i = changes.firstIndex(where: { $0.position == position }) else {
            throw TempoError.noSuchChange
        }
        changes.remove(at: i)
        normalize()
    }

    /// Ripple delete: changes inside `range` go, later ones move left, and the tempo
    /// that was in effect at the end of the range takes over at its start.
    public mutating func delete(_ range: Range<Frame>) {
        guard !range.isEmpty else { return }
        let atEnd = change(at: range.upperBound)
        let n = Frame(range.count)
        changes = changes.compactMap { c in
            if c.position >= range.upperBound { var c = c; c.position -= n; return c }
            if c.position >= range.lowerBound, c.position > 0 { return nil }
            return c
        }
        if atEnd.position >= range.lowerBound {
            var c = atEnd
            c.position = range.lowerBound
            if let i = changes.firstIndex(where: { $0.position == c.position }) { changes[i] = c } else { changes.append(c) }
            changes.sort { $0.position < $1.position }
        }
        normalize()
    }

    /// Opens a gap at `t`: changes at or after it move right with the audio.
    public mutating func insertGap(at t: Frame, length: Frame) {
        guard length > 0 else { return }
        for i in changes.indices where changes[i].position >= t && changes[i].position > 0 {
            changes[i].position += length
        }
    }

    private mutating func normalize() {
        var out: [TempoChange] = []
        for c in changes {
            if let last = out.last, last.bpm == c.bpm, last.meter == c.meter { continue }
            out.append(c)
        }
        changes = out
    }

    // MARK: Reading the map

    /// The change in effect at `frame`.
    public func change(at frame: Frame) -> TempoChange { changes[segmentIndex(at: frame)] }
    public func bpm(at frame: Frame) -> Double { change(at: frame).bpm }
    public func meter(at frame: Frame) -> Meter { change(at: frame).meter }

    /// Quarter notes from the start of the timeline to `frame`.
    public func quarterNotes(at frame: Frame, sampleRate: Double) -> Double {
        let s = segments(sampleRate)[segmentIndex(at: frame)]
        return s.startQ + Double(frame - s.change.position) * s.change.bpm / (60 * sampleRate)
    }

    /// The first frame at or after `quarterNotes`.
    public func frame(atQuarterNotes q: Double, sampleRate: Double) -> Frame {
        let segs = segments(sampleRate)
        let s = segs.last(where: { $0.startQ <= q + Self.epsilon }) ?? segs[0]
        let exact = Double(s.change.position) + (q - s.startQ) * 60 * sampleRate / s.change.bpm
        return max(0, Frame((exact - Self.frameTolerance).rounded(.up)))
    }

    /// Bar, beat and tick at `frame`, rounded down to the tick.
    public func position(at frame: Frame, sampleRate: Double) -> MusicalPosition {
        let segs = segments(sampleRate)
        let s = segs[segmentIndex(at: frame)]
        let q = s.startQ + Double(frame - s.change.position) * s.change.bpm / (60 * sampleRate)
        let m = s.change.meter
        let inSegment = q - s.barOriginQ
        let bar = Int((inSegment / m.barLength + Self.epsilon).rounded(.down))
        let inBar = max(0, inSegment - Double(bar) * m.barLength)
        let beat = min(m.beats - 1, Int((inBar / m.beatLength + Self.epsilon).rounded(.down)))
        let inBeat = max(0, inBar - Double(beat) * m.beatLength)
        let tick = min(Self.ticksPerBeat - 1, Int((inBeat / m.beatLength * Double(Self.ticksPerBeat) + Self.epsilon).rounded(.down)))
        return MusicalPosition(bar: s.firstBar + bar + 1, beat: beat + 1, tick: tick)
    }

    /// The first frame at or after a bar, beat and tick.
    public func frame(at p: MusicalPosition, sampleRate: Double) throws -> Frame {
        guard p.bar >= 1, p.beat >= 1, (0..<Self.ticksPerBeat).contains(p.tick) else { throw TempoError.badPosition }
        let segs = segments(sampleRate)
        let bar0 = p.bar - 1
        guard let i = segs.lastIndex(where: { $0.firstBar <= bar0 }) else { throw TempoError.badPosition }
        let s = segs[i]
        let m = s.change.meter
        guard p.beat <= m.beats else { throw TempoError.badPosition }
        let q = s.barOriginQ + Double(bar0 - s.firstBar) * m.barLength
            + (Double(p.beat - 1) + Double(p.tick) / Double(Self.ticksPerBeat)) * m.beatLength
        // The beat must come before the next time signature: an unfinished bar has no tail.
        if let next = segs[(i + 1)...].first(where: { $0.change.meter != m }), q + Self.epsilon >= next.startQ {
            throw TempoError.badPosition
        }
        return frame(atQuarterNotes: q, sampleRate: sampleRate)
    }

    /// Frames where bars start inside `range`, for rulers and grids.
    public func barStarts(in range: Range<Frame>, sampleRate: Double, limit: Int = 10_000) -> [(bar: Int, frame: Frame)] {
        var out: [(Int, Frame)] = []
        let first = position(at: range.lowerBound, sampleRate: sampleRate).bar
        for bar in first..<(first + limit) {
            guard let f = try? frame(at: MusicalPosition(bar: bar), sampleRate: sampleRate) else { continue }
            if f >= range.upperBound { break }
            if f >= range.lowerBound { out.append((bar, f)) }
        }
        return out
    }

    // MARK: Internals

    static let epsilon = 1e-9
    /// Frames from quarter notes carry a few ulps of error over hours; this absorbs it.
    static let frameTolerance = 1e-6

    private struct Segment {
        var change: TempoChange
        /// Quarter notes at the change.
        var startQ: Double
        /// Index (from 0) of the bar that starts at `barOriginQ`.
        var firstBar: Int
        /// Where bar `firstBar` starts, in quarter notes; at or before `startQ`.
        var barOriginQ: Double
    }

    private func segmentIndex(at frame: Frame) -> Int {
        var lo = 0, hi = changes.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if changes[mid].position <= frame { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private func segments(_ sampleRate: Double) -> [Segment] {
        var out: [Segment] = []
        out.reserveCapacity(changes.count)
        for c in changes {
            guard let prev = out.last else {
                out.append(Segment(change: c, startQ: 0, firstBar: 0, barOriginQ: 0))
                continue
            }
            let q = prev.startQ + Double(c.position - prev.change.position) * prev.change.bpm / (60 * sampleRate)
            if c.meter == prev.change.meter {
                out.append(Segment(change: c, startQ: q, firstBar: prev.firstBar, barOriginQ: prev.barOriginQ))
            } else {
                // A new time signature starts a new bar; an unfinished one before it still counts.
                let bars = (q - prev.barOriginQ) / prev.change.meter.barLength
                let whole = (bars + Self.epsilon).rounded(.down)
                let onLine = abs(bars - whole) < 1e-6
                let first = prev.firstBar + Int(whole) + (onLine ? 0 : 1)
                out.append(Segment(change: c, startQ: q, firstBar: first, barOriginQ: q))
            }
        }
        return out
    }
}
