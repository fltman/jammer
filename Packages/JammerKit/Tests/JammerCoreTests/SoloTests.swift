import Foundation
import Testing
@testable import JammerCore

@Suite("Mixer: solo, a way of listening")
struct SoloTests {
    @Test("A soloed track is the only one heard; two soloed are both; nothing soloed, or ids that are no strips, is the project itself")
    func tracks() throws {
        let (p, pool) = MixerTests.document()
        let ids = p.tracks.map(\.id)
        #expect(p.listening(solo: []) == p && p.listening(solo: [UUID()]) == p)
        var alone = p
        alone.tracks[0].isMuted = true; alone.tracks[2].isMuted = true
        #expect(p.listening(solo: [ids[1]]) == alone)
        #expect(MixerTests.render(p.listening(solo: [ids[1]]), pool) == MixerTests.render(alone, pool))
        #expect(p.heardInSolo([ids[0], ids[2]]) == [ids[0], ids[2]])
        // The document is not touched: listening is a copy.
        #expect(p.tracks.allSatisfy { !$0.isMuted })
    }

    @Test("A soloed bus lets through the tracks that reach it, by output, through another bus, or by a send")
    func buses() throws {
        var (p, _) = MixerTests.document()
        let a = try p.addBus(name: "A"), b = try p.addBus(name: "B"), fx = try p.addBus(name: "FX")
        try p.setBus(a.id, output: .some(b.id))                       // A → B
        try p.setTrackRoute(p.tracks[0].id, output: .some(a.id))      // track 0 → A → B
        try p.setSend(from: p.tracks[1].id, to: fx.id)                // track 1 → out, and a send to FX
        let ids = p.tracks.map(\.id)
        #expect(p.heardInSolo([a.id]) == [ids[0]])
        #expect(p.heardInSolo([b.id]) == [ids[0]])
        #expect(p.heardInSolo([fx.id]) == [ids[1]])
        #expect(p.heardInSolo([fx.id, ids[2]]) == [ids[1], ids[2]])
        // Buses are never muted by solo: what is heard still goes where it goes.
        #expect(p.listening(solo: [a.id]).buses == p.buses)
        // A track already muted stays muted when soloed: solo doesn't open what the document has closed.
        p.tracks[0].isMuted = true
        #expect(p.listening(solo: [ids[0]]).tracks[0].isMuted)
    }
}
