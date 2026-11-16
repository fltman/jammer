import CryptoKit
import Foundation

/// A strip played from a file instead of being worked out: a track or a bus rendered once through
/// its plugins, for sessions with more plugins than the Mac plays. The strip itself is untouched
/// underneath (its clips, its plugins), so thawing it is taking this away and nothing else. Its fader,
/// pan, mute, sends and route come after the file and stay live.
public struct Frozen: Codable, Hashable, Sendable {
    /// The frozen file (one of the project's sources).
    public var sourceID: UUID
    /// Where on the timeline the file begins, and how long it is.
    public var start: Frame
    public var length: Frame
    /// A digest of everything the file was made from. If any of that changes the file would be stale,
    /// so changes to it are refused while the strip is frozen.
    public var madeFrom: String

    public init(sourceID: UUID, start: Frame, length: Frame, madeFrom: String) {
        self.sourceID = sourceID
        self.start = start
        self.length = length
        self.madeFrom = madeFrom
    }
}

public enum FreezeError: Error, LocalizedError, Equatable {
    case noStrip(String), alreadyFrozen(String), notFrozen(String), nothing(String), frozen(String)

    public var reason: String {
        switch self {
        case .noStrip: "not_found"
        case .alreadyFrozen: "already_frozen"
        case .notFrozen: "not_frozen"
        case .nothing: "nothing_to_freeze"
        case .frozen: "frozen"
        }
    }
    public var errorDescription: String? {
        switch self {
        case .noStrip(let id): "there is no track or bus with id \(id)."
        case .alreadyFrozen(let name): "\(name) is frozen already."
        case .notFrozen(let name): "\(name) isn't frozen."
        case .nothing(let name): "\(name) has no sound to freeze."
        case .frozen(let name): "\(name) is frozen, and this would change what it was frozen from. Unfreeze it first."
        }
    }
}

extension Project {
    static let frozenSink = UUID(uuidString: "00000000-0000-4000-8000-0000534E4B00")!

    public var hasFreezes: Bool { tracks.contains { $0.frozen != nil } || buses.contains { $0.frozen != nil } }

    /// The frozen state of a track or a bus, if it has one.
    public func frozen(_ strip: UUID) -> Frozen? {
        tracks.first { $0.id == strip }?.frozen ?? bus(strip)?.frozen
    }

    // MARK: What a strip is made from

