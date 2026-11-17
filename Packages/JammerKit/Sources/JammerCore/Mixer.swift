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
    /// The VCA group whose level and mute are added to the bus's own; nil: none.
    public var vca: UUID?
    /// Set while the bus is frozen: played from a file of what it summed, through its plugins.
    public var frozen: Frozen?
    /// In a loudspeaker layout wider than stereo: the bus's whole image turned round the listener, in degrees
    /// (positive to the left). A bus carries every channel already placed by its tracks, so it isn't placed
    /// from one direction as a track is: it is turned. nil: as its tracks placed it.
    public var azimuth: Double?

    public init(id: UUID = UUID(), name: String, gainDB: Double = 0, pan: Double = 0, isMuted: Bool = false, output: UUID? = nil, sends: [Send] = []) {
        self.id = id
        self.name = name
        self.gainDB = gainDB
        self.pan = pan
        self.isMuted = isMuted
        self.output = output
        self.sends = sends
    }

    private enum CodingKeys: String, CodingKey { case id, name, gainDB, pan, isMuted, output, sends, inserts, vca, frozen, azimuth }
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
        try c.encodeIfPresent(vca, forKey: .vca)
        try c.encodeIfPresent(frozen, forKey: .frozen)
        try c.encodeIfPresent(azimuth, forKey: .azimuth)
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        azimuth = (try? c.decodeIfPresent(Double.self, forKey: .azimuth)).flatMap { $0 }.flatMap { $0.isFinite && abs($0) <= 180 ? $0 : nil }
        vca = try c.decodeIfPresent(UUID.self, forKey: .vca)
        frozen = try c.decodeIfPresent(Frozen.self, forKey: .frozen)
        name = try c.decode(String.self, forKey: .name)
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0
        pan = try c.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        output = try c.decodeIfPresent(UUID.self, forKey: .output)
        sends = try c.decodeIfPresent([Send].self, forKey: .sends) ?? []
        inserts = try c.decodeIfPresent([Insert].self, forKey: .inserts) ?? []
    }
}

/// A VCA group: no audio goes through it. Its level is added to the fader of every strip that belongs
/// to it, and its mute mutes them, so a group of tracks moves together while each keeps its own level,
/// its own plugins and its own route. (Sends before the fader don't follow it, as they don't follow the fader.)
public struct VCA: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var gainDB: Double
    public var isMuted: Bool
    public init(id: UUID = UUID(), name: String, gainDB: Double = 0, isMuted: Bool = false) {
        self.id = id
        self.name = name
        self.gainDB = gainDB
        self.isMuted = isMuted
    }
}

/// The limiter last on the master: the ceiling everything that leaves the document is held under.
public struct MasterLimiter: Codable, Hashable, Sendable {
    public var ceilingDB: Double
    public var releaseMs: Double
    public var lookaheadMs: Double
    public init(ceilingDB: Double = -1, releaseMs: Double = 100, lookaheadMs: Double = 5) {
        self.ceilingDB = ceilingDB
        self.releaseMs = releaseMs
        self.lookaheadMs = lookaheadMs
    }
    public var settings: Limiter { Limiter(ceilingDB: ceilingDB, releaseMs: releaseMs, lookaheadMs: lookaheadMs) }
}

/// The master strip: the sum of everything → its plugins → its gain → its limiter → out. As it is made
/// (0 dB, no plugins, no limiter) it does nothing and is not saved.
public struct Master: Codable, Hashable, Sendable {
    /// The master's id where a strip is named by id (plugins, the mixer's listing). Never a track's or a bus's.
    public static let id = UUID(uuidString: "00000000-0000-4000-8000-4D4153544552")!
    public var gainDB: Double = 0
    public var inserts: [Insert] = []
    public var limiter: MasterLimiter?
    public init() {}
    public var isDefault: Bool { gainDB == 0 && inserts.isEmpty && limiter == nil }

    private enum CodingKeys: String, CodingKey { case gainDB, inserts, limiter }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if gainDB != 0 { try c.encode(gainDB, forKey: .gainDB) }
        if !inserts.isEmpty { try c.encode(inserts, forKey: .inserts) }
        try c.encodeIfPresent(limiter, forKey: .limiter)
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0
        inserts = try c.decodeIfPresent([Insert].self, forKey: .inserts) ?? []
        limiter = try c.decodeIfPresent(MasterLimiter.self, forKey: .limiter)
    }
}

