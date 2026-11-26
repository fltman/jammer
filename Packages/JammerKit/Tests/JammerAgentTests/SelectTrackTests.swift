import Foundation
import Testing
@testable import JammerAgent
@testable import JammerCore

/// The selected track, chosen by a step or a key (vertical scrolling's follow-up, 2026-11-26): the window brings it
/// into view (LaneLayout.revealing, tested in JammerCore).
@Suite("Selecting a track")
struct SelectTrackTests {
    @Test("select_track makes a track the selected one, changes nothing in the document, and refuses a track that isn't there")
    func step() {
        var s = FieldStepTests.state(channels: 2)
        s.project.tracks.append(Track(name: "Two"))
        let before = s.project
        let id = s.project.tracks[1].id
        let r = FieldStepTests.run(&s, "select_track", ["track": .string(id.uuidString)])
        #expect(r.status == .done && s.currentTrack == id)
        #expect(s.project == before, "not an edit")
        let wrong = FieldStepTests.run(&s, "select_track", ["track": .string(UUID().uuidString)])
        #expect(wrong.status == .failed && wrong.reason == "not_found" && s.currentTrack == id)
        #expect(Operations.all.first { $0.name == "select_track" }?.edits == false)
    }

    @Test("Previous and Next Track are ⌥↑ and ⌥↓, with no ⌘, and the agent's way is select_track")
    func keys() {
        #expect(Commands.command("track.previous")?.shortcut == "⌥↑")
        #expect(Commands.command("track.next")?.shortcut == "⌥↓")
        // The other commands still all have ⌘.
        for c in Commands.all where !c.key.isEmpty && !["↑", "↓", "←", "→"].contains(c.key) { #expect(c.modifiers.contains(.command), "\(c.id)") }
    }
}
