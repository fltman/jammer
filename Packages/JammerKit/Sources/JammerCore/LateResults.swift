import Foundation

/// Late results that took long or were paid for, laid onto edits made meanwhile (COMFORT 59 and 77): put in where
/// nothing they replace has changed, and kept otherwise, never thrown away.
extension Project {
    /// The clips of a track over `range` as they were in `before` (by id and value): the place a result goes is untouched.
    public func unchanged(_ range: Range<Frame>, track: UUID, since before: Project) -> Bool {
        func there(_ p: Project) -> [Clip]? {
            p.tracks.first { $0.id == track }.map { $0.clips.filter { $0.start < range.upperBound && $0.end > range.lowerBound } }
        }
        guard let now = there(self), let then = there(before) else { return false }
        return now == then
    }

    /// A paid result whose place changed meanwhile, kept as a take: on a new track, muted, at the same place, so it is
    /// there to listen to and use, and nothing made meanwhile is touched. Returns the track's id.
    @discardableResult
    public mutating func addTake(_ source: SourceRef, at start: Frame, name: String) -> UUID {
        var t = addTrack(source: source, name: name, start: start)
        t.isMuted = true
        if let i = tracks.firstIndex(where: { $0.id == t.id }) { tracks[i].isMuted = true }
        return t.id
    }

    /// New transcripts laid onto the document as it is: each goes in unless its source's transcript was changed since
    /// `base` (a word corrected by hand meanwhile), which is kept. Returns the sources whose new transcript wasn't put in.
    @discardableResult
    public mutating func setTranscripts(_ ts: [SourceTranscript], basedOn base: Project) -> [UUID] {
        var held: [UUID] = []
        for t in ts where source(t.sourceID) != nil {
            let then = base.transcripts.first { $0.sourceID == t.sourceID }, now = transcripts.first { $0.sourceID == t.sourceID }
            if then != now { held.append(t.sourceID); continue }
            setTranscript(t)
        }
        return held
    }
}