/// An export through the master's limiter whose file still measured over the ceiling after every try.
/// No file is left. `truePeakDB` is what the last try measured; nil when the file couldn't be read back.
public struct MasterCeilingError: Error, LocalizedError, Equatable, Sendable, KeyedFailure {
    public var ceilingDB: Double
    public var truePeakDB: Double?
    public init(ceilingDB: Double, truePeakDB: Double?) {
        self.ceilingDB = ceilingDB
        self.truePeakDB = truePeakDB
    }
    public static let reason = "ceiling_not_met"
    public var errorDescription: String? { said.text }
    public var keyed: KeyedMessage? { said.keyed }
    var said: Said {
        guard let truePeakDB else {
            return Said("error.master.unread", "The file was written but couldn't be read back to check it against the master's ceiling of %@ dBTP, so it was removed.", values: [Said.n(ceilingDB, 1)])
        }
        return Said("error.master.ceiling", "The master's limiter couldn't keep the file under %1$@ dBTP: it measured %2$@ dBTP after the last try, so no file was left. Lower the master's level or raise the ceiling, and export again.", values: [Said.n(ceilingDB, 1), Said.n(truePeakDB, 2)])
    }
}

public enum Mixer {
    /// The lowest margin under the ceiling the master's limiter aims at: playback has one pass, so it
    /// aims a little under; an export measures the file it wrote and goes further down if it has to.
    public static let masterMargins: [Double] = [0.1, 0.2, 0.4, 0.8]
    /// An export's tries: the same, and further for an encoder that overshoots more than a converter does.
    public static let exportMargins: [Double] = masterMargins + [1.5, 3]
    public static let maxBuses = 64
    public static let maxVCAs = 64
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
        case noBus(String), loop(String), tooMany, inUse(String, Int), mono, badValue(Said), noStrip(String), noSend(String, String), tooManySends(String)
        /// Pan in a document wider than stereo, before its surround panner is built. The value is the layout.
        case wide(String)
        /// A surround position in a document that is mono or stereo. The value is the layout.
        case narrow(String)
        case noVCA(String), tooManyVCAs

        public var reason: String {
            switch self {
            case .noBus, .noVCA: "not_found"
            case .loop: "routing_loop"
            case .tooMany, .tooManyVCAs: "too_many"
            case .inUse: "in_use"
            case .mono, .wide: "needs_stereo"
            case .narrow: "needs_surround"
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
            case .inUse(let name, let n): Self.inUseSaid(name, n).text
            case .mono: "pan needs a stereo document; this one is mono."
            case .wide(let layout): "pan is for stereo documents; this one is \(layout). Place a track with azimuth instead."
            case .narrow(let layout): "a place by azimuth is for documents wider than stereo; this one is \(layout). Use pan."
            case .noStrip(let id): "there is no track or bus with id \(id)."
            case .noSend(let from, let to): "\(from) has no send to \(to)."
            case .tooManySends(let name): "\(name) already has \(Mixer.maxSends) sends, which is the most a strip can have."
            case .badValue(let m): m.text
            case .noVCA(let id): "there is no VCA with id \(id)."
            case .tooManyVCAs: "a document can have \(Mixer.maxVCAs) VCAs at most."
            }
        }
        /// The same message by its key in the app's string catalogue (see `KeyedMessage`).
        public var keyed: KeyedMessage? {
            switch self {
            case .noBus(let id): KeyedMessage("error.mixer.noBus", ["\(id)"])
            case .loop(let name): KeyedMessage("error.mixer.loop", ["\(name)"])
            case .tooMany: KeyedMessage("error.mixer.tooMany", ["\(Mixer.maxBuses)"])
            case .inUse(let name, let n): Self.inUseSaid(name, n).keyed
            case .mono: KeyedMessage("error.mixer.mono")
            case .wide(let layout): KeyedMessage("error.mixer.wide", ["\(layout)"])
            case .narrow(let layout): KeyedMessage("error.mixer.narrow", ["\(layout)"])
            case .noStrip(let id): KeyedMessage("error.mixer.noStrip", ["\(id)"])
            case .noSend(let from, let to): KeyedMessage("error.mixer.noSend", ["\(from)", "\(to)"])
            case .tooManySends(let name): KeyedMessage("error.mixer.tooManySends", ["\(name)", "\(Mixer.maxSends)"])
            case .badValue(let m): m.keyed
            case .noVCA(let id): KeyedMessage("error.mixer.noVCA", ["\(id)"])
            case .tooManyVCAs: KeyedMessage("error.mixer.tooManyVCAs", ["\(Mixer.maxVCAs)"])
            }
        }
        static func inUseSaid(_ name: String, _ n: Int) -> Said {
            counted(n, Said("error.mixer.inUse.one", "1 strip is routed to %@. Say where it should go instead with reroute (a bus id, or \"master\"), or route it elsewhere first.", name),
                    Said("error.mixer.inUse.other", "%1$@ strips are routed to %2$@. Say where they should go instead with reroute (a bus id, or \"master\"), or route them elsewhere first.", "\(n)", name))
        }
    }
}

