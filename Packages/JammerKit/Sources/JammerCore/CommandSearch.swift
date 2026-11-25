import Foundation

/// The omnibar's search over the app's commands (menus, presets and the agent's operations share one list),
/// and its guess whether a text is a command or a request for the assistant. The same behaviour as Glimmer's
/// omnibar, written for Jämmer.
public enum CommandSearch {
    /// Something the omnibar can run, by a stable id (for the usage table).
    public struct Entry: Sendable, Equatable {
        public var id: String
        public var title: String
        public var detail: String
        public init(id: String, title: String, detail: String) {
            self.id = id
            self.title = title
            self.detail = detail
        }
    }

    /// How well `query` matches `text`, higher is better; nil when the query's letters (spaces ignored) don't
    /// appear in `text` in order. Word starts, a run of letters next to each other, a match at the start and a
    /// shorter text count for more.
    public static func score(_ query: String, _ text: String) -> Double? {
        // Accents don't matter either way: "lak" finds "Läk", "Jammer" "Jämmer" (COMFORT 19).
        let q = Array(fold(query).filter { !$0.isWhitespace })
        let t = Array(fold(text))
        guard !q.isEmpty else { return 0 }
        guard q.count <= t.count else { return nil }
        var total = 0.0, at = 0, last = -2
        for c in q {
            guard let i = t[at...].firstIndex(of: c) else { return nil }
            total += 1
            if i == 0 || !(t[i - 1].isLetter || t[i - 1].isNumber) { total += 2 }
            if i == last + 1 { total += 1.5 }
            last = i
            at = i + 1
        }
        if t.first == q.first { total += 3 }
        let whole = String(t), needle = String(q)
        if whole.hasPrefix(needle) { total += 4 }
        if let r = whole.range(of: needle) {
            total += 4 + Double(q.count)
            if r.lowerBound == whole.startIndex || !whole[whole.index(before: r.lowerBound)].isLetter { total += 3 }
        }
        return total - Double(t.count) * 0.02
    }

    static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

    /// A typo forgiven (COMFORT 19): each word of the query of four letters or more may be one letter off from a word
    /// of the text (one changed, missing, extra, or two swapped), shorter words must begin one. Scored just over the
    /// listing's floor, so an exact match always ranks above it. nil when a word finds nothing.
    public static func forgiving(_ query: String, _ text: String) -> Double? {
        let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        let have = fold(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return nil }
        var total = 0.0
        for w in words {
            if have.contains(where: { $0.hasPrefix(w) }) { total += 2.6 * Double(w.count); continue }
            guard w.count >= 4, have.contains(where: { oneOff(w, $0) || oneOff(w, String($0.prefix(w.count))) }) else { return nil }
            total += 2.2 * Double(w.count)
        }
        return total - Double(text.count) * 0.02
    }

    /// One letter changed, missing, extra, or two neighbours swapped.
    static func oneOff(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        if x == y { return true }
        if x.count == y.count {
            let diff = x.indices.filter { x[$0] != y[$0] }
            if diff.count == 1 { return true }
            return diff.count == 2 && diff[1] == diff[0] + 1 && x[diff[0]] == y[diff[1]] && x[diff[1]] == y[diff[0]]
        }
        guard abs(x.count - y.count) == 1 else { return false }
        let (long, short) = x.count > y.count ? (x, y) : (y, x)
        var i = 0, j = 0, skipped = false
        while i < long.count, j < short.count {
            if long[i] == short[j] { i += 1; j += 1 } else if skipped { return false } else { skipped = true; i += 1 }
        }
        return true
    }

    /// How often and how lately each entry was run from the omnibar: a small lift, so that what you use comes
    /// first among equally good matches without burying a better one.
    public struct Usage: Codable, Sendable, Equatable {
        public var count = 0
        public var last = Date.distantPast
        public init(count: Int = 0, last: Date = .distantPast) {
            self.count = count
            self.last = last
        }
        /// At most 3, growing with use and halving every two weeks unused.
        public func lift(now: Date) -> Double {
            guard count > 0 else { return 0 }
            let days = max(0, now.timeIntervalSince(last) / 86_400)
            return min(3, 1.2 * log2(1 + Double(count))) * pow(0.5, days / 14)
        }
        /// One more use of `id`; past `limit` entries the least lifted are dropped.
        public static func record(_ id: String, in table: inout [String: Usage], now: Date = Date(), limit: Int = 200) {
            var u = table[id] ?? Usage()
            u.count += 1
            u.last = now
            table[id] = u
            if table.count > limit {
                for key in table.sorted(by: { $0.value.lift(now: now) < $1.value.lift(now: now) }).prefix(table.count - limit).map(\.key) {
                    table[key] = nil
                }
            }
        }
    }

    /// The best matches, best first: the title counts fully, the group and title together a little less.
    /// A match whose letters lie scattered (under 2 points a letter: "fade" across "File: copy every file
    /// the project plays from…", seen in the app 2026-11-19) isn't listed. An empty query gives the most used
    /// entries (none when nothing has been used yet).
    public static func search(_ query: String, in entries: [Entry], usage: [String: Usage] = [:], now: Date = Date(),
                              limit: Int = 6) -> [(entry: Entry, score: Double)] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            return entries.compactMap { e in usage[e.id].map { (e, $0.lift(now: now)) } }.filter { $0.1 > 0 }
                .sorted { $0.1 > $1.1 }.prefix(limit).map { ($0.0, $0.1) }
        }
        var found: [(Entry, Double)] = []
        for e in entries {
            let title = score(q, e.title) ?? forgiving(q, e.title)
            let both = (score(q, "\(e.detail) \(e.title)") ?? forgiving(q, "\(e.detail) \(e.title)")).map { $0 * 0.8 }
            guard let best = [title, both].compactMap({ $0 }).max(), best >= 2 * Double(q.filter { !$0.isWhitespace }.count) else { continue }
            found.append((e, best + (usage[e.id]?.lift(now: now) ?? 0)))
        }
        return found.sorted { $0.1 > $1.1 }.prefix(limit).map { ($0.0, $0.1) }
    }

    /// What Return does with a text: run the best command, ask the assistant, or, when the text could be either,
    /// let the model on this Mac decide (free, and nothing leaves the Mac).
    public enum Route: Equatable, Sendable { case command, ask, unsure }

    /// A command when the text is a command's name or close to one; the assistant when it reads as a sentence
    /// (four words or more) or nothing matches well; unsure in between.
    public static func route(_ query: String, best: (entry: Entry, score: Double)?) -> Route {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let best, !q.isEmpty else { return .ask }
        if best.entry.title.compare(q, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame { return .command }
        let words = q.split(whereSeparator: \.isWhitespace).count
        if words >= 4 { return .ask }
        if words == 1 { return .command }
        let perLetter = best.score / Double(max(q.filter { !$0.isWhitespace }.count, 1))
        return perLetter >= 2.6 ? .command : perLetter < 1.6 ? .ask : .unsure
    }
}
