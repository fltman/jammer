import Foundation

/// The Track menu's whole-track edits (the comfort block, step 4): remove, duplicate, move, and the lock that
/// keeps a track's clips where they are. Each is a value change on the project: one undo step.
public enum TrackEditError: Error, LocalizedError, Equatable, KeyedFailure {
    case noTrack
    /// A document keeps at least one track.
    case lastTrack
    /// A step would change the clips of a locked track.
    case locked(String)

    public var errorDescription: String? {
        switch self {
        case .noTrack: "There's no track with that id."
        case .lastTrack: "A document keeps at least one track."
        case .locked(let name): "\(name) is locked; unlock it to change its clips."
        }
    }

    public var keyed: KeyedMessage? {
        switch self {
        case .noTrack: KeyedMessage("error.track.noTrack")
        case .lastTrack: KeyedMessage("error.track.lastTrack")
        case .locked(let name): KeyedMessage("error.track.locked", [name])
        }
    }
}

extension Project {
    func trackIndex(_ id: UUID) throws -> Int {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { throw TrackEditError.noTrack }
        return i
    }

    /// Removes a track with its automation; a plugin elsewhere keyed by it loses the key. Its files stay where they
    /// are (undo brings the track back as it was).
    public mutating func removeTrack(_ id: UUID) throws {
        let i = try trackIndex(id)
        guard tracks.count > 1 else { throw TrackEditError.lastTrack }
        tracks.remove(at: i)
        automation.removeAll { $0.strip == id || $0.to == id }
        for t in tracks.indices { for k in tracks[t].inserts.indices where tracks[t].inserts[k].key == id { tracks[t].inserts[k].key = nil } }
        for b in buses.indices { for k in buses[b].inserts.indices where buses[b].inserts[k].key == id { buses[b].inserts[k].key = nil } }
        for k in master.inserts.indices where master.inserts[k].key == id { master.inserts[k].key = nil }
    }

    /// A copy of a track right under it: the same clips, level, pan, plugins, sends and automation, with ids of its
    /// own and the name given. Not locked and not frozen (a copy is made to be changed). Returns the copy's id.
    @discardableResult
    public mutating func duplicateTrack(_ id: UUID, name: String) throws -> UUID {
        let i = try trackIndex(id)
        var copy = tracks[i]
        copy.id = UUID()
        copy.name = name
        copy.locked = false
        copy.frozen = nil
        for c in copy.clips.indices { copy.clips[c].id = UUID() }
        var insertIDs: [UUID: UUID] = [:]
        for k in copy.inserts.indices {
            let new = UUID()
            insertIDs[copy.inserts[k].id] = new
            copy.inserts[k].id = new
        }
        tracks.insert(copy, at: i + 1)
        for lane in automation where lane.strip == id {
            var l = lane
            l.strip = copy.id
            l.insert = lane.insert.map { insertIDs[$0] ?? $0 }
            automation.append(l)
        }
        return copy.id
    }

    /// Moves a track to `index` among the tracks (clamped); the order is the lanes' and the mixer's.
    public mutating func moveTrack(_ id: UUID, to index: Int) throws {
        let i = try trackIndex(id)
        let t = tracks.remove(at: i)
        tracks.insert(t, at: max(0, min(index, tracks.count)))
    }

    /// The first locked track whose clips differ between `before` and this project, if any (StepRunner's guard).
    public func lockedTrackChanged(since before: Project) -> String? {
        for old in before.tracks where old.locked {
            guard let now = tracks.first(where: { $0.id == old.id }) else { return old.name }
            if now.clips != old.clips { return old.name }
        }
        return nil
    }
}