extension Project {
    /// True when the project uses anything of the mixer. Such a project is saved as format 2, which a
    /// Jämmer from before the mixer refuses to open instead of playing every track straight out.
    public var usesMixer: Bool {
        !buses.isEmpty || !vcas.isEmpty || !master.isDefault
            || tracks.contains { $0.pan != 0 || $0.output != nil || !$0.sends.isEmpty || $0.vca != nil || $0.frozen != nil || $0.inserts.contains { $0.key != nil } }
    }

    /// Whether the signal of `from` (a track or a bus) reaches `to`: through outputs, sends, and the keys
    /// that plugins listen to. A key from `from` to a plugin on `to` would close a loop exactly when
    /// `to` already reaches `from`.
    public func reaches(from: UUID, to: UUID) -> Bool {
        var seen = Set<UUID>(), queue = [from]
        while let id = queue.popLast() {
            if id == to { return true }
            guard seen.insert(id).inserted else { continue }
            if let t = tracks.first(where: { $0.id == id }) { queue += [t.output].compactMap { $0 } + t.sends.map(\.to) }
            if let b = bus(id) { queue += [b.output].compactMap { $0 } + b.sends.map(\.to) }
            // Everything that listens to this strip.
            for t in tracks where t.inserts.contains(where: { $0.key == id }) { queue.append(t.id) }
            for b in buses where b.inserts.contains(where: { $0.key == id }) { queue.append(b.id) }
        }
        return false
    }

    /// True when some strip reaches itself (only possible through a key; routes and sends alone are
    /// refused where they are set).
    public var hasKeyLoop: Bool {
        let listening = tracks.filter { $0.inserts.contains { $0.key != nil } }.map(\.id) + buses.filter { $0.inserts.contains { $0.key != nil } }.map(\.id)
        for strip in listening {
            let inserts = self.strip(strip)?.inserts ?? []
            for source in inserts.compactMap(\.key) where source == strip || reaches(from: strip, to: source) { return true }
        }
        return false
    }

    /// Gives the plugin `insert` on `strip` (a track or a bus) a key, or (`nil`) takes it away. Refused
    /// when the source isn't there, is the strip itself, or would be fed by what it is to control.
    public mutating func setKey(strip: UUID, insert: UUID, key: UUID?) throws {
        guard strip != Master.id, var list = self.strip(strip)?.inserts, let i = list.firstIndex(where: { $0.id == insert }) else {
            throw Mixer.Failure.noStrip(strip.uuidString)
        }
        if let key {
            guard tracks.contains(where: { $0.id == key }) || bus(key) != nil else { throw Mixer.Failure.noStrip(key.uuidString) }
            guard key != strip, !reaches(from: strip, to: key) else { throw Mixer.Failure.loop(self.strip(strip)?.name ?? "the strip") }
        }
        list[i].key = key
        setInserts(list, on: strip)
    }

    public func vca(_ id: UUID) -> VCA? { vcas.first { $0.id == id } }

