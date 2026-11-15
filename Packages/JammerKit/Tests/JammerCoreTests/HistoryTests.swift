import Foundation
import Testing
@testable import JammerCore

@Suite("History tree")
struct HistoryTests {
    private func project(_ dir: TempDir) throws -> Project {
        let url = dir.file("a.wav")
        try writeWAV(sine(440, amplitudeDB: -12, seconds: 4), to: url)
        var p = Project(source: SourceRef(name: "a", path: url.path, info: try AudioFileReader.info(at: url)))
        p.setTranscript(SourceTranscript(sourceID: p.sources[0].id, language: "sv-SE", engine: "t",
                                         words: (0..<200).map { Word(text: "ord\($0)", start: Frame($0 * 900), end: Frame($0 * 900 + 800)) }))
        return p
    }

    @Test("Undo, a new change, and the old future is still there as a branch; every state comes back exactly")
    func branches() throws {
        let dir = TempDir()
        let p0 = try project(dir)
        var h = try History(root: p0)
        var p1 = p0; try p1.changeGain(0..<p1.length, by: -3)
        try h.record(p1, action: "Gain")
        var p2 = p1; try p2.delete(0..<48_000)
        try h.record(p2, action: "Delete")
        let deleteNode = h.current
        // Undo twice, then something else.
        let root = h.activePath[0], gainNode = h.activePath[1]
        #expect(try h.move(to: gainNode) == p1)
        var p3 = p1; try p3.fade(.fadeIn, 0..<24_000, shape: .linear)
        try h.record(p3, action: "Fade In")
        #expect(h.children(of: gainNode).count == 2)
        #expect(!h.activePath.contains(deleteNode))
        // Jump over to the other branch and back: identical projects.
        #expect(try h.move(to: deleteNode) == p2)
        #expect(try h.move(to: root) == p0)
        #expect(try h.project(of: h.nodes.last!.id) == p3)
        #expect(throws: HistoryError.self) { try h.move(to: UUID()) }
    }

    @Test("Transcripts are stored once, not per step; the tree survives saving")
    func storageAndCoding() throws {
        let dir = TempDir()
        var p = try project(dir)
        var h = try History(root: p)
        for i in 0..<20 { try p.changeGain(0..<p.length, by: 0.5); try h.record(p, action: "Gain \(i)") }
        #expect(h.blobs.count == 2) // one transcript set, one (empty) turn set
        let back = try JSONDecoder().decode(History.self, from: JSONEncoder().encode(h))
        #expect(back == h)
        #expect(try back.project(of: back.current) == p)
    }

    @Test("Over the limit, old branches go first, the active path stays, and the count is kept")
    func pruning() throws {
        let dir = TempDir()
        var p = try project(dir)
        var h = try History(root: p, limit: 6)
        try p.changeGain(0..<p.length, by: 1); try h.record(p, action: "A")
        let a = h.current
        var side = p; try side.changeGain(0..<p.length, by: 2); try h.record(side, action: "Side")
        try h.move(to: a)
        for i in 0..<6 { try p.changeGain(0..<p.length, by: 0.1); try h.record(p, action: "Main \(i)") }
        #expect(h.nodes.count == 6)
        #expect(h.pruned == 3)
        #expect(!h.nodes.contains { $0.action == "Side" })
        #expect(try h.project(of: h.current) == p)
        #expect(h.activePath.count == 6)
    }
}
