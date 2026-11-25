import Foundation
import Testing
@testable import JammerAgent
@testable import JammerCore

/// The Track menu's whole-track edits and the lock (the comfort block, step 4).
@Suite("Tracks: delete, duplicate, move and lock")
struct TrackEditTests {
    func state(tracks: Int = 3) -> EditState {
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 1, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: 480_000, chunks: [], bext: nil, ixml: nil, markers: [])
        var p = Project(source: SourceRef(name: "a", path: "/dev/null", info: info))
        for i in 1..<tracks {
            var t = p.tracks[0]
            t.id = UUID()
            t.name = "T\(i)"
            for c in t.clips.indices { t.clips[c].id = UUID() }
            p.tracks.append(t)
        }
        return EditState(project: p)
    }
    let silent: StepRunner.Measure = { _, _ in LoudnessResult(integrated: nil, range: nil, maxMomentary: nil, maxShortTerm: nil, samplePeak: 0, truePeak: 0, duration: 0) }
    func run(_ s: inout EditState, _ op: String, _ params: [String: JSONValue]) -> StepResult {
        StepRunner.run([Step(op: op, params: params)], on: &s, measure: silent)[0]
    }

    @Test("Delete removes the track and its automation; the last track can't go")
    func remove() throws {
        var s = state()
        let id = s.project.tracks[1].id
        s.project.automation.append(AutomationLane(strip: id, param: .gain, points: [AutomationPoint(frame: 0, value: -6)]))
        #expect(run(&s, "remove_track", ["track": .string(id.uuidString)]).status == .done)
        #expect(s.project.tracks.count == 2 && !s.project.tracks.contains { $0.id == id } && s.project.automation.isEmpty)
        var one = state(tracks: 1)
        let r = run(&one, "remove_track", ["track": .string(one.project.tracks[0].id.uuidString)])
        #expect(r.status == .failed && r.reason == "last_track" && one.project.tracks.count == 1)
    }

    @Test("Duplicate puts a copy under the track with ids of its own and the same audio, and says the copy's id")
    func duplicate() throws {
        var s = state()
        let orig = s.project.tracks[0]
        let r = run(&s, "duplicate_track", ["track": .string(orig.id.uuidString), "name": .string("Copy")])
        let copy = s.project.tracks[1]
        #expect(r.status == .done && r.ids["track"] == copy.id.uuidString)
        #expect(copy.name == "Copy" && copy.id != orig.id && s.project.tracks.count == 4)
        #expect(copy.clips.map(\.sourceID) == orig.clips.map(\.sourceID) && copy.clips.map(\.start) == orig.clips.map(\.start))
        #expect(Set(copy.clips.map(\.id)).isDisjoint(with: orig.clips.map(\.id)))
    }

    @Test("Move by index or by places, clamped to the ends")
    func move() {
        var s = state()
        let ids = s.project.tracks.map(\.id)
        #expect(run(&s, "move_track", ["track": .string(ids[0].uuidString), "by": .number(1)]).status == .done)
        #expect(s.project.tracks.map(\.id) == [ids[1], ids[0], ids[2]])
        _ = run(&s, "move_track", ["track": .string(ids[2].uuidString), "index": .number(0)])
        #expect(s.project.tracks.map(\.id) == [ids[2], ids[1], ids[0]])
        _ = run(&s, "move_track", ["track": .string(ids[2].uuidString), "by": .number(-5)])
        #expect(s.project.tracks.first?.id == ids[2])
        #expect(run(&s, "move_track", ["track": .string(ids[0].uuidString)]).status == .failed)
    }

    @Test("A locked track keeps its clips: a cut across all tracks, a delete of the track or a split on it changes nothing and names the track; level and mute stay free")
    func lock() throws {
        var s = state()
        let t = s.project.tracks[1]
        #expect(run(&s, "set_track", ["track": .string(t.id.uuidString), "locked": .bool(true)]).status == .done)
        let before = s.project
        let cut = run(&s, "delete", ["start": .number(1), "end": .number(2)])
        #expect(cut.status == .failed && cut.reason == "locked" && cut.keyed == KeyedMessage("error.track.locked", ["T1"]))
        #expect(s.project == before)
        #expect(run(&s, "remove_track", ["track": .string(t.id.uuidString)]).reason == "locked")
        #expect(run(&s, "split", ["at": .number(1), "tracks": .array([.string(t.id.uuidString)])]).reason == "locked")
        #expect(run(&s, "set_track", ["track": .string(t.id.uuidString), "gainDB": .number(-3), "muted": .bool(true)]).status == .done)
        // Another track's own split is free.
        #expect(run(&s, "split", ["at": .number(1), "tracks": .array([.string(s.project.tracks[0].id.uuidString)])]).status == .done)
        // Unlocked, the cut goes through.
        _ = run(&s, "set_track", ["track": .string(t.id.uuidString), "locked": .bool(false)])
        #expect(run(&s, "delete", ["start": .number(1), "end": .number(2)]).status == .done)
    }

    @Test("The lock is kept in the file, and a file without locks is written as before")
    func lockInFile() throws {
        var t = Track(name: "A")
        let plain = String(decoding: try JSONEncoder().encode(t), as: UTF8.self)
        #expect(!plain.contains("locked"))
        t.locked = true
        let back = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(t))
        #expect(back.locked)
        #expect(try !JSONDecoder().decode(Track.self, from: Data(plain.utf8)).locked)
    }
}
