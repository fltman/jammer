import Foundation

/// Finding things in a document for an assistant or an agent: pauses and filler words.
extension Project {
    /// Stretches where everything that plays stays below `threshold` dBFS for at least
    /// `minLength` frames, measured in 10 ms blocks on the mixed timeline.
    public func silences(minLength: Frame, threshold: Double = -45, in range: Range<Frame>? = nil, pool: SourcePool) -> [Range<Frame>] {
        let r = range ?? 0..<length
        guard !r.isEmpty else { return [] }
        let plan = PlanCompiler.compile(self, pool: pool)
        let block = max(1, Int(sampleRate / 100))
        let limit = Float(pow(10, threshold / 20))
        var out: [Range<Frame>] = []
        var quietStart: Frame?
        var at = r.lowerBound
        let piece = block * 1_000
        while at < r.upperBound {
            let n = Int(min(Frame(piece), r.upperBound - at))
            let raw = plan.render(from: at, frames: n)
            var b = 0
            while b < n {
                let m = min(block, n - b)
                var peak: Float = 0
                for i in (b * channels)..<((b + m) * channels) { peak = max(peak, abs(raw[i])) }
                let t = at + Frame(b)
                if peak < limit {
                    if quietStart == nil { quietStart = t }
                } else if let s = quietStart {
                    if t - s >= minLength { out.append(s..<t) }
                    quietStart = nil
                }
                b += m
            }
            at += Frame(n)
        }
        if let s = quietStart, r.upperBound - s >= minLength { out.append(s..<r.upperBound) }
        return out
    }

    /// Filler words as they read in the transcript ("eh", "ehm", "öh", "um", "uh"…).
    public static let fillerWords: Set<String> = ["eh", "ehm", "ehh", "öh", "öhm", "öhh", "äh", "ähm", "hm", "hmm", "mm", "um", "umm", "uh", "uhm", "er", "erm"]

    /// Ids of the filler words that play, in timeline order.
    public func fillerWordIDs(extra: Set<String> = []) -> [UUID] {
        let set = Self.fillerWords.union(extra.map { $0.lowercased() })
        return placedWords().filter { w in
            let t = Self.tokens(w.word.text).joined(separator: " ")
            return set.contains(t)
        }.map(\.word.id)
    }
}