    /// A digest of everything that decides what a strip sounds like before its own fader: for a track
    /// its clips and plugins, and whatever its plugins listen to; for a bus its plugins and everything
    /// that arrives at it. nil when there is no such strip.
    public func content(of strip: UUID) -> String? {
        var seen = Set<UUID>()
        guard let text = signal(of: strip, afterFader: false, seen: &seen) else { return nil }
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func signal(of id: UUID, afterFader: Bool, seen: inout Set<UUID>) -> String? {
        // (A loop can't be set and is cut in a file; this is so that even one doesn't hang here.)
        guard seen.insert(id).inserted else { return "again:\(id.uuidString)" }
        defer { seen.remove(id) }
        func encoded<T: Encodable>(_ value: T) -> String {
            let e = JSONEncoder()
            e.outputFormatting = [.sortedKeys]
            return (try? e.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
        }
        func keys(_ inserts: [Insert], _ seen: inout Set<UUID>) -> String {
            inserts.filter { !$0.bypass }.compactMap(\.key).map { signal(of: $0, afterFader: true, seen: &seen) ?? "gone" }.joined(separator: ";")
        }
        if let t = tracks.first(where: { $0.id == id }) {
            var s = "track{clips:\(encoded(t.clips)),inserts:\(encoded(t.inserts)),keys:[\(keys(t.inserts, &seen))]"
            if afterFader { let h = heard(gainDB: t.gainDB, muted: t.isMuted, vca: t.vca); s += ",fader:\(h.gainDB),\(h.muted),\(t.pan)" }
            return s + "}"
        }
        if let b = bus(id) {
            var inputs: [String] = []
            for t in tracks {
                if t.output == id { inputs.append("out:" + (signal(of: t.id, afterFader: true, seen: &seen) ?? "")) }
                for send in t.sends where send.to == id { inputs.append("send:\(send.gainDB),\(send.pre):" + (signal(of: t.id, afterFader: !send.pre, seen: &seen) ?? "")) }
            }
            for other in buses where other.id != id {
                if other.output == id { inputs.append("out:" + (signal(of: other.id, afterFader: true, seen: &seen) ?? "")) }
                for send in other.sends where send.to == id { inputs.append("send:\(send.gainDB),\(send.pre):" + (signal(of: other.id, afterFader: !send.pre, seen: &seen) ?? "")) }
            }
            var s = "bus{inserts:\(encoded(b.inserts)),keys:[\(keys(b.inserts, &seen))],in:[\(inputs.joined(separator: "|"))]"
            if afterFader { let h = heard(gainDB: b.gainDB, muted: b.isMuted, vca: b.vca); s += ",fader:\(h.gainDB),\(h.muted),\(b.pan)" }
            return s + "}"
        }
        return nil
    }

    /// The name of a frozen strip whose content is no longer what it was frozen from in `new`, if any:
    /// the change from this project to `new` must then be refused. A strip that was unfrozen, frozen
    /// afresh or removed in `new` is no violation.
    public func frozenViolation(in new: Project) -> String? {
        for (id, name, frozen) in tracks.compactMap({ t in t.frozen.map { (t.id, t.name, $0) } }) + buses.compactMap({ b in b.frozen.map { (b.id, b.name, $0) } }) {
            guard new.frozen(id) == frozen else { continue }
            if new.content(of: id) != frozen.madeFrom { return name }
        }
        return nil
    }

    // MARK: Rendering what is to be frozen

    /// A copy in which only `strip`, before its own fader, reaches the output: everything else still
    /// runs (a plugin on the strip may listen to another track, and a bus is made of its inputs) but
    /// ends in a muted bus. Rendering the copy's mix gives the strip's sound as it is in this mix.
    func freezeContext(for strip: UUID) -> Project? {
        var p = self
        p.master = Master()
        let sink = Bus(id: Self.frozenSink, name: "sink", isMuted: true)
        if let t = p.tracks.firstIndex(where: { $0.id == strip }) {
            p.tracks[t].gainDB = 0; p.tracks[t].pan = 0; p.tracks[t].isMuted = false
            p.tracks[t].output = nil; p.tracks[t].sends = []; p.tracks[t].vca = nil; p.tracks[t].frozen = nil
            for o in p.tracks.indices where o != t && p.tracks[o].output == nil { p.tracks[o].output = sink.id }
            for b in p.buses.indices where p.buses[b].output == nil { p.buses[b].output = sink.id }
        } else if let b = p.buses.firstIndex(where: { $0.id == strip }) {
            p.buses[b].gainDB = 0; p.buses[b].pan = 0; p.buses[b].isMuted = false
            p.buses[b].output = nil; p.buses[b].sends = []; p.buses[b].vca = nil; p.buses[b].frozen = nil
            for o in p.tracks.indices where p.tracks[o].output == nil { p.tracks[o].output = sink.id }
            for o in p.buses.indices where o != b && p.buses[o].output == nil { p.buses[o].output = sink.id }
        } else {
            return nil
        }
        p.buses.append(sink)
        return p
    }

    /// The stretch of the timeline a strip's frozen file covers: a track's own extent, the whole
    /// document for a bus, and a little more when it has plugins that ring on.
    public func freezeRange(for strip: UUID) -> Range<Frame>? {
        let tail = Frame(2 * sampleRate)
        if let t = tracks.first(where: { $0.id == strip }) {
            guard let first = t.clips.map(\.start).min() else { return nil }
            return first..<(t.end + (t.inserts.contains { !$0.bypass } ? tail : 0))
        }
        if let b = bus(strip) {
            guard length > 0 else { return nil }
            return 0..<(length + (b.inserts.contains { !$0.bypass } ? tail : 0))
        }
        return nil
    }

    /// Freezes `strip`: renders it as it sounds in this mix (through `render`, which gets the copy to
    /// render and the range) into a float file under `media`, and marks the strip frozen. One value
    /// change; the previous project is the undo.
    public func freezing(_ strip: UUID, media: URL, render: (Project, Range<Frame>, (UnsafeBufferPointer<Float>) throws -> Void) throws -> Void) throws -> Project {
        guard let now = self.strip(strip), strip != Master.id else { throw FreezeError.noStrip(strip.uuidString) }
        guard frozen(strip) == nil else { throw FreezeError.alreadyFrozen(now.name) }
        guard let range = freezeRange(for: strip), !range.isEmpty, let context = freezeContext(for: strip), let made = content(of: strip) else {
            throw FreezeError.nothing(now.name)
        }
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let url = media.appending(path: "\(UUID().uuidString.prefix(8)) frozen.wav")
        let writer = try WAVWriter(url: url, options: .init(encoding: .float32, channels: channels, sampleRate: sampleRate))
        do {
            try render(context, range) { try writer.write(Array($0)) }
            try writer.finish()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        let source = SourceRef(name: "\(now.name) (frozen)", path: url.path, info: try AudioFileReader.info(at: url))
        var p = self
        p.sources.append(source)
        let record = Frozen(sourceID: source.id, start: range.lowerBound, length: source.info.frames, madeFrom: made)
        if let t = p.tracks.firstIndex(where: { $0.id == strip }) { p.tracks[t].frozen = record }
        else if let b = p.buses.firstIndex(where: { $0.id == strip }) { p.buses[b].frozen = record }
        return p
    }

    /// Thaws `strip`: it is worked out live again, from exactly what it was all along.
    public func unfreezing(_ strip: UUID) throws -> Project {
        guard let now = self.strip(strip) else { throw FreezeError.noStrip(strip.uuidString) }
        guard frozen(strip) != nil else { throw FreezeError.notFrozen(now.name) }
        var p = self
        if let t = p.tracks.firstIndex(where: { $0.id == strip }) { p.tracks[t].frozen = nil }
        else if let b = p.buses.firstIndex(where: { $0.id == strip }) { p.buses[b].frozen = nil }
        p.pruneSources()
        return p
    }

    // MARK: Playing a project with frozen strips

    /// The project as it is played: a frozen track plays its file and runs no plugins; a frozen bus
    /// plays its file in place of everything that fed it, and what only fed frozen buses isn't worked
    /// out at all. Faders, pans, mutes, sends and routes of the frozen strips are as they are now.
    /// Without a frozen strip, the project itself.
    public func played() -> Project {
        guard hasFreezes else { return self }
        var p = self
        for t in p.tracks.indices {
            guard let f = p.tracks[t].frozen, source(f.sourceID) != nil else { p.tracks[t].frozen = nil; continue }
            p.tracks[t].clips = [Clip(sourceID: f.sourceID, start: f.start, length: f.length)]
            p.tracks[t].inserts = []
            p.tracks[t].frozen = nil
        }
        let frozenBuses = Set(buses.filter { b in b.frozen.map { source($0.sourceID) != nil } ?? false }.map(\.id))
        for b in p.buses.indices where !frozenBuses.contains(p.buses[b].id) { p.buses[b].frozen = nil }
        guard !frozenBuses.isEmpty else { return p }

        // What still has to be worked out: every strip that reaches the output without going into a
        // frozen bus, or that a plugin on such a strip listens to. The rest is silent work.
        var alive = Set<UUID>()
        var changed = true
        func leadsOut(_ target: UUID?) -> Bool { target == nil || (!frozenBuses.contains(target!) && alive.contains(target!)) }
        while changed {
            changed = false
            for t in p.tracks where !alive.contains(t.id) {
                if leadsOut(t.output) || t.sends.contains(where: { leadsOut($0.to) }) { alive.insert(t.id); changed = true }
            }
            for b in p.buses where !alive.contains(b.id) {
                if leadsOut(b.output) || b.sends.contains(where: { leadsOut($0.to) }) { alive.insert(b.id); changed = true }
            }
            // A key: its source is needed while the strip that listens runs its plugins (a frozen bus doesn't).
            for t in p.tracks where alive.contains(t.id) {
                for k in t.inserts.filter({ !$0.bypass }).compactMap(\.key) where !alive.contains(k) { alive.insert(k); changed = true }
            }
            for b in p.buses where alive.contains(b.id) && !frozenBuses.contains(b.id) {
                for k in b.inserts.filter({ !$0.bypass }).compactMap(\.key) where !alive.contains(k) { alive.insert(k); changed = true }
            }
        }
        var needsSink = false
        func redirected(_ output: UUID?, _ sends: [Send]) -> (UUID?, [Send]) {
            var out = output
            if let o = output, frozenBuses.contains(o) { out = Self.frozenSink; needsSink = true }
            return (out, sends.filter { !frozenBuses.contains($0.to) })
        }
        for t in p.tracks.indices {
            (p.tracks[t].output, p.tracks[t].sends) = redirected(p.tracks[t].output, p.tracks[t].sends)
            if !alive.contains(p.tracks[t].id) { p.tracks[t].isMuted = true; p.tracks[t].inserts = [] }
        }
        for b in p.buses.indices {
            let id = p.buses[b].id
            if frozenBuses.contains(id) {
                // The file stands in for the sum and the plugins; the fader and the way out are the bus's own.
                let f = p.buses[b].frozen!
                p.buses[b].inserts = []
                p.buses[b].frozen = nil
                var stand = Track(id: f.sourceID, name: "\(p.buses[b].name) (frozen)", clips: [Clip(sourceID: f.sourceID, start: f.start, length: f.length)])
                stand.output = id
                p.tracks.append(stand)
            } else {
                (p.buses[b].output, p.buses[b].sends) = redirected(p.buses[b].output, p.buses[b].sends)
                if !alive.contains(id) { p.buses[b].isMuted = true; p.buses[b].inserts = [] }
            }
        }
        if needsSink { p.buses.append(Bus(id: Self.frozenSink, name: "sink", isMuted: true)) }
        return p
    }
}
