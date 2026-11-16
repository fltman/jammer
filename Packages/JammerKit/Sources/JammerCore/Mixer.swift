import Foundation

/// A bus: tracks (and other buses) routed to it are summed, given the bus's gain and pan, and passed on
/// to another bus or to the output. A project without buses, with every track unpanned and going to the
/// output, is played by exactly the code that played it before there was a mixer.
/// A copy of a strip's signal sent to a bus (a reverb, a headphone mix, a parallel compressor).
public struct Send: Codable, Hashable, Sendable {
    /// The bus it goes to.
    public var to: UUID
    public var gainDB: Double
    /// Before the strip's fader and pan (it then doesn't follow the fader); default after them.
    public var pre: Bool

    public init(to: UUID, gainDB: Double = 0, pre: Bool = false) {
        self.to = to
        self.gainDB = gainDB
        self.pre = pre
    }
}

public struct Bus: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var gainDB: Double
    /// −1 (left) … 0 (centre) … 1 (right).
    public var pan: Double
    public var isMuted: Bool
    /// The bus this one feeds; nil: the output.
    public var output: UUID?
    public var sends: [Send] = []
    /// Plugins on the bus, in order, after its sum and before its fader. What they add in latency is
    /// made up for across the mixer (every other path is delayed to match), so the mix stays in time.
    public var inserts: [Insert] = []

    public init(id: UUID = UUID(), name: String, gainDB: Double = 0, pan: Double = 0, isMuted: Bool = false, output: UUID? = nil, sends: [Send] = []) {
        self.id = id
        self.name = name
        self.gainDB = gainDB
        self.pan = pan
        self.isMuted = isMuted
        self.output = output
        self.sends = sends
    }

    private enum CodingKeys: String, CodingKey { case id, name, gainDB, pan, isMuted, output, sends, inserts }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(gainDB, forKey: .gainDB)
        try c.encode(pan, forKey: .pan)
        try c.encode(isMuted, forKey: .isMuted)
        try c.encodeIfPresent(output, forKey: .output)
        if !sends.isEmpty { try c.encode(sends, forKey: .sends) }
        if !inserts.isEmpty { try c.encode(inserts, forKey: .inserts) }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0
        pan = try c.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        output = try c.decodeIfPresent(UUID.self, forKey: .output)
        sends = try c.decodeIfPresent([Send].self, forKey: .sends) ?? []
        inserts = try c.decodeIfPresent([Insert].self, forKey: .inserts) ?? []
    }
}

public enum Mixer {
    public static let maxBuses = 64
    public static let maxSends = 16
    public static let gainRange = -96.0...24.0
    public static let panRange = -1.0...1.0

    /// The gains of the left and the right channel for a pan. The centre is exactly 1 and 1, so an
    /// unpanned strip is untouched; towards one side that side stays at 1 and the other falls away along
    /// a sine, to nothing at the end. Nothing is ever raised, so panning can't clip.
    public static func panGains(_ pan: Double) -> (left: Float, right: Float) {
        guard pan != 0, pan.isFinite else { return (1, 1) }
        let p = max(-1, min(1, pan))
        // All the way to one side is exactly nothing on the other (cos(π/2) in floating point is not quite 0).
        let fall = abs(p) == 1 ? 0 : Float(cos(abs(p) * .pi / 2))
        return p < 0 ? (1, fall) : (fall, 1)
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case noBus(String), loop(String), tooMany, inUse(String, Int), mono, badValue(String), noStrip(String), noSend(String, String), tooManySends(String)

        public var reason: String {
            switch self {
            case .noBus: "not_found"
            case .loop: "routing_loop"
            case .tooMany: "too_many"
            case .inUse: "in_use"
            case .mono: "needs_stereo"
            case .noStrip, .noSend: "not_found"
            case .tooManySends: "too_many"
            case .badValue: "bad_request"
            }
        }
        public var errorDescription: String? {
            switch self {
            case .noBus(let id): "there is no bus with id \(id)."
            case .loop(let name): "that would send \(name) back into itself through the buses it feeds."
            case .tooMany: "a document can have \(Mixer.maxBuses) buses at most."
            case .inUse(let name, let n): "\(n) strip\(n == 1 ? " is" : "s are") routed to \(name). Say where they should go instead with reroute (a bus id, or \"master\"), or route them elsewhere first."
            case .mono: "pan needs a stereo document; this one is mono."
            case .noStrip(let id): "there is no track or bus with id \(id)."
            case .noSend(let from, let to): "\(from) has no send to \(to)."
            case .tooManySends(let name): "\(name) already has \(Mixer.maxSends) sends, which is the most a strip can have."
            case .badValue(let m): m
            }
        }
    }
}