    /// The buses a signal passes after leaving `bus`, by outputs and sends, `bus` itself included.
    private func downstream(of bus: UUID) -> Set<UUID> {
        var seen = Set<UUID>(), queue = [bus]
        while let id = queue.popLast() {
            guard seen.insert(id).inserted, let b = self.bus(id) else { continue }
            if let o = b.output { queue.append(o) }
            queue += b.sends.map(\.to)
        }
        return seen
    }

    /// The tracks that are heard while `solo` (ids of tracks and buses) is on: a soloed track, and every
    /// track that reaches a soloed bus through its output or a send. Ids that aren't strips count for nothing.
    public func heardInSolo(_ solo: Set<UUID>) -> Set<UUID> {
        var heard = Set<UUID>()
        for t in tracks {
            if solo.contains(t.id) { heard.insert(t.id); continue }
            let first = ([t.output].compactMap { $0 } + t.sends.map(\.to))
            if first.contains(where: { !downstream(of: $0).isDisjoint(with: solo) }) { heard.insert(t.id) }
        }
        return heard
    }

    /// The project as it is listened to with `solo` on: every track that isn't heard is muted, nothing
    /// else is touched. Solo is a way of listening: it is not in the document, not undone, not exported.
    /// With no strip of this project in `solo`, the project itself.
    public func listening(solo: Set<UUID>) -> Project {
        let real = solo.filter { id in tracks.contains { $0.id == id } || bus(id) != nil }
        guard !real.isEmpty else { return self }
        return silencing(Set(tracks.map(\.id)).subtracting(heardInSolo(real)))
    }

    /// A copy in which `quiet` (track ids) are not heard. A track is muted, unless a plugin on a strip
    /// that is still heard listens to it: a muted track is a silent key, and a ducked track mustn't come
    /// up because the voice over it was soloed away. Such a track keeps playing into a muted bus instead,
    /// so its key is what it was and nothing of it reaches the output.
    public func silencing(_ quiet: Set<UUID>) -> Project {
        guard !quiet.isEmpty else { return self }
        var listenedTo = Set<UUID>()
        for t in tracks where !quiet.contains(t.id) { listenedTo.formUnion(t.inserts.filter { !$0.bypass }.compactMap(\.key)) }
        for b in buses { listenedTo.formUnion(b.inserts.filter { !$0.bypass }.compactMap(\.key)) }
        var p = self
        var sink = false
        for t in p.tracks.indices where quiet.contains(p.tracks[t].id) {
            if listenedTo.contains(p.tracks[t].id), !p.tracks[t].isMuted {
                p.tracks[t].output = Self.frozenSink
                p.tracks[t].sends = []
                sink = true
            } else {
                p.tracks[t].isMuted = true
            }
        }
        if sink { p.buses.append(Bus(id: Self.frozenSink, name: "sink", isMuted: true)) }
        return p
    }

    /// The project with only `chosen` (track ids) heard: for exporting or measuring some of the tracks.
    /// The others are gone, except one that a plugin on a chosen track listens to, which stays as its key
    /// and is heard nowhere. nil: the project itself.
    public func only(tracks chosen: Set<UUID>?) -> Project {
        guard let chosen else { return self }
        var keys = Set<UUID>()
        for t in tracks where chosen.contains(t.id) { keys.formUnion(t.inserts.filter { !$0.bypass }.compactMap(\.key)) }
        var p = self
        p.tracks = p.tracks.filter { chosen.contains($0.id) || keys.contains($0.id) }
        for i in p.tracks.indices where chosen.contains(p.tracks[i].id) { p.tracks[i].isMuted = false }
        return p.silencing(Set(p.tracks.map(\.id)).subtracting(chosen))
    }
    /// A strip's fader and mute as they are heard: its own, with its VCA's level added and its VCA's mute.
    /// Without a VCA, exactly its own.
    public func heard(gainDB: Double, muted: Bool, vca: UUID?) -> (gainDB: Double, muted: Bool) {
        guard let v = vca.flatMap({ self.vca($0) }) else { return (gainDB, muted) }
        return (gainDB + v.gainDB, muted || v.isMuted)
    }

