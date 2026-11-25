import Foundation

/// One way to make a file name from a name a person or an agent gave (a document's, a track's, a take's, a batch's
/// suffix), for every place Jämmer writes or suggests one: exports, batch results, stems, chapters, a project's media,
/// files sent to Flimmer (COMFORT.md, the series' shared lesson on safe file names, 2026-11-25).
///
/// - `/`, `:` and `\` become `-`: a name never reaches into another folder, and Finder's `:` is macOS's `/`.
/// - Newlines, tabs and other control characters go.
/// - Leading dots go (no hidden files), as do spaces at either end.
/// - The text is NFC, as the series writes names (Jämmer.app, Jämmer-<version>.zip).
/// - At most 120 characters, cut at a character, never inside one; the extension isn't counted and is kept.
/// - Nothing left: the fallback.
public enum FileNames {
    public static let maxLength = 120

    /// A file name's stem (no extension).
    public static func safe(_ name: String, fallback: String = "Untitled") -> String {
        var s = name.precomposedStringWithCanonicalMapping
        s = String(s.unicodeScalars.compactMap { u -> Character? in
            if ["/", ":", "\\"].contains(u) { return "-" }
            if CharacterSet.controlCharacters.contains(u) || CharacterSet.newlines.contains(u) { return nil }
            return Character(u)
        })
        s = s.trimmingCharacters(in: .whitespaces)
        while s.hasPrefix(".") { s.removeFirst(); s = s.trimmingCharacters(in: .whitespaces) }
        if s.count > maxLength { s = String(s.prefix(maxLength)).trimmingCharacters(in: .whitespaces) }
        return s.isEmpty ? fallback : s
    }

    /// A whole file name: the stem made safe, then the extension (itself made safe and lowercase-kept as given).
    public static func safe(_ stem: String, ext: String, fallback: String = "Untitled") -> String {
        let e = safe(ext, fallback: "").replacingOccurrences(of: ".", with: "")
        return e.isEmpty ? safe(stem, fallback: fallback) : safe(stem, fallback: fallback) + "." + e
    }
}
