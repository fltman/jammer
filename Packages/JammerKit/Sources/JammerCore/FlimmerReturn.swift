import Foundation

/// The way back to Flimmer, first half: what would be sent. Compares the document with how
/// its clips and tracks came in (`Origin.snapshot`) and sorts every clip into unchanged,
/// changed (a new take), new, or missing. Pure: nothing is rendered or sent here.
public enum FlimmerReturn {
    public struct Take: Sendable, Equatable {
        public var clipId: String
        public var trackId: String?
        public var linkedShotId: String?
        /// From the first piece's start to the last piece's end; gaps between pieces are silence.
        public var range: Range<Frame>
        public var pieces: Int
        /// Frames the start has moved since import (0: in place).
        public var movedBy: Frame
        /// The pieces are no longer on the track the clip came in on. In v1 the clip stays on
        /// its track in Flimmer; the take is still rendered from where the sound is now.
        public var changedTrack: Bool
        /// The Jämmer tracks the pieces are on.
        public var tracks: [UUID]
    }

    public struct NewClip: Sendable, Equatable {
        public var clip: UUID
        public var track: UUID
        /// The Flimmer track it would land on; nil: a new track named like Jämmer's.
        public var trackId: String?
        public var trackName: String
        public var range: Range<Frame>
    }

    public struct TrackChange: Sendable, Equatable {
        public var trackId: String
        public var name: String
        public var gainDB: Double
        public var muted: Bool
    }

    public struct Plan: Sendable, Equatable {
        public var takes: [Take] = []
        public var unchanged: [String] = []
        public var new: [NewClip] = []
        /// Clips that came in and are no longer in the document. Nothing happens to them in Flimmer.
        public var missing: [String] = []
        public var tracks: [TrackChange] = []
        /// Shot clips whose own sound was changed here. It can't go back as a take (Flimmer has
        /// no audio clip for it).
        public var videoChanged: [String] = []
        /// The document is shorter or longer than it came in: what follows a cut has moved
        /// against the picture.
        public var lengthChangedBy: Frame = 0
        public var isEmpty: Bool { takes.isEmpty && new.isEmpty && tracks.isEmpty }
        public init() {}
    }

    public enum PlanError: Error, LocalizedError, Equatable, KeyedFailure {
        case notFromFlimmer
        static let said = Said("error.flimmer.notFromFlimmer", "This document didn't come from Flimmer, so there is nothing to send back to.")
        public var errorDescription: String? { Self.said.text }
        public var keyed: KeyedMessage? { Self.said.keyed }
    }

    public static func plan(_ project: Project) throws(PlanError) -> Plan {
        guard let record = project.imported, record.app == "flimmer" else { throw .notFromFlimmer }
        var plan = Plan()
        plan.lengthChangedBy = project.length - record.length
        struct Piece { var clip: Clip; var track: Track }
        var byClip: [String: [Piece]] = [:], order: [String] = []
        for t in project.tracks {
            for c in t.clips {
                guard let o = c.origin, o.app == "flimmer", let id = o.clipId else {
                    plan.new.append(NewClip(clip: c.id, track: t.id, trackId: t.origin?.trackId, trackName: t.name, range: c.start..<c.end))
                    continue
                }
                if byClip[id] == nil { order.append(id) }
                byClip[id, default: []].append(Piece(clip: c, track: t))
            }
            if let o = t.origin, let id = o.trackId, let s = o.snapshot, s.gainDB != t.gainDB || (s.muted ?? false) != t.isMuted {
                plan.tracks.append(TrackChange(trackId: id, name: t.name, gainDB: t.gainDB, muted: t.isMuted))
            }
        }
        for id in order {
            let pieces = byClip[id]!.sorted { $0.clip.start < $1.clip.start }
            let first = pieces[0], o = first.clip.origin!
            var same = false
            if pieces.count == 1, let s = o.snapshot {
                let c = first.clip
                same = c.start == s.start && c.sourceStart == s.sourceStart && c.length == s.length && c.gainDB == s.gainDB
                    && c.fadeIn == s.fadeIn && c.fadeOut == s.fadeOut && c.sourceID == s.sourceID
                    // Plugins on the track change the sound without changing the clip.
                    && first.track.inserts.isEmpty
                    && (o.videoAudio == true || first.track.origin?.trackId == o.trackId)
            }
            if o.videoAudio == true {
                if !same { plan.videoChanged.append(id) }
                continue
            }
            if same { plan.unchanged.append(id); continue }
            let start = first.clip.start, end = pieces.map(\.clip.end).max()!
            plan.takes.append(Take(clipId: id, trackId: o.trackId, linkedShotId: o.linkedShotId, range: start..<end, pieces: pieces.count,
                                   movedBy: start - (o.snapshot?.start ?? start),
                                   changedTrack: pieces.contains { $0.track.origin?.trackId != o.trackId },
                                   tracks: Array(Set(pieces.map(\.track.id)))))
        }
        plan.missing = record.clipIds.filter { byClip[$0] == nil }
        return plan
    }

    // MARK: What each file is rendered from

    /// The document reduced to one take's sound: only the pieces of that clip, on their tracks
    /// with their plugins. The track's level and mute aren't in the file (they go back as
    /// values), except what a track has above 0 dB, which Flimmer's 0…1 volume can't hold.
    public static func soloProject(_ project: Project, clipId: String) -> Project {
        solo(project) { $0.origin?.clipId == clipId && $0.origin?.videoAudio != true }
    }

    /// The same for a clip that was added here.
    public static func soloProject(_ project: Project, clip: UUID) -> Project { solo(project) { $0.id == clip } }

    static func solo(_ project: Project, keep: (Clip) -> Bool) -> Project {
        var p = project
        p.markers = []
        for i in p.tracks.indices {
            p.tracks[i].clips.removeAll { !keep($0) }
            p.tracks[i].isMuted = false
            p.tracks[i].gainDB = max(0, p.tracks[i].gainDB)
        }
        return p
    }

    /// The whole mix as Flimmer should get it: everything as it sounds here, without the
    /// video clips' own sound, which Flimmer plays itself.
    public static func mixProject(_ project: Project) -> Project {
        var p = project
        p.markers = []
        for i in p.tracks.indices { p.tracks[i].clips.removeAll { $0.origin?.videoAudio == true } }
        return p
    }
}