extension Project {
    /// True when the project uses anything of the mixer. Such a project is saved as format 2, which a
    /// Jämmer from before the mixer refuses to open instead of playing every track straight out.
    public var usesMixer: Bool { !buses.isEmpty || tracks.contains { $0.pan != 0 || $0.output != nil || !$0.sends.isEmpty } }

    public func bus(_ id: UUID) -> Bus? { buses.first { $0.id == id } }

    /// A track or a bus by its id, as the thing plugins sit on: its name and its plugins.
    public func strip(_ id: UUID) -> (name: String, inserts: [Insert], isBus: Bool)? {
        if let t = tracks.first(where: { $0.id == id }) { return (t.name, t.inserts, false) }
        if let b = bus(id) { return (b.name, b.inserts, true) }
        return nil
    }
    /// Replaces the plugins of the track or bus with that id.
    public mutating func setInserts(_ inserts: [Insert], on id: UUID) {
        if let t = tracks.firstIndex(where: { $0.id == id }) { tracks[t].inserts = inserts }
        else if let b = buses.firstIndex(where: { $0.id == id }) { buses[b].inserts = inserts }
    }

    /// Every plugin in the project: on the tracks and on the buses.
    public var allInserts: [Insert] { tracks.flatMap(\.inserts) + buses.flatMap(\.inserts) }

    /// Takes the mixer out of a copy that is made to render one track by itself (for a bounce, an
    /// analysis, a waveform): what is wanted there is the track's own sound, before its pan and its bus.
    /// The pan and the bus still apply afterwards, to whatever the track then plays.
    public mutating func withoutMixer() {
        buses = []
        for t in tracks.indices { tracks[t].pan = 0; tracks[t].output = nil; tracks[t].sends = [] }
    }

    /// Whether sending `bus` to `output`, by its output or by a send, would make a loop: whether
    /// `output` reaches `bus` again through the outputs and sends of the buses on the way.
    func loops(bus: UUID, into output: UUID?) -> Bool {
        guard let start = output else { return false }
        var seen = Set<UUID>(), queue = [start]
        while let id = queue.popLast() {
            if id == bus { return true }
            guard seen.insert(id).inserted, let b = self.bus(id) else { continue }
            if let o = b.output { queue.append(o) }
            queue.append(contentsOf: b.sends.map(\.to))
        }
        return false
    }

    /// Sets, changes or removes the send from a track or a bus to a bus. One send per pair.
    public mutating func setSend(from: UUID, to: UUID, gainDB: Double? = nil, pre: Bool? = nil, remove: Bool = false) throws {
        guard let target = bus(to) else { throw Mixer.Failure.noBus(to.uuidString) }
        if let g = gainDB, !Mixer.gainRange.contains(g) { throw Mixer.Failure.badValue("gainDB must be −96 to 24.") }
        func change(_ sends: inout [Send], name: String) throws {
            if remove {
                guard sends.contains(where: { $0.to == to }) else { throw Mixer.Failure.noSend(name, target.name) }
                sends.removeAll { $0.to == to }
            } else if let i = sends.firstIndex(where: { $0.to == to }) {
                if let gainDB { sends[i].gainDB = gainDB }
                if let pre { sends[i].pre = pre }
            } else {
                guard sends.count < Mixer.maxSends else { throw Mixer.Failure.tooManySends(name) }
                sends.append(Send(to: to, gainDB: gainDB ?? 0, pre: pre ?? false))
            }
        }
        if let t = tracks.firstIndex(where: { $0.id == from }) {
            try change(&tracks[t].sends, name: tracks[t].name)
        } else if let b = buses.firstIndex(where: { $0.id == from }) {
            guard remove || (from != to && !loops(bus: from, into: to)) else { throw Mixer.Failure.loop(buses[b].name) }
            try change(&buses[b].sends, name: buses[b].name)
        } else {
            throw Mixer.Failure.noStrip(from.uuidString)
        }
    }

