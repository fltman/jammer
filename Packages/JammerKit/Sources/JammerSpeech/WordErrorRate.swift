import Foundation

/// Word error rate the standard way: (substitutions + deletions + insertions) / reference
/// words, from a minimum-edit alignment of normalised words.
public struct WordErrorRate: Sendable, Equatable {
    public var substitutions: Int
    public var deletions: Int
    public var insertions: Int
    public var referenceWords: Int

    public var errors: Int { substitutions + deletions + insertions }
    /// 0 is perfect; can exceed 1 when there are many insertions.
    public var rate: Double { referenceWords == 0 ? (insertions == 0 ? 0 : 1) : Double(errors) / Double(referenceWords) }

    public static let zero = WordErrorRate(substitutions: 0, deletions: 0, insertions: 0, referenceWords: 0)

    public static func + (a: Self, b: Self) -> Self {
        WordErrorRate(substitutions: a.substitutions + b.substitutions, deletions: a.deletions + b.deletions,
                      insertions: a.insertions + b.insertions, referenceWords: a.referenceWords + b.referenceWords)
    }

    /// Lower case, punctuation removed, hyphens and dashes as spaces. Letters such as
    /// å, ä, ö are kept: "har" and "här" are different words.
    public static func normalise(_ s: String) -> [String] {
        let mapped = s.lowercased().unicodeScalars.map { c -> String in
            if CharacterSet.punctuationCharacters.contains(c) || CharacterSet.symbols.contains(c) {
                return c == "'" || c == "’" ? "" : " "
            }
            return String(c)
        }.joined()
        return mapped.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public static func compute(reference: String, hypothesis: String) -> WordErrorRate {
        compute(reference: normalise(reference), hypothesis: normalise(hypothesis))
    }

    public static func compute(reference r: [String], hypothesis h: [String]) -> WordErrorRate {
        let n = r.count, m = h.count
        // cost[i][j]: edits to turn r[0..<i] into h[0..<j]; ties prefer substitution,
        // then deletion, then insertion (as sclite and jiwer report).
        var cost = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { cost[i][0] = i }
        for j in 0...m { cost[0][j] = j }
        if n > 0 && m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let sub = cost[i - 1][j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1)
                    cost[i][j] = min(sub, cost[i - 1][j] + 1, cost[i][j - 1] + 1)
                }
            }
        }
        var s = 0, d = 0, ins = 0, i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, cost[i][j] == cost[i - 1][j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1) {
                if r[i - 1] != h[j - 1] { s += 1 }
                i -= 1; j -= 1
            } else if i > 0, cost[i][j] == cost[i - 1][j] + 1 {
                d += 1; i -= 1
            } else {
                ins += 1; j -= 1
            }
        }
        return WordErrorRate(substitutions: s, deletions: d, insertions: ins, referenceWords: n)
    }
}
