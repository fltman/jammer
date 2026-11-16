import Foundation

/// A bus: tracks (and other buses) routed to it are summed, given the bus's gain and pan, and passed on
/// to another bus or to the output. A project without buses, with every track unpanned and going to the
/// output, is played by exactly the code that played it before there was a mixer.
public struct Bus: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var gainDB: Double
    /// −1 (left) … 0 (centre) … 1 (right).
    public var pan: Double
    public var isMuted: Bool
    /// The bus this one feeds; nil: the output.
    public var output: UUID?

    public init(id: UUID = UUID(), name: String, gainDB: Double = 0, pan: Double = 0, isMuted: Bool = false, output: UUID? = nil) {
        self.id = id
        self.name = name
        self.gainDB = gainDB
        self.pan = pan
        self.isMuted = isMuted
        self.output = output
    }
}

public enum Mixer {
    public static let maxBuses = 64
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
        case noBus(String), loop(String), tooMany, inUse(String, Int), mono, badValue(String)

        public var reason: String {
            switch self {
            case .noBus: "not_found"
            case .loop: "routing_loop"
            case .tooMany: "too_many"
            case .inUse: "in_use"
            case .mono: "needs_stereo"
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
            case .badValue(let m): m
            }
        }
    }
}

extension Project {
    /// True when the project uses anything of the mixer. Such a project is saved as format 2, which a
    /// Jämmer from before the mixer refuses to open instead of playing every track straight out.
    public var usesMixer: Bool { !buses.isEmpty || tracks.contains { $0.pan != 0 || $0.output != nil } }

    public func bus(_ id: UUID) -> Bus? { buses.first { $0.id == id } }

    /// Takes the mixer out of a copy that is made to render one track by itself (for a bounce, an
    /// analysis, a waveform): what is wanted there is the track's own sound, before its pan and its bus.
    /// The pan and the bus still apply afterwards, to whatever the track then plays.
    public mutating func withoutMixer() {
        buses = []
        for t in tracks.indices { tracks[t].pan = 0; tracks[t].output = nil }
    }

    /// Whether routing `bus` to `output` would make a loop (`output` reaches `bus` again).
    func loops(bus: UUID, into output: UUID?) -> Bool {
        var at = output
        var steps = 0
        while let id = at, steps <= buses.count {
            if id == bus { return true }
            at = self.bus(id)?.output
            steps += 1
        }
        return steps > buses.count
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