    @discardableResult
    public mutating func addBus(name: String, output: UUID? = nil) throws -> Bus {
        guard buses.count < Mixer.maxBuses else { throw Mixer.Failure.tooMany }
        if let output, bus(output) == nil { throw Mixer.Failure.noBus(output.uuidString) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { throw Mixer.Failure.badValue("a bus needs a name of 1 to 200 characters.") }
        let b = Bus(name: trimmed, output: output)
        buses.append(b)
        return b
    }

    public mutating func setBus(_ id: UUID, name: String? = nil, gainDB: Double? = nil, pan: Double? = nil, muted: Bool? = nil, output: UUID?? = nil) throws {
        guard let i = buses.firstIndex(where: { $0.id == id }) else { throw Mixer.Failure.noBus(id.uuidString) }
        if let name {
            let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, t.count <= 200 else { throw Mixer.Failure.badValue("a bus needs a name of 1 to 200 characters.") }
            buses[i].name = t
        }
        if let gainDB {
            guard Mixer.gainRange.contains(gainDB) else { throw Mixer.Failure.badValue("gainDB must be −96 to 24.") }
            buses[i].gainDB = gainDB
        }
        if let pan {
            guard Mixer.panRange.contains(pan) else { throw Mixer.Failure.badValue("pan must be −1 (left) to 1 (right).") }
            guard pan == 0 || channels == 2 else { throw Mixer.Failure.mono }
            buses[i].pan = pan
        }
        if let muted { buses[i].isMuted = muted }
        if let output {
            if let to = output {
                guard bus(to) != nil else { throw Mixer.Failure.noBus(to.uuidString) }
                guard !loops(bus: id, into: to) else { throw Mixer.Failure.loop(buses[i].name) }
            }
            buses[i].output = output
        }
    }

    /// Takes a bus away. What was routed to it goes to `reroute` (nil inside: the output); without
    /// `reroute` a bus that anything is routed to is not removed.
    public mutating func removeBus(_ id: UUID, reroute: UUID?? = nil) throws {
        guard let b = bus(id) else { throw Mixer.Failure.noBus(id.uuidString) }
        let users = tracks.filter { $0.output == id }.count + buses.filter { $0.output == id }.count
        if users > 0 {
            guard let reroute else { throw Mixer.Failure.inUse(b.name, users) }
            if let to = reroute {
                guard to != id, bus(to) != nil else { throw Mixer.Failure.noBus(to.uuidString) }
                // A bus that fed the removed one may not end up feeding itself.
                for other in buses where other.output == id && (other.id == to || loops(bus: other.id, into: to)) { throw Mixer.Failure.loop(other.name) }
            }
            for t in tracks.indices where tracks[t].output == id { tracks[t].output = reroute }
            for o in buses.indices where buses[o].output == id { buses[o].output = reroute }
        }
        // Sends to a bus that is gone go with it.
        for t in tracks.indices { tracks[t].sends.removeAll { $0.to == id } }
        for o in buses.indices { buses[o].sends.removeAll { $0.to == id } }
        buses.removeAll { $0.id == id }
    }

    public mutating func setTrackRoute(_ track: UUID, pan: Double? = nil, output: UUID?? = nil) throws {
        guard let t = tracks.firstIndex(where: { $0.id == track }) else { throw EditError.noTrack }
        if let pan {
            guard Mixer.panRange.contains(pan) else { throw Mixer.Failure.badValue("pan must be −1 (left) to 1 (right).") }
            guard pan == 0 || channels == 2 else { throw Mixer.Failure.mono }
            tracks[t].pan = pan
        }
        if let output {
            if let to = output, bus(to) == nil { throw Mixer.Failure.noBus(to.uuidString) }
            tracks[t].output = output
        }
    }
}
