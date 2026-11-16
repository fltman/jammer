import Foundation
import Testing
@testable import JammerCore

@Suite("Mixer: VCA groups")
struct VCATests {
    @Test("A VCA at 0 dB changes nothing; its level is added to each member's fader and its mute mutes them; the others are untouched")
    func level() throws {
        var (p, pool) = MixerTests.document()
        let plain = MixerTests.render(p, pool)
        let v = try p.addVCA(name: "Voices")
        try p.setMember(p.tracks[0].id, vca: v.id)
        try p.setMember(p.tracks[1].id, vca: v.id)
        #expect(p.usesMixer)
        // At 0 dB: the same samples, bit for bit.
        #expect(MixerTests.render(p, pool) == plain)
        // −6 dB on the group is −6 dB on its two members and nothing on the third.
        try p.setVCA(v.id, gainDB: -6)
        var by = p
        by.vcas = []
        for t in 0..<2 { by.tracks[t].vca = nil; by.tracks[t].gainDB = -6 }
        #expect(MixerTests.render(p, pool) == MixerTests.render(by, pool))
        // A member with a level of its own keeps it under the group's.
        p.tracks[0].gainDB = 3
        by.tracks[0].gainDB = -3
        #expect(MixerTests.render(p, pool) == MixerTests.render(by, pool))
        // Muted: the members are silent, the third track is all there is.
        try p.setVCA(v.id, muted: true)
        var third = p
        third.vcas = []
        third.tracks[0].vca = nil; third.tracks[1].vca = nil
        third.tracks[0].isMuted = true; third.tracks[1].isMuted = true
        #expect(MixerTests.render(p, pool) == MixerTests.render(third, pool))
        // Saved and opened: the same project.
        #expect(try JSONDecoder().decode(Project.self, from: try JSONEncoder().encode(p)) == p)
        // A track rendered by itself (a bounce, an analysis) has no VCA.
        var solo = p
        solo.withoutMixer()
        #expect(solo.vcas.isEmpty && solo.tracks.allSatisfy { $0.vca == nil })
    }

    @Test("A bus in a VCA; a send before the fader doesn't follow the VCA, one after it does")
    func busesAndSends() throws {
        var (p, pool) = MixerTests.document()
        let bus = try p.addBus(name: "Room"), other = try p.addBus(name: "FX")
        try p.setTrackRoute(p.tracks[0].id, output: .some(bus.id))
        let v = try p.addVCA(name: "Group")
        try p.setMember(bus.id, vca: v.id)
        try p.setVCA(v.id, gainDB: -12)
        var by = p
        by.vcas = []
        by.buses[0].vca = nil
        by.buses[0].gainDB = -12
        #expect(MixerTests.render(p, pool) == MixerTests.render(by, pool))
        // Track 1 in the group, sending to FX before and after the fader.
        for pre in [true, false] {
            var q = p
            try q.setMember(q.tracks[1].id, vca: v.id)
            try q.setSend(from: q.tracks[1].id, to: other.id, gainDB: 0, pre: pre)
            var want = q
            want.tracks[1].vca = nil
            want.tracks[1].gainDB = -12       // the fader as it is heard; a pre-fader send ignores it either way
            #expect(MixerTests.render(q, pool) == MixerTests.render(want, pool), "pre \(pre)")
        }
    }

    @Test("Removing a VCA leaves the sound as it was; refusals; a strip is in one group at most")
    func removing() throws {
        var (p, pool) = MixerTests.document()
        let v = try p.addVCA(name: "Voices"), w = try p.addVCA(name: "Others")
        try p.setMember(p.tracks[0].id, vca: v.id)
        try p.setMember(p.tracks[1].id, vca: v.id)
        p.tracks[1].gainDB = 2.5
        try p.setVCA(v.id, gainDB: -4.5)
        let before = MixerTests.render(p, pool)
        var q = p
        try q.removeVCA(v.id)
        #expect(q.vcas.map(\.name) == ["Others"] && q.tracks[0].gainDB == -4.5 && q.tracks[1].gainDB == -2 && q.tracks[0].vca == nil)
        #expect(MixerTests.render(q, pool) == before)
        // A muted group leaves its members muted.
        try p.setVCA(v.id, muted: true)
        try p.removeVCA(v.id)
        #expect(p.tracks[0].isMuted && p.tracks[1].isMuted && !p.tracks[2].isMuted)
        // Moving to another group leaves the first.
        try p.setMember(p.tracks[2].id, vca: w.id)
        #expect(p.tracks[2].vca == w.id)
        let kept = p
        #expect(throws: Mixer.Failure.self) { try p.setMember(p.tracks[0].id, vca: UUID()) }
        #expect(throws: Mixer.Failure.self) { try p.setMember(UUID(), vca: w.id) }
        #expect(throws: Mixer.Failure.self) { try p.setVCA(w.id, gainDB: 99) }
        #expect(throws: Mixer.Failure.self) { try p.setVCA(UUID(), gainDB: 0) }
        #expect(throws: Mixer.Failure.self) { try p.addVCA(name: " ") }
        #expect(throws: Mixer.Failure.self) { try p.removeVCA(v.id) }
        #expect(p == kept)
    }

    @Test("A hostile file: twin VCAs, a member of a VCA that isn't there, an absurd level")
    func hostile() throws {
        var (p, pool) = MixerTests.document()
        let id = UUID()
        p.vcas = [VCA(id: id, name: "A", gainDB: 1e300), VCA(id: id, name: "A again"), VCA(name: "")]
        p.tracks[0].vca = id
        p.tracks[1].vca = UUID()
        let (opened, notes) = try ProjectPackage.decodeChecked(try ProjectPackage.encode(p))
        #expect(opened.vcas.count == 2 && opened.vcas[0].gainDB == Mixer.gainRange.upperBound && !opened.vcas[1].name.isEmpty)
        #expect(opened.tracks[0].vca == id && opened.tracks[1].vca == nil)
        #expect(notes.contains { $0.contains("VCA") && $0.contains("same id") } && notes.contains { $0.contains("belonged to a VCA that isn't") }, "\(notes)")
        let y = PlanCompiler.compile(opened, pool: pool).render(from: 0, frames: MixerTests.n)
        let finite = y.allSatisfy { $0.isFinite }
        #expect(finite)
    }
}
