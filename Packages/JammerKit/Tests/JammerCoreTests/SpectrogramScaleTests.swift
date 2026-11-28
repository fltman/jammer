import Testing
@testable import JammerCore

@Suite("The spectrogram's frequency scale: ticks that fit, and the frequency under the pointer")
struct SpectrogramScaleTests {
    @Test("The scale and its inverse agree; the bottom is the low end and the top the high")
    func mapping() {
        for f in [50.0, 120, 440, 1_000, 3_500, 16_000] {
            let y = SpectrogramScale.y(of: f, low: 50, high: 16_000, height: 200)
            #expect(abs(SpectrogramScale.hz(atY: y, low: 50, high: 16_000, height: 200) / f - 1) < 1e-9, "\(f) Hz")
        }
        #expect(SpectrogramScale.y(of: 16_000, low: 50, high: 16_000, height: 200) == 0)
        #expect(SpectrogramScale.y(of: 50, low: 50, high: 16_000, height: 200) == 199)
    }

    @Test("Ticks: more in a tall lane, fewer in a low one, never crowded, never at the ends")
    func ticks() {
        let tall = SpectrogramScale.ticks(low: 50, high: 16_000, height: 300)
        let low = SpectrogramScale.ticks(low: 50, high: 16_000, height: 48)
        #expect(tall == [100, 200, 500, 1_000, 2_000, 5_000, 10_000])
        #expect(!low.isEmpty && low.count < tall.count)
        for list in [tall, low] {
            let ys = list.map { SpectrogramScale.y(of: $0, low: 50, high: 16_000, height: list == tall ? 300 : 48) }
            #expect(zip(ys, ys.dropFirst()).allSatisfy { $0 - $1 >= 14 }, "\(list)")
        }
        #expect(SpectrogramScale.ticks(low: 50, high: 16_000, height: 20).count <= 1)
        #expect(SpectrogramScale.ticks(low: 50, high: 8_000, height: 300).allSatisfy { $0 < 8_000 }, "a 16 kHz document's ticks stop under its top")
    }

    @Test("Said: ticks short, the readout with its unit")
    func words() {
        #expect(SpectrogramScale.tick(100) == "100" && SpectrogramScale.tick(1_000) == "1k" && SpectrogramScale.tick(10_000) == "10k")
        #expect(SpectrogramScale.readout(840.4) == (840, 0, false))
        #expect(SpectrogramScale.readout(1_234) == (1.234, 2, true) && SpectrogramScale.readout(12_000).decimals == 1)
    }
}