    @discardableResult
    public mutating func addVCA(name: String) throws -> VCA {
        guard vcas.count < Mixer.maxVCAs else { throw Mixer.Failure.tooManyVCAs }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { throw Mixer.Failure.badValue(Said("error.value.vca_needs_name_1", "a VCA needs a name of 1 to 200 characters.")) }
        let v = VCA(name: trimmed)
        vcas.append(v)
        return v
    }

    public mutating func setVCA(_ id: UUID, name: String? = nil, gainDB: Double? = nil, muted: Bool? = nil) throws {
        guard let i = vcas.firstIndex(where: { $0.id == id }) else { throw Mixer.Failure.noVCA(id.uuidString) }
        if let name {
            let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, t.count <= 200 else { throw Mixer.Failure.badValue(Said("error.value.vca_needs_name_1", "a VCA needs a name of 1 to 200 characters.")) }
            vcas[i].name = t
        }
        if let gainDB {
            guard gainDB.isFinite, Mixer.gainRange.contains(gainDB) else { throw Mixer.Failure.badValue(Said("error.value.gaindb_1_2", "gainDB must be %1$@ to %2$@.", "\(Int(Mixer.gainRange.lowerBound))", "\(Int(Mixer.gainRange.upperBound))")) }
            vcas[i].gainDB = gainDB
        }
        if let muted { vcas[i].isMuted = muted }
    }

    /// Takes a VCA away and leaves the sound as it was: its level goes into each member's own fader
    /// (kept within what a fader can be), and a muted VCA leaves its members muted.
    public mutating func removeVCA(_ id: UUID) throws {
        guard let v = vca(id) else { throw Mixer.Failure.noVCA(id.uuidString) }
        func fold(_ g: Double) -> Double { min(Mixer.gainRange.upperBound, max(Mixer.gainRange.lowerBound, ((g + v.gainDB) * 100).rounded() / 100)) }
        for t in tracks.indices where tracks[t].vca == id {
            if v.gainDB != 0 { tracks[t].gainDB = fold(tracks[t].gainDB) }
            tracks[t].isMuted = tracks[t].isMuted || v.isMuted
            tracks[t].vca = nil
        }
        for b in buses.indices where buses[b].vca == id {
            if v.gainDB != 0 { buses[b].gainDB = fold(buses[b].gainDB) }
            buses[b].isMuted = buses[b].isMuted || v.isMuted
            buses[b].vca = nil
        }
        vcas.removeAll { $0.id == id }
    }

    /// Puts a track or a bus in a VCA group, or (`nil`) takes it out. Taking it out changes its level by
    /// what the VCA added; that is what leaving a group means.
    public mutating func setMember(_ strip: UUID, vca: UUID?) throws {
        if let vca, self.vca(vca) == nil { throw Mixer.Failure.noVCA(vca.uuidString) }
        if let t = tracks.firstIndex(where: { $0.id == strip }) { tracks[t].vca = vca }
        else if let b = buses.firstIndex(where: { $0.id == strip }) { buses[b].vca = vca }
        else { throw Mixer.Failure.noStrip(strip.uuidString) }
    }

    public func bus(_ id: UUID) -> Bus? { buses.first { $0.id == id } }

    /// A track or a bus by its id, as the thing plugins sit on: its name and its plugins.
    public func strip(_ id: UUID) -> (name: String, inserts: [Insert], isBus: Bool)? {
        if let t = tracks.first(where: { $0.id == id }) { return (t.name, t.inserts, false) }
        if let b = bus(id) { return (b.name, b.inserts, true) }
        if id == Master.id { return ("Master", master.inserts, true) }
        return nil
    }
    /// Replaces the plugins of the track or bus with that id.
    public mutating func setInserts(_ inserts: [Insert], on id: UUID) {
        if let t = tracks.firstIndex(where: { $0.id == id }) { tracks[t].inserts = inserts }
        else if let b = buses.firstIndex(where: { $0.id == id }) { buses[b].inserts = inserts }
        else if id == Master.id { master.inserts = inserts }
    }

    /// Every plugin in the project: on the tracks and on the buses.
    public var allInserts: [Insert] { tracks.flatMap(\.inserts) + buses.flatMap(\.inserts) + master.inserts }

