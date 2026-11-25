import Foundation
import Testing
@testable import JammerCore

@Suite("A recorded take laid onto a track")
struct LayOverTests {
    func project() -> (Project, UUID) {
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 1, sampleRate: 48_000, dataOffset: 0, frames: 480_000)
        let s = SourceRef(name: "old", path: "/dev/null", info: info)
        let t = Track(name: "Voice", clips: [Clip(sourceID: s.id, start: 0, length: 240_000)])
        let other = Track(name: "Music", clips: [Clip(sourceID: s.id, start: 0, length: 480_000)])
        return (Project(sampleRate: 48_000, channels: 1, tracks: [t, other], sources: [s]), t.id)
    }
    func take(_ frames: Frame) -> SourceRef {
        SourceRef(name: "take", path: "/dev/null", info: AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 1, sampleRate: 48_000, dataOffset: 0, frames: Int64(frames)))
    }

    @Test("In the middle of a clip: the clip is split around the take, its sound where it was; other tracks and the length untouched")
    func middle() throws {
        var (p, id) = project()
        let before = p
        let covered = try p.layOver(take(48_000), frames: 48_000, at: 96_000, onTrack: id)
        let clips = p.tracks[0].clips
        #expect(clips.map(\.start) == [0, 96_000, 144_000] && clips.map(\.length) == [96_000, 48_000, 96_000])
        #expect(clips[2].sourceStart == 144_000, "the sound after the take is where it was")
        #expect(p.tracks[1] == before.tracks[1] && covered.count == 1)
    }

    @Test("Past the clip's end, over the start of the next, or onto an empty stretch: only what lies under the take gives way")
    func edges() throws {
        var (p, id) = project()
        try p.layOver(take(96_000), frames: 96_000, at: 200_000, onTrack: id)
        #expect(p.tracks[0].clips.map(\.start) == [0, 200_000] && p.tracks[0].clips[0].length == 200_000)
        var (q, qid) = project()
        try q.layOver(take(48_000), frames: 48_000, at: 300_000, onTrack: qid)
        #expect(q.tracks[0].clips.count == 2 && q.tracks[0].clips[0].length == 240_000)
        #expect(throws: (any Error).self) { try q.layOver(take(0), frames: 0, at: 0, onTrack: qid) }
    }
}

@Suite("Takes: every one kept, one chosen")
struct TakeTests {
    let base = LayOverTests()
    /// Voice: one clip of the old sound 0–5 s; a take of 1 s recorded at 2 s, then a second over the same place.
    func twoTakes() throws -> (Project, UUID, TakeGroup.Take, TakeGroup.Take, SourceRef, SourceRef) {
        var (p, id) = base.project()
        let a = base.take(48_000), b = base.take(96_000)
        let first = try p.recordTake(a, frames: 48_000, at: 96_000, onTrack: id)
        let second = try p.recordTake(b, frames: 48_000, at: 96_000, onTrack: id, sourceStart: 48_000)
        return (p, id, first, second, a, b)
    }

