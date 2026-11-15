import Foundation
import Testing
@testable import JammerCore

@Suite("Delivering at a loudness target")
struct LoudnessDeliveryTests {
    /// A pretend encoder: the file comes out `shift` LU off what went in, peaks `overshoot` dB up.
    func run(mix: Double, peak: Double, shift: Double, overshoot: Double = 0, target: LoudnessDelivery.Target) -> (LoudnessDelivery, [Double]) {
        var gains: [Double] = [], last = 0.0
        let d = LoudnessDelivery.deliver(target, encode: { g in gains.append(g); last = g }, measure: {
            LoudnessResult(integrated: mix + last + shift, range: nil, maxMomentary: nil, maxShortTerm: nil, samplePeak: peak + last,
                           truePeak: peak + last + overshoot, duration: 10)
        })
        return (d, gains)
    }

    @Test("On target at once: one encode, nothing added")
    func onTarget() {
        let (d, gains) = run(mix: -16, peak: -6, shift: 0.02, target: .init(integrated: -16))
        #expect(gains == [0] && d.encodes == 1 && d.compensatedDB == 0 && !d.limitedByPeak)
    }

    @Test("The encoder takes 0.4 LU: corrected in one more encode")
    func corrected() {
        let (d, gains) = run(mix: -14, peak: -6, shift: -0.4, target: .init(integrated: -14))
        #expect(gains.count == 2 && abs(gains[1] - 0.4) < 1e-9)
        #expect(d.encodes == 2 && d.compensatedDB == 0.4 && abs(d.loudness! + 14) < 0.001 && !d.limitedByPeak)
    }

    @Test("Never past the ceiling: the gain stops where the decoded peak reaches it, and says so")
    func ceiling() {
        // 0.4 LU to make up, but the decoded peak is already 0.1 dB under the ceiling.
        let (d, _) = run(mix: -14, peak: -1.6, shift: -0.4, overshoot: 0.5, target: .init(integrated: -14, ceiling: -1))
        #expect(d.truePeak! <= -1 + 1e-9 && d.limitedByPeak && abs(d.compensatedDB - 0.1) < 1e-9 && d.loudness! < -14.2)
        // The encoder alone pushes the peak past the ceiling: the gain goes down.
        let (e, _) = run(mix: -14, peak: -1.2, shift: 0, overshoot: 0.6, target: .init(integrated: -14, ceiling: -1))
        #expect(e.truePeak! <= -1 + 1e-9 && e.compensatedDB < 0 && e.limitedByPeak)
    }

    @Test("At most two corrections, and a file that can't be read back is reported as unmeasured")
    func bounds() {
        // An encoder whose shift grows with the gain never converges: three encodes, then stop.
        var encodes = 0, last = 0.0
        let d = LoudnessDelivery.deliver(.init(integrated: -14), encode: { g in encodes += 1; last = g }, measure: {
            LoudnessResult(integrated: -15 + last * 0.5, range: nil, maxMomentary: nil, maxShortTerm: nil, samplePeak: -20, truePeak: -20, duration: 10)
        })
        #expect(encodes == 3 && d.encodes == 3)
        let u = LoudnessDelivery.deliver(.init(integrated: -14), encode: { _ in }, measure: { nil })
        #expect(u.loudness == nil && u.encodes == 1 && u.compensatedDB == 0)
    }
}
