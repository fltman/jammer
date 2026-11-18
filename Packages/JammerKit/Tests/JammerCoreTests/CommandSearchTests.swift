import Foundation
import Testing
@testable import JammerCore

@Suite("Omnibar search")
struct CommandSearchTests {
    let entries: [CommandSearch.Entry] = [
        .init(id: "fit", title: "Zoom to Fit", detail: "View"),
        .init(id: "fade-in", title: "Fade In", detail: "Fade"),
        .init(id: "fade-out", title: "Fade Out", detail: "Fade"),
        .init(id: "norm-16", title: "Normalize to −16 LUFS", detail: "Normalize Loudness"),
        .init(id: "noise", title: "Reduce Noise…", detail: "Audio"),
        .init(id: "mixer", title: "Mixer…", detail: "Audio"),
        .init(id: "collect", title: "Collect Audio and Save", detail: "File: copy every file the project plays from into it"),
    ]

    @Test("Letters in order match; a word start, a run and a prefix rank higher; nothing out of order matches")
    func scores() {
        #expect(CommandSearch.score("fdin", "Fade In") != nil)
        #expect(CommandSearch.score("nidaf", "Fade In") == nil)
        #expect(CommandSearch.score("fade", "Fade In")! > CommandSearch.score("fade", "Reduce Noise and Fade")!)
        #expect(CommandSearch.search("norm", in: entries).first?.entry.id == "norm-16")
        #expect(CommandSearch.search("fit", in: entries).first?.entry.id == "fit")
        #expect(CommandSearch.search("xyz", in: entries).isEmpty)
        // Letters scattered over a long description aren't a match (seen in the app).
        #expect(!CommandSearch.search("fade", in: entries).contains { $0.entry.id == "collect" })
        #expect(CommandSearch.search("collect", in: entries).first?.entry.id == "collect")
    }

    @Test("What you use comes first among equal matches, and an empty field lists only what has been used")
    func usage() {
        #expect(CommandSearch.search("fade", in: entries).first?.entry.id == "fade-in")
        var table: [String: CommandSearch.Usage] = [:]
        for _ in 0..<3 { CommandSearch.Usage.record("fade-out", in: &table) }
        #expect(CommandSearch.search("fade", in: entries, usage: table).first?.entry.id == "fade-out")
        #expect(CommandSearch.search("", in: entries).isEmpty)
        #expect(CommandSearch.search("", in: entries, usage: table).map(\.entry.id) == ["fade-out"])
        // A use two months ago lifts much less than one today.
        let old = CommandSearch.Usage(count: 3, last: Date().addingTimeInterval(-60 * 86_400))
        #expect(old.lift(now: Date()) < 0.2 && table["fade-out"]!.lift(now: Date()) > 2)
    }

    @Test("Return runs a command's name or one word; a sentence or no match goes to the assistant; in between it is unsure")
    func route() {
        func r(_ q: String) -> CommandSearch.Route { CommandSearch.route(q, best: CommandSearch.search(q, in: entries).first) }
        #expect(r("fade in") == .command)          // a command's own name
        #expect(r("norm") == .command)             // one word that matches
        #expect(r("mixer") == .command)
        #expect(r("make the music quieter under the voice") == .ask)
        #expect(r("ta bort alla ehm") == .ask)
        #expect(r("qqq") == .ask)                  // no match
        #expect(r("") == .ask)
        // Two or three words: by how well they match per letter (6 letters here).
        let e = entries[4]
        #expect(CommandSearch.route("red noi", best: (e, 6 * 2.7)) == .command)
        #expect(CommandSearch.route("red noi", best: (e, 6 * 2.0)) == .unsure)
        #expect(CommandSearch.route("red noi", best: (e, 6 * 1.5)) == .ask)
    }
}
