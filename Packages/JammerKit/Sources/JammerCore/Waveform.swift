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
    ///   - allowRaw: false never touches the files: below one peak block a column
    ///     shows its block's min/max (or nothing without an index). For the main
    ///     thread, which mustn't wait for a disk.
    public static func columns(_ project: Project, track: Int, start: Double, framesPerColumn: Double, count: Int,
                               peaks: [UUID: PeakIndex], pool: SourcePool, allowRaw: Bool = true) -> [[Column]] {
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
            let usePeaks = index != nil && (framesPerColumn >= Double(PeakIndex.baseBlock) || !allowRaw)
            if !usePeaks && !allowRaw { continue }
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
            // In a layout wider than stereo the clip is drawn where it is heard: through the same matrix as the
            // sound (the panner's for a placed track, else the layouts'), so a voice shows in C, not in every row.
            let matrix: [Float]? = channels <= 2 ? nil
                : (t.position != nil && srcCh <= 2) ? Panner.matrix(t.position!, sourceChannels: srcCh, in: project.layout)
                : project.layout.matrix(sourceChannels: srcCh, sourceMask: ref.info.channelMask)
            for c in firstCol...lastCol {
                let (a, b) = columnRange(c)
                let lo = Swift.max(clip.start, a), hi = Swift.min(clip.end, b)
                guard hi > lo else { continue }
                let mid = (lo + hi) / 2 - clip.start
                let g = gain * fadeGain(clip, mid)
                if let matrix {
                    // Each source channel's range, then each document channel's as the sum of its parts' ranges
                    // (an envelope: the real sum lies inside it).
                    var ranges: [(Float, Float)?] = []
                    for sc in 0..<srcCh {
                        if usePeaks, let index {
                            let s0 = clip.sourceStart + (lo - clip.start)
                            ranges.append(index.minMax(channel: sc, s0..<(s0 + (hi - lo))))
                        } else {
                            let i0 = Int(lo - rawStart), i1 = Swift.min(Int(hi - rawStart), raw.count / srcCh)
                            guard i0 < i1 else { ranges.append(nil); continue }
                            var mn = Float.greatestFiniteMagnitude, mx = -Float.greatestFiniteMagnitude
                            for i in i0..<i1 { let v = raw[i * srcCh + sc]; mn = Swift.min(mn, v); mx = Swift.max(mx, v) }
                            ranges.append((mn, mx))
                        }
                    }
                    for ch in 0..<channels {
                        var mn: Float = 0, mx: Float = 0, any = false
                        for sc in 0..<srcCh {
                            let m = matrix[sc * channels + ch] * g
                            guard m != 0, let (p, q) = ranges[sc] else { continue }
                            any = true
                            mn += Swift.min(m * p, m * q); mx += Swift.max(m * p, m * q)
                        }
                        guard any else { continue }
                        var col = out[ch][c]
                        if col == .empty { col = Column(min: mn, max: mx) } else { col.min = Swift.min(col.min, mn); col.max = Swift.max(col.max, mx) }
                        out[ch][c] = col
                    }
                    continue
                }
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
