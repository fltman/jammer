import Foundation

/// Min/max columns of the edited timeline (clips, gains and fades applied), for
/// drawing and for agents that want to "see" the audio. Uses the peak index
/// when a column covers at least one peak block, and the samples otherwise.
public enum Waveform {
    public struct Column: Sendable, Equatable {
        public var min: Float
        public var max: Float
        public static let empty = Column(min: 0, max: 0)
    }

    /// Columns for one track: `result[channel][column]`, `channels` = the project's.
    /// - Parameters:
    ///   - start: first timeline frame (fractional, so zooming is smooth).
    ///   - framesPerColumn: may be below 1 when zoomed in past single samples.
    public static func columns(_ project: Project, track: Int, start: Double, framesPerColumn: Double, count: Int,
                               peaks: [UUID: PeakIndex], pool: SourcePool) -> [[Column]] {
        let channels = project.channels
        var out = Array(repeating: Array(repeating: Column.empty, count: count), count: channels)
        guard track < project.tracks.count, count > 0, framesPerColumn > 0 else { return out }
        let t = project.tracks[track]
        let trackGain = Float(dbToGain(t.gainDB))
        let viewEnd = start + framesPerColumn * Double(count)
        func columnRange(_ c: Int) -> (Frame, Frame) {
            let a = Frame((start + Double(c) * framesPerColumn).rounded(.down))
            let b = Swift.max(a + 1, Frame((start + Double(c + 1) * framesPerColumn).rounded(.down)))
            return (a, b)
        }
        for clip in t.clips where Double(clip.end) > start && Double(clip.start) < viewEnd {
            guard let ref = project.source(clip.sourceID) else { continue }
            let srcCh = ref.info.channels
            let gain = Float(dbToGain(clip.gainDB)) * trackGain
            let firstCol = Swift.max(0, Int(((Double(clip.start) - start) / framesPerColumn).rounded(.down)))
            let lastCol = Swift.min(count - 1, Int(((Double(clip.end) - start) / framesPerColumn).rounded(.up)))
            guard firstCol <= lastCol else { continue }
            let index = peaks[ref.id]
            let usePeaks = index != nil && framesPerColumn >= Double(PeakIndex.baseBlock)
            // Raw mode: read the visible part of the clip once.
            var raw: [Float] = []
            var rawStart: Frame = 0
            if !usePeaks {
                let (a, _) = columnRange(firstCol)
                let (_, b) = columnRange(lastCol)
                let lo = Swift.max(clip.start, a), hi = Swift.min(clip.end, b)
                guard hi > lo, hi - lo <= 8_000_000 else { continue }
                rawStart = lo
                raw = pool.read(ref, from: clip.sourceStart + (lo - clip.start), count: Int(hi - lo))
            }
            for c in firstCol...lastCol {
                let (a, b) = columnRange(c)
                let lo = Swift.max(clip.start, a), hi = Swift.min(clip.end, b)
                guard hi > lo else { continue }
                let mid = (lo + hi) / 2 - clip.start
                let g = gain * fadeGain(clip, mid)
                for ch in 0..<channels {
                    let sc = srcCh == 1 ? 0 : ch
                    guard sc < srcCh else { continue }
                    var mn: Float, mx: Float
                    if usePeaks, let index {
                        let s0 = clip.sourceStart + (lo - clip.start)
                        guard let (p, q) = index.minMax(channel: sc, s0..<(s0 + (hi - lo))) else { continue }
                        mn = p; mx = q
                    } else {
                        let i0 = Int(lo - rawStart), i1 = Swift.min(Int(hi - rawStart), raw.count / srcCh)
                        guard i0 < i1 else { continue }
                        mn = .greatestFiniteMagnitude; mx = -.greatestFiniteMagnitude
                        for i in i0..<i1 {
                            let v = raw[i * srcCh + sc]
                            if v < mn { mn = v }
                            if v > mx { mx = v }
                        }
                    }
                    mn *= g; mx *= g
                    if g < 0 { swap(&mn, &mx) }
                    var col = out[ch][c]
                    if col == .empty { col = Column(min: mn, max: mx) } else {
                        col.min = Swift.min(col.min, mn)
                        col.max = Swift.max(col.max, mx)
                    }
                    out[ch][c] = col
                }
            }
        }
        return out
    }

    static func fadeGain(_ c: Clip, _ p: Frame) -> Float {
        var g: Float = 1
        func curve(_ t: Double) -> Float { Float(c.fadeShape == .linear ? t : sin(t * .pi / 2)) }
        if c.fadeIn > 0, p < c.fadeIn { g *= curve(Double(p) / Double(c.fadeIn)) }
        if c.fadeOut > 0, p >= c.length - c.fadeOut { g *= curve(Double(c.length - p) / Double(c.fadeOut)) }
        return g
    }
}
