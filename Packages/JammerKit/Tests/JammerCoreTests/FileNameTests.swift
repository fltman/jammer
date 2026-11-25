import Foundation
import Testing
@testable import JammerCore

/// FileNames: one way from a given name to a file name (COMFORT.md, safe file names).
@Suite("Safe file names")
struct FileNameTests {
    @Test("Separators become -, control characters and newlines go, leading dots and edge spaces go")
    func cleans() {
        #expect(FileNames.safe("a/b:c\\d") == "a-b-c-d")
        #expect(FileNames.safe("Intervju\n\tdel 2\u{0007}") == "Intervjudel 2")
        #expect(FileNames.safe("  ..hidden ") == "hidden")
        #expect(FileNames.safe(". . .") == "Untitled")
        #expect(FileNames.safe("", fallback: "audio") == "audio")
    }

    @Test("NFC, and at most 120 characters, cut at a character; the extension is kept and not counted")
    func normalizesAndCuts() {
        let decomposed = "Ja\u{0308}mmer"   // ä as a plus a combining diaeresis
        #expect(FileNames.safe(decomposed) == "Jämmer" && FileNames.safe(decomposed).unicodeScalars.count == 6)
        let long = String(repeating: "å", count: 200)
        let cut = FileNames.safe(long, ext: "wav")
        #expect(cut.hasSuffix(".wav") && (cut as NSString).deletingPathExtension.count == 120)
        #expect(FileNames.safe("👩‍👩‍👧" + String(repeating: "x", count: 130)).count == 120, "an emoji of several scalars is kept whole")
        #expect(FileNames.safe("take", ext: ".w/av") == "take.w-av")
    }
}
