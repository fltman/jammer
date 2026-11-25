import Foundation
import Testing
@testable import JammerCore

/// A late result on top of edits made meanwhile (COMFORT 77): applied when they changed different things, a conflict
/// when they changed the same.
@Suite("Late results and edits made meanwhile")
struct ProjectMergeTests {
    func project() -> Project {
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 1, sampleRate: 48_000, dataOffset: 0, frames: 480_000)
        let a = SourceRef(name: "a", path: "/dev/null", info: info), b = SourceRef(name: "b", path: "/dev/null", info: info)
        var p = Project(sampleRate: 48_000, channels: 1, tracks: [
            Track(name: "Anna", clips: [Clip(sourceID: a.id, start: 0, length: 96_000), Clip(sourceID: a.id, sourceStart: 96_000, start: 144_000, length: 96_000)]),
            Track(name: "Erik", clips: [Clip(sourceID: b.id, start: 0, length: 240_000)]),
        ], sources: [a, b])
        p.markers = [Marker(position: 48_000, name: "Intro")]
        return p
    }

    func merged(_ o: ProjectMerge.Outcome) -> Project? { if case .merged(let p) = o { p } else { nil } }

    @Test("The document as it is, encoded and read back, is the same document")
    func roundTrip() throws {
        let p = project()
        let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        #expect(back == p)
    }

    @Test("Different things changed: the result goes on top, and nothing made meanwhile is undone")
    func onTop() throws {
        let base = project()
        var ours = base            // the run: Anna's first clip 3 dB down
        ours.tracks[0].clips[0].gainDB = -3
        var theirs = base          // meanwhile: Erik's level, the marker renamed, a new marker
        theirs.tracks[1].gainDB = -6
        theirs.markers[0].name = "Start"
        theirs.markers.append(Marker(position: 200_000, name: "End"))
        let m = try #require(merged(ProjectMerge.merge(base: base, ours: ours, theirs: theirs)))
        #expect(m.tracks[0].clips[0].gainDB == -3 && m.tracks[1].gainDB == -6)
        #expect(m.markers.map(\.name) == ["Start", "End"])
        // The same track, different clips, and the track's own name: still on top.
        var trimmed = base
        trimmed.tracks[0].clips[1].fadeIn = 4_800
        trimmed.tracks[0].name = "Anna B"
        let n = try #require(merged(ProjectMerge.merge(base: base, ours: ours, theirs: trimmed)))
        #expect(n.tracks[0].clips[0].gainDB == -3 && n.tracks[0].clips[1].fadeIn == 4_800 && n.tracks[0].name == "Anna B")
    }

    @Test("The same thing changed: a conflict, nothing applied")
    func conflict() {
        let base = project()
        var ours = base
        ours.tracks[0].clips[0].gainDB = -3
        var theirs = base
        theirs.tracks[0].clips[0].fadeIn = 4_800    // the same clip
        guard case .conflict(let at) = ProjectMerge.merge(base: base, ours: ours, theirs: theirs) else { Issue.record("merged"); return }
        #expect(at.hasPrefix("tracks["), "\(at)")
        var gone = base
        gone.tracks[0].clips.remove(at: 0)          // the clip the run changed was deleted meanwhile
        guard case .conflict = ProjectMerge.merge(base: base, ours: ours, theirs: gone) else { Issue.record("merged over a deleted clip"); return }
        var renamed = base, renamedToo = base
        renamed.tracks[1].name = "A"; renamedToo.tracks[1].name = "B"   // one field, two values
        guard case .conflict = ProjectMerge.merge(base: base, ours: renamed, theirs: renamedToo) else { Issue.record("merged two names"); return }
    }

    @Test("Order: a track moved by one side and a clip added by the other both stay")
    func order() throws {
        let base = project()
        var ours = base
        ours.tracks.swapAt(0, 1)
        var theirs = base
        theirs.tracks.append(Track(name: "Musik"))
        let m = try #require(merged(ProjectMerge.merge(base: base, ours: ours, theirs: theirs)))
        #expect(m.tracks.map(\.name) == ["Erik", "Anna", "Musik"])
    }

    @Test("A paid result (Overdub) whose place is untouched goes in; whose place changed meanwhile is kept as a muted take there")
    func paidTake() throws {
        let base = project()
        let track = base.tracks[0].id
        let range: Range<Frame> = 48_000..<72_000
        var moved = base
        moved.tracks[1].gainDB = -2                      // elsewhere: the place is untouched
        #expect(moved.unchanged(range, track: track, since: base))
        moved.tracks[0].clips[0].gainDB = -1             // the clip under the range itself
        #expect(!moved.unchanged(range, track: track, since: base))
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 1, sampleRate: 48_000, dataOffset: 0, frames: 24_000)
        let speech = SourceRef(name: "speech", path: "/dev/null", info: info)
        var kept = moved
        let id = kept.addTake(speech, at: range.lowerBound, name: "Overdub (take)")
        let take = try #require(kept.tracks.first { $0.id == id })
        #expect(take.isMuted && take.clips.first?.start == range.lowerBound && take.clips.first?.sourceID == speech.id)
        #expect(Array(kept.tracks.prefix(2)) == moved.tracks, "nothing made meanwhile is touched")
    }

    @Test("A long transcription: a transcript corrected meanwhile isn't written over; the others go in")
    func transcripts() {
        var base = project()
        let a = base.sources[0].id, b = base.sources[1].id
        base.transcripts = [SourceTranscript(sourceID: a, language: "sv", engine: "x", words: [Word(text: "hej", start: 0, end: 4_800)]),
                            SourceTranscript(sourceID: b, language: "sv", engine: "x", words: [Word(text: "då", start: 0, end: 4_800)])]
        var now = base
        now.transcripts[0].words[0].text = "Hej!"          // corrected by hand while the new one was made
        let fresh = [SourceTranscript(sourceID: a, language: "sv", engine: "paid", words: [Word(text: "hejsan", start: 0, end: 4_800)]),
                     SourceTranscript(sourceID: b, language: "sv", engine: "paid", words: [Word(text: "hej då", start: 0, end: 4_800)])]
        let held = now.setTranscripts(fresh, basedOn: base)
        #expect(held == [a])
        #expect(now.transcripts.first { $0.sourceID == a }?.words.first?.text == "Hej!")
        #expect(now.transcripts.first { $0.sourceID == b }?.engine == "paid")
    }
}
