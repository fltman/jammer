import Foundation

/// One clip changed by itself: its edges trimmed, its fades, its gain (the handles on the timeline and the agent's
/// `set_clip`), and one marker moved, renamed or resized (`set_marker`). Each is a value change on the project, so
/// a drag is one undo step: the window commits the end of the drag, not every move.
public enum ClipEditError: Error, LocalizedError, Equatable, KeyedFailure {
    case noClip
    case noMarker
    /// The new edge would lie over the clip next to it on the track.
    case overlaps
    /// The clip can't reach past the start or end of its file.
    case beyondSource
    /// A clip keeps at least one frame.
    case empty
    /// A clip can't start before the timeline does.
    case beforeStart

    public var errorDescription: String? {
        switch self {
        case .noClip: "There's no clip with that id."
        case .noMarker: "There's no marker with that id."
        case .overlaps: "The clip can't reach over the clip next to it."
        case .beyondSource: "The clip can't reach past the start or end of its file."
        case .empty: "A clip can't be shorter than one sample."
        case .beforeStart: "A clip can't start before the start of the timeline."
        }
    }

    public var keyed: KeyedMessage? {
        switch self {
        case .noClip: KeyedMessage("error.clip.noClip")
        case .noMarker: KeyedMessage("error.clip.noMarker")
        case .overlaps: KeyedMessage("error.clip.overlaps")
        case .beyondSource: KeyedMessage("error.clip.beyondSource")
        case .empty: KeyedMessage("error.clip.empty")
        case .beforeStart: KeyedMessage("error.clip.beforeStart")
        }
    }
}

extension Project {
    /// Where a clip is: its track and its index there.
    public func clipLocation(_ id: UUID) -> (track: Int, index: Int)? {
        for (t, track) in tracks.enumerated() {
            if let i = track.clips.firstIndex(where: { $0.id == id }) { return (t, i) }
        }
        return nil
    }

    /// Changes one clip. `start` and `end` trim its edges on the timeline (the sound under them stays where it is:
    /// trimming the start moves into the file, not the sound); fades are clamped so the two never overlap.
    public mutating func setClip(_ id: UUID, start: Frame? = nil, end: Frame? = nil, fadeIn: Frame? = nil, fadeOut: Frame? = nil,
                                 shape: FadeShape? = nil, gainDB: Double? = nil) throws {
        guard let (t, i) = clipLocation(id) else { throw ClipEditError.noClip }
        var c = tracks[t].clips[i]
        let others = tracks[t].clips.enumerated().filter { $0.offset != i }.map(\.element)
        if let start, start != c.start {
            guard start < c.end else { throw ClipEditError.empty }
            let delta = start - c.start
            guard c.sourceStart + delta >= 0 else { throw ClipEditError.beyondSource }
            guard !others.contains(where: { $0.start < c.start && $0.end > start }) else { throw ClipEditError.overlaps }
            c.sourceStart += delta
            c.length -= delta
            c.start = start
        }
        if let end, end != c.end {
            guard end > c.start else { throw ClipEditError.empty }
            if let frames = source(c.sourceID)?.info.frames, c.sourceStart + (end - c.start) > Frame(frames) { throw ClipEditError.beyondSource }
            guard !others.contains(where: { $0.end > c.end && $0.start < end }) else { throw ClipEditError.overlaps }
            c.length = end - c.start
        }
        if let fadeIn { c.fadeIn = max(0, min(fadeIn, c.length)) }
        if let fadeOut { c.fadeOut = max(0, min(fadeOut, c.length)) }
        // The fades share the clip: the one changed now wins, the other gives way.
        if c.fadeIn + c.fadeOut > c.length {
            if fadeIn != nil { c.fadeOut = c.length - c.fadeIn } else { c.fadeIn = c.length - c.fadeOut }
        }
        c.fadeIn = min(c.fadeIn, c.length)
        c.fadeOut = min(c.fadeOut, c.length - c.fadeIn)
        if let shape { c.fadeShape = shape }
        if let gainDB { c.gainDB = gainDB }
        tracks[t].clips[i] = c
    }

    /// Moves clips on the timeline, sound and all (their transcripts and fades go with them): to `start`, or by
    /// `delta`. Refused, with nothing moved, when one would start before the timeline or lie over a clip on its track
    /// that isn't moved with it.
    public mutating func moveClips(_ ids: Set<UUID>, by delta: Frame) throws {
        guard delta != 0 else { return }
        var p = self
        for id in ids { guard p.clipLocation(id) != nil else { throw ClipEditError.noClip } }
        for t in p.tracks.indices {
            let moving = p.tracks[t].clips.filter { ids.contains($0.id) }
            guard !moving.isEmpty else { continue }
            let still = p.tracks[t].clips.filter { !ids.contains($0.id) }
            for c in moving {
                let start = c.start + delta
                guard start >= 0 else { throw ClipEditError.beforeStart }
                guard !still.contains(where: { $0.start < start + c.length && $0.end > start }) else { throw ClipEditError.overlaps }
            }
            for i in p.tracks[t].clips.indices where ids.contains(p.tracks[t].clips[i].id) { p.tracks[t].clips[i].start += delta }
            p.tracks[t].clips.sort { $0.start < $1.start }
        }
        self = p
    }

    /// Moves, renames or resizes one marker; the list stays in time order.
    public mutating func setMarker(_ id: UUID, position: Frame? = nil, name: String? = nil, length: Frame? = nil) throws {
        guard let i = markers.firstIndex(where: { $0.id == id }) else { throw ClipEditError.noMarker }
        if let position { markers[i].position = max(0, position) }
        if let name { markers[i].name = name }
        if let length { markers[i].length = max(0, length) }
        markers.sort { $0.position < $1.position }
    }

    /// Removes one marker by its id.
    public mutating func removeMarker(_ id: UUID) throws {
        guard markers.contains(where: { $0.id == id }) else { throw ClipEditError.noMarker }
        markers.removeAll { $0.id == id }
    }
}
