import Foundation
import Testing
@testable import JammerCore

@Suite("Edits")
struct EditTests {
    private let signal = (0..<(48_000 * 2)).map { Float(($0 * 7) % 65_536 - 32_768) / 32_768 }

    private func rendered(_ p: Project, _ pool: SourcePool) -> [Float] {
        let plan = PlanCompiler.compile(p, pool: pool)
        return plan.render(from: 0, frames: Int(plan.length))
    }

    private func frames(_ range: Range<Int>) -> [Float] { Array(signal[(range.lowerBound * 2)..<(range.upperBound * 2)]) }

    @Test("Delete with ripple closes the gap, bit-exactly")
    func delete() throws {
        var (p, pool) = memoryProject(signal)
        try p.delete(10_000..<20_000)
        #expect(p.length == 38_000)
        #expect(rendered(p, pool) == frames(0..<10_000) + frames(20_000..<48_000))
    }

    @Test("Cut then paste back gives the original bits")
    func cutPaste() throws {
        var (p, pool) = memoryProject(signal)
        let original = rendered(p, pool)
        let clip = try p.cut(5_000..<12_345)
        #expect(clip.length == 7_345)
        try p.paste(clip, at: 5_000)
        #expect(p.length == 48_000)
        #expect(rendered(p, pool) == original)
    }

    @Test("Paste elsewhere inserts and pushes the rest right")
    func pasteElsewhere() throws {
        var (p, pool) = memoryProject(signal)
        let clip = try p.copy(0..<1_000)
        try p.paste(clip, at: 30_000)
        #expect(p.length == 49_000)
        #expect(rendered(p, pool) == frames(0..<30_000) + frames(0..<1_000) + frames(30_000..<48_000))
    }

    @Test("Crop keeps only the selection")
    func crop() throws {
        var (p, pool) = memoryProject(signal)
        try p.crop(to: 1_234..<5_678)
        #expect(p.length == 4_444)
        #expect(rendered(p, pool) == frames(1_234..<5_678))
    }

    @Test("Gain changes only the range")
    func gain() throws {
        var (p, pool) = memoryProject(signal)
        try p.changeGain(1_000..<2_000, by: -6.0206)
        let out = rendered(p, pool)
        #expect(Array(out[0..<2_000]) == frames(0..<1_000))
        for i in 2_000..<4_000 { #expect(abs(out[i] - signal[i] * 0.5) < 1e-6) }
        #expect(Array(out[4_000...]) == frames(2_000..<48_000))
    }

    @Test("Fade in and out land exactly on the range")
    func fades() throws {
        var (p, pool) = memoryProject([Float](repeating: 0.5, count: 48_000 * 2))
        try p.fade(.fadeIn, 0..<1_000, shape: .linear)
        try p.fade(.fadeOut, 47_000..<48_000, shape: .linear)
        let out = rendered(p, pool)
        #expect(out[0] == 0)
        #expect(abs(out[500 * 2] - 0.25) < 1e-6)
        #expect(out[1_000 * 2] == 0.5)
        #expect(out[46_999 * 2] == 0.5)
        #expect(out[47_999 * 2] < 0.001)
    }

    @Test("A fade across two clips is refused")
    func fadeAcrossClips() throws {
        var (p, _) = memoryProject(signal)
        p.split(at: 10_000)
        #expect(throws: EditError.spansClips) { try p.fade(.fadeOut, 9_000..<11_000) }
    }

    @Test("Markers move with ripple edits and vanish with the audio")
    func markers() throws {
        var (p, _) = memoryProject(signal)
        p.addMarker(at: 5_000, name: "a")
        p.addMarker(at: 15_000, name: "b")
        p.addMarker(at: 30_000, name: "c")
        try p.delete(10_000..<20_000)
        #expect(p.markers.map(\.name) == ["a", "c"])
        #expect(p.markers.map(\.position) == [5_000, 20_000])
    }

    @Test("Projects survive the package format")
    func package() throws {
        var (p, _) = memoryProject(signal)
        try p.delete(100..<200)
        p.addMarker(at: 50, name: "Intro — första")
        let back = try ProjectPackage.decode(try ProjectPackage.encode(p))
        #expect(back == p)
    }

    @Test("Peaks match a brute-force scan")
    func peaks() throws {
        let s = noise(count: 300_000 * 2, seed: 9)
        let index = try #require(PeakIndex.build(reading: { at, n in
            let lo = Int(at) * 2, hi = min(s.count, (Int(at) + n) * 2)
            return lo < hi ? Array(s[lo..<hi]) : []
        }, channels: 2, frames: 300_000))
        for (lo, hi) in [(0, 300_000), (12_345, 12_600), (256, 512), (299_000, 300_000), (70_000, 170_001)] {
            for ch in 0..<2 {
                let (mn, mx) = try #require(index.minMax(channel: ch, Int64(lo)..<Int64(hi)))
                // Blocks are 256 frames, so the answer covers whole blocks around the range.
                let blo = lo / 256 * 256, bhi = min(300_000, (hi + 255) / 256 * 256)
                let vals = stride(from: blo * 2 + ch, to: bhi * 2, by: 2).map { s[$0] }
                #expect(mn == vals.min())
                #expect(mx == vals.max())
            }
        }
        let dir = TempDir()
        try index.write(to: dir.file("p.peaks"))
        let back = try #require(PeakIndex.read(from: dir.file("p.peaks")))
        #expect(back.levels == index.levels)
    }
}

@Suite("Waveform columns")
struct WaveformTests {
    @Test("Peak mode and sample mode agree, and edits show up")
    func columns() throws {
        let frames = 200_000
        let s = noise(count: frames * 2, seed: 5)
        var (p, pool) = memoryProject(s)
        let ref = p.sources[0]
        let index = try #require(PeakIndex.build(reading: { at, n in pool.read(ref, from: at, count: n) }, channels: 2, frames: Int64(frames)))
        // 1024 frames per column: peaks and raw must give the same envelope.
        let viaPeaks = Waveform.columns(p, track: 0, start: 0, framesPerColumn: 1_024, count: 100, peaks: [ref.id: index], pool: pool)
        let viaRaw = Waveform.columns(p, track: 0, start: 0, framesPerColumn: 1_024, count: 100, peaks: [:], pool: pool)
        #expect(viaPeaks == viaRaw)
        // Silence the first half: those columns go flat.
        try p.silence(0..<100_000)
        let after = Waveform.columns(p, track: 0, start: 0, framesPerColumn: 1_024, count: 195, peaks: [ref.id: index], pool: pool)
        #expect(after[0][10] == .empty)
        #expect(after[0][150].max > 0.5)
        // Zoomed past single samples, a column shows the sample under it.
        let zoomed = Waveform.columns(p, track: 0, start: 150_000, framesPerColumn: 0.25, count: 8, peaks: [:], pool: pool)
        #expect(zoomed[1][0].max == s[150_000 * 2 + 1])
        #expect(zoomed[1][4].max == s[150_001 * 2 + 1])
    }
}
