import Foundation

/// One way to make a file name from a name a person or an agent gave (a document's, a track's, a take's, a batch's
/// suffix), for every place Jämmer writes or suggests one: exports, batch results, stems, chapters, a project's media,
/// files sent to Flimmer (COMFORT.md, the series' shared lesson on safe file names, 2026-11-25).
///
/// - `/`, `:` and `\` become `-`: a name never reaches into another folder, and Finder's `:` is macOS's `/`.
/// - Newlines, tabs and other control characters (Cc) go, as do the bidi overrides; joiners stay (emoji families).
/// - Leading dots go (no hidden files), as do spaces at either end.
/// - The text is NFC, as the series writes names (Jämmer.app, Jämmer-<version>.zip).
/// - At most 120 characters and 240 bytes in UTF-8, cut at a character, never inside one; the extension isn't
///   counted and is kept.
/// - Nothing left: the fallback.
public enum FileNames {
    public static let maxLength = 120
    /// And at most this many bytes in UTF-8 (APFS allows 255 a name; the extension goes after; COMFORT.md 9cd968e).
    public static let maxBytes = 240
    /// LRE, RLE, PDF, LRO, RLO and LRI, RLI, FSI, PDI: they can make a name read differently from what it is.
    static let bidiOverrides: Set<UInt32> = [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]

    /// A file name's stem (no extension).
    public static func safe(_ name: String, fallback: String = "Untitled") -> String {
        var s = name.precomposedStringWithCanonicalMapping
        s = String(s.unicodeScalars.compactMap { u -> Character? in
            if ["/", ":", "\\"].contains(u) { return "-" }
            // Control characters (Cc), line breaks and the bidi overrides go; joiners stay, or emoji families fall apart.
            if u.properties.generalCategory == .control || CharacterSet.newlines.contains(u) || bidiOverrides.contains(u.value) { return nil }
            return Character(u)
        })
        s = s.trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst(); s = s.trimmingCharacters(in: .whitespaces) }
        if s.count > maxLength { s = String(s.prefix(maxLength)).trimmingCharacters(in: .whitespaces) }
        // APFS takes 255 bytes a name: at most 240 in UTF-8 for the stem, cut before a whole character.
        while s.utf8.count > maxBytes { s.removeLast() }
        s = s.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? fallback : s
    }

    /// A whole file name: the stem made safe, then the extension (itself made safe and lowercase-kept as given).
    public static func safe(_ stem: String, ext: String, fallback: String = "Untitled") -> String {
        let e = safe(ext, fallback: "").replacingOccurrences(of: ".", with: "")
        return e.isEmpty ? safe(stem, fallback: fallback) : safe(stem, fallback: fallback) + "." + e
    }
}