    /// Changes the master: its gain, and its limiter (`.some(nil)` takes the limiter away).
    public mutating func setMaster(gainDB: Double? = nil, limiter: MasterLimiter?? = nil) throws {
        if let gainDB {
            guard gainDB.isFinite, Mixer.gainRange.contains(gainDB) else { throw Mixer.Failure.badValue(Said("error.value.gaindb_1_2", "gainDB must be %1$@ to %2$@.", "\(Int(Mixer.gainRange.lowerBound))", "\(Int(Mixer.gainRange.upperBound))")) }
            master.gainDB = gainDB
        }
        if let limiter {
            if let l = limiter {
                // The same checks as the limiter itself makes, so a master that is set is one that runs.
                do { _ = try Limiter.Processor(l.settings, channels: channels, sampleRate: sampleRate) }
                catch { throw Mixer.Failure.badValue(Said.of(error)) }
            }
            master.limiter = limiter
        }
    }

    /// Takes the mixer out of a copy that is made to render one track by itself (for a bounce, an
    /// analysis, a waveform): what is wanted there is the track's own sound, before its pan and its bus.
    /// The pan and the bus still apply afterwards, to whatever the track then plays.
    public mutating func withoutMixer() {
        buses = []
        master = Master()
        vcas = []
        automation = []
        // (…and not from a frozen file either: the track's own sound, before its plugins, is what is wanted.)
        for t in tracks.indices { tracks[t].pan = 0; tracks[t].output = nil; tracks[t].sends = []; tracks[t].vca = nil; tracks[t].frozen = nil }
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
        if let g = gainDB, !Mixer.gainRange.contains(g) { throw Mixer.Failure.badValue(Said("error.value.gaindb_96_24", "gainDB must be −96 to 24.")) }
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
        let unchanged = self
        if let t = tracks.firstIndex(where: { $0.id == from }) {
            try change(&tracks[t].sends, name: tracks[t].name)
        } else if let b = buses.firstIndex(where: { $0.id == from }) {
            guard remove || (from != to && !loops(bus: from, into: to)) else { throw Mixer.Failure.loop(buses[b].name) }
            try change(&buses[b].sends, name: buses[b].name)
        } else {
            throw Mixer.Failure.noStrip(from.uuidString)
        }
        // A send can close a loop through a key (a plugin that listens to what this would now feed).
        if !remove, hasKeyLoop { let name = strip(from)?.name ?? "the strip"; self = unchanged; throw Mixer.Failure.loop(name) }
    }

