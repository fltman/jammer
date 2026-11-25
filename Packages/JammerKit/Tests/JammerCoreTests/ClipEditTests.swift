import Foundation
import Testing
@testable import JammerCore

/// One clip and one marker changed by themselves (the timeline's handles and the agent's set_clip / set_marker).
@Suite("Clip and marker edits")
struct ClipEditTests {
    func project() -> Project {
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 1, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: 480_000, chunks: [], bext: nil, ixml: nil, markers: [])
        var p = Project(source: SourceRef(name: "a", path: "/dev/null", info: info))
        // Two clips on the track: 0–4 s (file 0–4 s) and 6–10 s (file 6–10 s).
        p.split(at: 192_000)
        p.split(at: 288_000)
        p.tracks[0].clips.remove(at: 1)
        return p
    }

    @Test("The Split tool splits only the track it is given; without tracks, every track under the point")
    func splitOnTracks() {
        var p = project()
        var second = p.tracks[0]
        second.id = UUID()
        p.tracks.append(second)
        p.split(at: 96_000, onTracks: [second.id])
        #expect(p.tracks[0].clips.count == 2 && p.tracks[1].clips.count == 3)
        #expect(p.tracks[1].clips[0].end == 96_000 && p.tracks[1].clips[1].start == 96_000 && p.tracks[1].clips[1].sourceStart == 96_000)
        p.split(at: 360_000)
        #expect(p.tracks[0].clips.count == 3 && p.tracks[1].clips.count == 4)
        // A point between clips splits nothing.
        p.split(at: 240_000)
        #expect(p.tracks[0].clips.count == 3)
    }

    @Test("Trimming moves the edge into the file, never past its start or end, and never over the next clip")
    func trim() throws {
        var p = project()
        let a = p.tracks[0].clips[0].id, b = p.tracks[0].clips[1].id
        try p.setClip(a, start: 48_000)
        #expect(p.tracks[0].clips[0].start == 48_000 && p.tracks[0].clips[0].sourceStart == 48_000 && p.tracks[0].clips[0].length == 144_000)
        try p.setClip(a, start: 0)
        #expect(throws: ClipEditError.beyondSource) { try p.setClip(a, start: -1) }
        #expect(throws: ClipEditError.overlaps) { try p.setClip(a, end: 300_000) }
        try p.setClip(a, end: 288_000)
        #expect(p.tracks[0].clips[0].end == 288_000)
        #expect(throws: ClipEditError.beyondSource) { try p.setClip(b, end: 500_000) }
        #expect(throws: ClipEditError.empty) { try p.setClip(b, start: p.tracks[0].clips[1].end) }
        #expect(throws: ClipEditError.noClip) { try p.setClip(UUID(), start: 0) }
    }

    @Test("Fades are set by length, 0 removes one, and the two never overlap: the one changed now wins")
    func fades() throws {
        var p = project()
        let a = p.tracks[0].clips[0].id
        try p.setClip(a, fadeIn: 48_000, fadeOut: 48_000, shape: .linear)
        #expect(p.tracks[0].clips[0].fadeIn == 48_000 && p.tracks[0].clips[0].fadeOut == 48_000 && p.tracks[0].clips[0].fadeShape == .linear)
        try p.setClip(a, fadeIn: 180_000)
        #expect(p.tracks[0].clips[0].fadeIn == 180_000 && p.tracks[0].clips[0].fadeOut == 12_000)
        try p.setClip(a, fadeIn: 0)
        #expect(p.tracks[0].clips[0].fadeIn == 0)
        try p.setClip(a, gainDB: -3)
        #expect(p.tracks[0].clips[0].gainDB == -3)
    }

    @Test("A marker moves, is renamed and removed by its id; the list stays in time order")
    func markers() throws {
        var p = project()
        let m1 = p.addMarker(at: 96_000, name: "A"), m2 = p.addMarker(at: 192_000, name: "B")
        try p.setMarker(m1.id, position: 300_000, name: "A2")
        #expect(p.markers.map(\.name) == ["B", "A2"] && p.markers[1].position == 300_000)
        try p.removeMarker(m2.id)
        #expect(p.markers.map(\.name) == ["A2"])
        #expect(throws: ClipEditError.noMarker) { try p.setMarker(UUID(), name: "x") }
    }
}

@Suite("Moving clips")
struct MoveClipTests {
    func project() -> Project {
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 1, sampleRate: 48_000, dataOffset: 0, frames: 480_000)
        let s = SourceRef(name: "a", path: "/dev/null", info: info)
        return Project(sampleRate: 48_000, channels: 1, tracks: [
            Track(name: "A", clips: [Clip(sourceID: s.id, start: 0, length: 48_000), Clip(sourceID: s.id, sourceStart: 48_000, start: 96_000, length: 48_000)]),
        ], sources: [s])
    }

    @Test("A clip moves with its sound; several move together; the order on the track stays by time")
    func moves() throws {
        var p = project()
        let a = p.tracks[0].clips[0].id, b = p.tracks[0].clips[1].id
        try p.moveClips([b], by: -24_000)
        #expect(p.tracks[0].clips[1].start == 72_000 && p.tracks[0].clips[1].sourceStart == 48_000)
        try p.moveClips([a, b], by: 480)
        #expect(p.tracks[0].clips.map(\.start) == [480, 72_480])
    }

    @Test("Refused, nothing moved: before 0, over a clip that isn't moved, an unknown clip")
    func refuses() {
        var p = project()
        let before = p
        let a = p.tracks[0].clips[0].id, b = p.tracks[0].clips[1].id
        #expect(throws: ClipEditError.beforeStart) { try p.moveClips([a], by: -1) }
        #expect(throws: ClipEditError.overlaps) { try p.moveClips([b], by: -48_001) }
        #expect(throws: ClipEditError.noClip) { try p.moveClips([UUID()], by: 10) }
        #expect(p == before)
    }
}
