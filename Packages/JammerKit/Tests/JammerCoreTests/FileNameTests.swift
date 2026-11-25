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
        #expect(FileNames.safe("Familjen 👩‍👩‍👧") == "Familjen 👩‍👩‍👧", "the zero-width joiners stay")
        #expect(FileNames.safe("abc\u{202E}gpj.exe") == "abcgpj.exe", "a right-to-left override goes")
        #expect(FileNames.safe("take", ext: ".w/av") == "take.w-av")
    }

    @Test("At most 240 bytes in UTF-8 as well, cut before a whole character: emoji, and a long Swedish name")
    func bytes() {
        let emoji = FileNames.safe(String(repeating: "🎙️", count: 120), ext: "wav")
        let stem = (emoji as NSString).deletingPathExtension
        #expect(stem.utf8.count <= 240 && emoji.hasSuffix(".wav") && stem.allSatisfy { $0 == "🎙️" }, "\(stem.utf8.count) bytes")
        let swedish = FileNames.safe(String(repeating: "Åsa-Märta Öberg ", count: 10))
        #expect(swedish.count <= 120 && swedish.utf8.count <= 240 && swedish.hasPrefix("Åsa-Märta Öberg"))
        let wide = FileNames.safe(String(repeating: "ö", count: 130))   // 2 bytes each: 120 characters are 240 bytes
        #expect(wide.count == 120 && wide.utf8.count == 240)
    }
}
