import Foundation

/// A stretch of a track recorded more than once (recording, R3): every take kept, the newest chosen, another chosen
/// later from the take list or with `set_take`. What lay under the stretch before the first take is kept with it, so
/// a shorter take chosen later leaves the old sound around it, and deleting the last take gives it back.
public struct TakeGroup: Codable, Hashable, Sendable, Identifiable {
    public struct Take: Codable, Hashable, Sendable, Identifiable {
        public var id: UUID
        public var sourceID: UUID
        /// Where the take's sound starts in its file: the pre-roll recorded before a punch-in is skipped.
        public var sourceStart: Frame
        public var start: Frame
        public var length: Frame
        /// 1, 2, 3…: the order they were recorded in, kept when one is deleted.
        public var number: Int
        public var end: Frame { start + length }
        public var clip: Clip { Clip(sourceID: sourceID, sourceStart: sourceStart, start: start, length: length) }

        public init(id: UUID = UUID(), sourceID: UUID, sourceStart: Frame = 0, start: Frame, length: Frame, number: Int) {
            self.id = id
            self.sourceID = sourceID
            self.sourceStart = sourceStart
            self.start = start
            self.length = length
            self.number = number
        }
    }

    public var id: UUID
    public var takes: [Take]
    public var chosen: UUID
    /// What lay on the track under the stretch before it was first recorded, as clips cut to it.
    public var under: [Clip]

    public init(id: UUID = UUID(), takes: [Take], chosen: UUID, under: [Clip]) {
        self.id = id
        self.takes = takes
        self.chosen = chosen
        self.under = under
    }

    public var start: Frame { takes.map(\.start).min() ?? 0 }
    public var end: Frame { takes.map(\.end).max() ?? 0 }
    public var chosenTake: Take? { takes.first { $0.id == chosen } }
}

public enum TakeError: Error, LocalizedError, Equatable, KeyedFailure {
    case noTrack, noTakes, noTake, locked
    public var errorDescription: String? { said.text }
    public var keyed: KeyedMessage? { said.keyed }
    private var said: Said {
        switch self {
        case .noTrack: Said("error.take.noTrack", "There's no track with that id.")
        case .noTakes: Said("error.take.noTakes", "There are no takes with that id on the track.")
        case .noTake: Said("error.take.noTake", "There's no take with that id among them.")
        case .locked: Said("error.take.locked", "The track is locked: its clips stay as they are.")
        }
    }
    /// The step API's reason.
    public var reason: String {
        switch self {
        case .noTrack, .noTakes, .noTake: "not_found"
        case .locked: "locked"
        }
    }
}

extension Project {
    /// A recorded take laid onto a track at `start` (recording; punch-in): the clips under its stretch are trimmed,
    /// split or taken off so nothing lies under it, and nothing else on the timeline moves (unlike Overdub, which
    /// ripples). What was under it comes back, as the clips were.
    @discardableResult
    public mutating func layOver(_ source: SourceRef, frames: Frame, at start: Frame, onTrack id: UUID, sourceStart: Frame = 0) throws -> [Clip] {
        guard let t = tracks.firstIndex(where: { $0.id == id }) else { throw ClipEditError.noClip }
        guard frames > 0 else { throw EditError.emptyRange }
        if !sources.contains(where: { $0.id == source.id }) { sources.append(source) }
        return place(Clip(sourceID: source.id, sourceStart: sourceStart, start: start, length: frames), onTrack: t)
    }

    /// A take recorded onto a track: laid over what is there, and kept. Over a stretch already recorded it joins
    /// those takes as the newest, chosen; elsewhere it starts takes of its own. Returns the take.
    @discardableResult
    public mutating func recordTake(_ source: SourceRef, frames: Frame, at start: Frame, onTrack id: UUID, sourceStart: Frame = 0) throws -> TakeGroup.Take {
        guard let t = tracks.firstIndex(where: { $0.id == id }) else { throw TakeError.noTrack }
        guard !tracks[t].locked else { throw TakeError.locked }
        guard frames > 0 else { throw EditError.emptyRange }
        let end = start + frames
        let g = tracks[t].takes.firstIndex { $0.start < end && $0.end > start }
        let takeSources = g.map { Set(tracks[t].takes[$0].takes.map(\.sourceID)) } ?? []
        let covered = try layOver(source, frames: frames, at: start, onTrack: id, sourceStart: sourceStart)
        // What was under the new take and isn't one of the takes: kept, where the stretch didn't already reach.
        let outside: [Range<Frame>]
        if let g {
            let old = tracks[t].takes[g]
            // Before and after the old stretch (either may be empty: a take inside it reaches neither).
            outside = [(start, min(end, old.start)), (max(start, old.end), end)].filter { $0.0 < $0.1 }.map { $0.0..<$0.1 }
        } else {
            outside = [start..<end]
        }
        let under = covered.filter { !takeSources.contains($0.sourceID) }.flatMap { c in outside.compactMap { c.cut(to: $0) } }
        if let g {
            let number = (tracks[t].takes[g].takes.map(\.number).max() ?? 0) + 1
            let take = TakeGroup.Take(sourceID: source.id, sourceStart: sourceStart, start: start, length: frames, number: number)
            tracks[t].takes[g].takes.append(take)
            tracks[t].takes[g].chosen = take.id
            tracks[t].takes[g].under += under
            return take
        }
        let take = TakeGroup.Take(sourceID: source.id, sourceStart: sourceStart, start: start, length: frames, number: 1)
        tracks[t].takes.append(TakeGroup(takes: [take], chosen: take.id, under: under))
        return take
    }