    @discardableResult
    public mutating func addBus(name: String, output: UUID? = nil) throws -> Bus {
        guard buses.count < Mixer.maxBuses else { throw Mixer.Failure.tooMany }
        if let output, bus(output) == nil { throw Mixer.Failure.noBus(output.uuidString) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 200 else { throw Mixer.Failure.badValue(Said("error.value.bus_needs_name_1", "a bus needs a name of 1 to 200 characters.")) }
        let b = Bus(name: trimmed, output: output)
        buses.append(b)
        return b
    }

    /// Turns a bus's image round the listener (`turned: false` takes the turn away). Loudspeaker layouts wider than stereo only.
    public mutating func setBusTurn(_ id: UUID, azimuth: Double? = nil, turned: Bool? = nil) throws {
        guard let i = buses.firstIndex(where: { $0.id == id }) else { throw Mixer.Failure.noBus(id.uuidString) }
        guard channels > 2, !layout.isAmbisonic else { throw Mixer.Failure.narrow(layout.rawValue) }
        if turned == false, azimuth == nil { buses[i].azimuth = nil; return }
        if let azimuth {
            guard azimuth.isFinite, abs(azimuth) <= 180 else { throw Mixer.Failure.badValue(Said("error.value.azimuth_180_180", "azimuth is −180 to 180.")) }
            buses[i].azimuth = azimuth
        }
    }

    public mutating func setBus(_ id: UUID, name: String? = nil, gainDB: Double? = nil, pan: Double? = nil, muted: Bool? = nil, output: UUID?? = nil) throws {
        guard let i = buses.firstIndex(where: { $0.id == id }) else { throw Mixer.Failure.noBus(id.uuidString) }
        if let name {
            let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, t.count <= 200 else { throw Mixer.Failure.badValue(Said("error.value.bus_needs_name_1", "a bus needs a name of 1 to 200 characters.")) }
            buses[i].name = t
        }
        if let gainDB {
            guard Mixer.gainRange.contains(gainDB) else { throw Mixer.Failure.badValue(Said("error.value.gaindb_96_24", "gainDB must be −96 to 24.")) }
            buses[i].gainDB = gainDB
        }
        if let pan {
            guard Mixer.panRange.contains(pan) else { throw Mixer.Failure.badValue(Said("error.value.pan_1_left_1", "pan must be −1 (left) to 1 (right).")) }
            guard pan == 0 || channels == 2 else { throw channels == 1 ? Mixer.Failure.mono : Mixer.Failure.wide(layout.rawValue) }
            buses[i].pan = pan
        }
        if let muted { buses[i].isMuted = muted }
        if let output {
            if let to = output {
                guard bus(to) != nil else { throw Mixer.Failure.noBus(to.uuidString) }
                guard !loops(bus: id, into: to) else { throw Mixer.Failure.loop(buses[i].name) }
            }
            let before = buses[i].output
            buses[i].output = output
            if hasKeyLoop { buses[i].output = before; throw Mixer.Failure.loop(buses[i].name) }
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
        // Sends to a bus that is gone go with it, and so do the keys taken from it.
        for t in tracks.indices { for i in tracks[t].inserts.indices where tracks[t].inserts[i].key == id { tracks[t].inserts[i].key = nil } }
        for o in buses.indices { for i in buses[o].inserts.indices where buses[o].inserts[i].key == id { buses[o].inserts[i].key = nil } }
        for t in tracks.indices { tracks[t].sends.removeAll { $0.to == id } }
        for o in buses.indices { buses[o].sends.removeAll { $0.to == id } }
        buses.removeAll { $0.id == id }
    }

    /// Places a track by the surround panner (or takes it out with `placed: false`). Values left out keep the
    /// track's current place, or the default (the center, level, 60° wide).
    public mutating func setTrackPosition(_ track: UUID, azimuth: Double? = nil, elevation: Double? = nil, width: Double? = nil, placed: Bool? = nil) throws {
        guard let i = tracks.firstIndex(where: { $0.id == track }) else { throw Mixer.Failure.noStrip(track.uuidString) }
        guard channels > 2 else { throw Mixer.Failure.narrow(layout.rawValue) }
        if placed == false, azimuth == nil, elevation == nil, width == nil { tracks[i].position = nil; return }
        var p = tracks[i].position ?? SurroundPosition()
        if let azimuth { p.azimuth = azimuth }
        if let elevation { p.elevation = elevation }
        if let width { p.width = width }
        guard p.isValid else { throw Mixer.Failure.badValue(Said("error.value.azimuth_180_180_elevation", "azimuth is −180 to 180, elevation 0 to 90, width 0 to 180.")) }
        tracks[i].position = p
    }

    public mutating func setTrackRoute(_ track: UUID, pan: Double? = nil, output: UUID?? = nil) throws {
        guard let t = tracks.firstIndex(where: { $0.id == track }) else { throw EditError.noTrack }
        if let pan {
            guard Mixer.panRange.contains(pan) else { throw Mixer.Failure.badValue(Said("error.value.pan_1_left_1", "pan must be −1 (left) to 1 (right).")) }
            guard pan == 0 || channels == 2 else { throw channels == 1 ? Mixer.Failure.mono : Mixer.Failure.wide(layout.rawValue) }
            tracks[t].pan = pan
        }
        if let output {
            if let to = output, bus(to) == nil { throw Mixer.Failure.noBus(to.uuidString) }
            let before = tracks[t].output
            tracks[t].output = output
            // A plugin on this track may listen to a bus the track would now feed.
            if hasKeyLoop { tracks[t].output = before; throw Mixer.Failure.loop(tracks[t].name) }
        }
    }
}

extension Mixer.Failure: KeyedFailure {}