    @Test("A second take over the first joins it, numbered and chosen; the old sound around them is untouched")
    func joins() throws {
        let (p, _, first, second, _, b) = try twoTakes()
        let t = p.tracks[0]
        #expect(t.takes.count == 1 && t.takes[0].takes.map(\.number) == [1, 2] && t.takes[0].chosen == second.id && first.number == 1)
        #expect(t.clips.map(\.start) == [0, 96_000, 144_000] && t.clips[1].sourceID == b.id && t.clips[1].sourceStart == 48_000,
                "the second plays, its pre-roll skipped")
        #expect(t.takes[0].under.count == 1 && t.takes[0].under[0].start == 96_000 && t.takes[0].under[0].length == 48_000,
                "what was under the stretch is kept once, not the first take")
    }

    @Test("Choosing the first plays it again; choosing back and forth gives the same clips; another track is untouched")
    func choose() throws {
        var (p, id, first, second, a, _) = try twoTakes()
        let other = p.tracks[1]
        let g = p.tracks[0].takes[0].id
        try p.chooseTake(first.id, of: g, onTrack: id)
        #expect(p.tracks[0].clips.map(\.sourceID)[1] == a.id && p.tracks[0].takes[0].chosen == first.id)
        try p.chooseTake(second.id, of: g, onTrack: id)
        let once = p.tracks[0].clips.map { [$0.start, $0.length, $0.sourceStart] }
        try p.chooseTake(first.id, of: g, onTrack: id)
        try p.chooseTake(second.id, of: g, onTrack: id)
        #expect(p.tracks[0].clips.map { [$0.start, $0.length, $0.sourceStart] } == once && p.tracks[1] == other)
        #expect(throws: TakeError.noTake) { try p.chooseTake(UUID(), of: g, onTrack: id) }
        #expect(throws: TakeError.noTakes) { try p.chooseTake(first.id, of: UUID(), onTrack: id) }
    }

    @Test("A shorter take chosen leaves the old sound around it, from what was under the stretch")
    func shorter() throws {
        var (p, id) = base.project()
        let long = try p.recordTake(base.take(96_000), frames: 96_000, at: 96_000, onTrack: id)
        _ = try p.recordTake(base.take(24_000), frames: 24_000, at: 120_000, onTrack: id)
        let g = p.tracks[0].takes[0]
        #expect(g.takes.count == 2 && g.start == 96_000 && g.end == 192_000)
        let shortID = g.takes[1].id
        try p.chooseTake(long.id, of: g.id, onTrack: id)
        try p.chooseTake(shortID, of: g.id, onTrack: id)
        let c = p.tracks[0].clips
        #expect(c.map(\.start) == [0, 96_000, 120_000, 144_000, 192_000] && c.map(\.length) == [96_000, 24_000, 24_000, 48_000, 48_000])
        #expect(c[1].sourceID == p.sources[0].id && c[1].sourceStart == 96_000, "the old sound before the take, where it was")
        #expect(c[3].sourceStart == 144_000, "and after it")
    }

    @Test("Deleting the chosen take chooses the newest left; deleting the last gives the stretch back as it was")
    func delete() throws {
        var (p, id, first, second, a, _) = try twoTakes()
        let g = p.tracks[0].takes[0].id
        try p.deleteTake(second.id, of: g, onTrack: id)
        #expect(p.tracks[0].takes[0].takes.map(\.number) == [1] && p.tracks[0].takes[0].chosen == first.id && p.tracks[0].clips[1].sourceID == a.id)
        try p.deleteTake(first.id, of: g, onTrack: id)
        #expect(p.tracks[0].takes.isEmpty)
        #expect(p.tracks[0].clips.map { [$0.start, $0.length, $0.sourceStart] } == [[0, 96_000, 0], [96_000, 48_000, 96_000], [144_000, 96_000, 144_000]]
                && p.tracks[0].clips.allSatisfy { $0.sourceID == p.sources[0].id }, "the old sound, in three pieces where it was")
    }

    @Test("Moved since (a ripple edit before it): the takes go with the chosen take's clip")
    func follows() throws {
        var (p, id, first, _, a, _) = try twoTakes()
        let g = p.tracks[0].takes[0].id
        try p.moveClips(Set(p.tracks[0].clips.map(\.id)), by: 48_000)
        try p.chooseTake(first.id, of: g, onTrack: id)
        let c = p.tracks[0].clips
        #expect(c.first { $0.sourceID == a.id }?.start == 144_000 && p.tracks[0].takes[0].start == 144_000)
        #expect(c.map(\.start) == [48_000, 144_000, 192_000], "nothing left behind where the stretch was")
    }

    @Test("Takes on a locked track are refused; takes are saved as format 8 and read back; a document without keeps its format")
    func lockedAndSaved() throws {
        var (p, id, first, _, _, _) = try twoTakes()
        let g = p.tracks[0].takes[0].id
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Project.self, from: data)
        #expect(back.tracks[0].takes == p.tracks[0].takes)
        #expect(String(decoding: data, as: UTF8.self).contains("\"formatVersion\":8"))
        let plain = try JSONEncoder().encode(base.project().0)
        #expect(!String(decoding: plain, as: UTF8.self).contains("takes") && !String(decoding: plain, as: UTF8.self).contains("documentID"))
        p.tracks[0].locked = true
        #expect(throws: TakeError.locked) { try p.chooseTake(first.id, of: g, onTrack: id) }
        #expect(throws: TakeError.locked) { try p.recordTake(base.take(10), frames: 10, at: 0, onTrack: id) }
    }
}