    /// Plays another take of a stretch: the stretch is laid again from what was under it, with the chosen take
    /// over that. If the take's clip was moved since (a ripple edit before it, a drag), the takes move with it.
    /// What was edited by hand inside the stretch gives way to the take.
    public mutating func chooseTake(_ take: UUID, of group: UUID, onTrack id: UUID) throws {
        let (t, g) = try takeLocation(group, onTrack: id)
        guard !tracks[t].locked else { throw TakeError.locked }
        guard tracks[t].takes[g].takes.contains(where: { $0.id == take }) else { throw TakeError.noTake }
        follow(t, g)
        tracks[t].takes[g].chosen = take
        rebuild(t, g)
    }

    /// Deletes one take (in the window only). The others stay; the newest left is chosen if this one was. When
    /// the last goes, the stretch gets back what was under it before it was recorded, and the takes are gone.
    public mutating func deleteTake(_ take: UUID, of group: UUID, onTrack id: UUID) throws {
        let (t, g) = try takeLocation(group, onTrack: id)
        guard !tracks[t].locked else { throw TakeError.locked }
        guard let i = tracks[t].takes[g].takes.firstIndex(where: { $0.id == take }) else { throw TakeError.noTake }
        follow(t, g)
        let gone = tracks[t].takes[g].takes.remove(at: i)
        if tracks[t].takes[g].takes.isEmpty {
            let stretch = gone.start..<gone.end
            let under = tracks[t].takes[g].under
            tracks[t].takes.remove(at: g)
            _ = place(nil, over: stretch, onTrack: t)
            for c in under { _ = place(c, onTrack: t) }
            return
        }
        if tracks[t].takes[g].chosen == take, let newest = tracks[t].takes[g].takes.max(by: { $0.number < $1.number }) {
            tracks[t].takes[g].chosen = newest.id
        }
        rebuild(t, g)
    }

    private func takeLocation(_ group: UUID, onTrack id: UUID) throws -> (Int, Int) {
        guard let t = tracks.firstIndex(where: { $0.id == id }) else { throw TakeError.noTrack }
        guard let g = tracks[t].takes.firstIndex(where: { $0.id == group }) else { throw TakeError.noTakes }
        return (t, g)
    }

    /// The chosen take's clip as the track has it now: where it was moved to since, the whole group goes with it.
    private mutating func follow(_ t: Int, _ g: Int) {
        guard let chosen = tracks[t].takes[g].chosenTake,
              let clip = tracks[t].clips.first(where: { $0.sourceID == chosen.sourceID }) else { return }
        let delta = (clip.start - clip.sourceStart) - (chosen.start - chosen.sourceStart)
        guard delta != 0 else { return }
        for k in tracks[t].takes[g].takes.indices { tracks[t].takes[g].takes[k].start += delta }
        for k in tracks[t].takes[g].under.indices { tracks[t].takes[g].under[k].start += delta }
    }

    private mutating func rebuild(_ t: Int, _ g: Int) {
        let group = tracks[t].takes[g]
        _ = place(nil, over: group.start..<group.end, onTrack: t)
        for c in group.under { _ = place(c, onTrack: t) }
        if let take = group.chosenTake { _ = place(take.clip, onTrack: t) }
    }

    /// Lays `clip` onto track `t`, cutting away what lies under it; returns what was there, as it was.
    private mutating func place(_ clip: Clip, onTrack t: Int) -> [Clip] { place(clip, over: clip.range, onTrack: t) }

    /// Clears `range` on track `t` (the clips there trimmed, split or taken off) and puts `clip` in it.
    private mutating func place(_ clip: Clip?, over range: Range<Frame>, onTrack t: Int) -> [Clip] {
        var kept: [Clip] = [], covered: [Clip] = []
        for c in tracks[t].clips {
            guard c.start < range.upperBound, c.end > range.lowerBound else { kept.append(c); continue }
            covered.append(c)
            if c.start < range.lowerBound {
                var left = c
                left.length = range.lowerBound - c.start
                left.fadeOut = min(left.fadeOut, left.length / 2)
                left.fadeIn = min(left.fadeIn, left.length - left.fadeOut)
                kept.append(left)
            }
            if c.end > range.upperBound {
                var right = c
                if c.start < range.lowerBound { right.id = UUID() }
                let cut = range.upperBound - c.start
                right.sourceStart += cut
                right.start = range.upperBound
                right.length = c.end - range.upperBound
                right.fadeIn = 0
                right.fadeOut = min(right.fadeOut, right.length)
                kept.append(right)
            }
        }
        if let clip { kept.append(clip) }
        tracks[t].clips = kept.sorted { $0.start < $1.start }
        return covered
    }
}

extension Clip {
    /// The part of this clip inside `range`, as a clip of its own (a new id; a fade only where its own edge is kept).
    func cut(to range: Range<Frame>) -> Clip? {
        let a = max(start, range.lowerBound), b = min(end, range.upperBound)
        guard a < b else { return nil }
        var c = self
        c.id = UUID()
        c.sourceStart += a - start
        c.start = a
        c.length = b - a
        c.fadeIn = a == start ? min(fadeIn, c.length) : 0
        c.fadeOut = b == end ? min(fadeOut, c.length - c.fadeIn) : 0
        return c
    }
}
