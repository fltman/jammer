import Foundation
import Testing
@testable import JammerCore

@Suite("Loudness presets")
struct LoudnessPresetTests {
    func m(_ i: Double, _ tp: Double) -> LoudnessResult {
        LoudnessResult(integrated: i, range: 5, maxMomentary: nil, maxShortTerm: nil, samplePeak: tp, truePeak: tp, duration: 60)
    }

    @Test("Reaches the target when the peaks allow it, stops at the ceiling when not")
    func plans() {
        let a = LoudnessPreset.applePodcasts.plan(for: m(-22, -9))!
        #expect(a.gainDB == 6 && a.integratedAfter == -16 && !a.limitedByPeak)
        let b = LoudnessPreset.applePodcasts.plan(for: m(-22, -4))!
        #expect(b.gainDB == 3 && b.truePeakAfter == -1 && b.limitedByPeak && b.integratedAfter == -19)
        let c = LoudnessPreset.atscA85.plan(for: m(-18, -3))!
        #expect(c.gainDB == -6 && !c.limitedByPeak)
        #expect(LoudnessPreset.ebuR128.plan(for: LoudnessResult(integrated: nil, range: nil, maxMomentary: nil, maxShortTerm: nil, samplePeak: -.infinity, truePeak: -.infinity, duration: 1)) == nil)
    }

    @Test("End to end on a real signal: the measured result meets the preset")
    func endToEnd() throws {
        let s = sine(1_000, amplitudeDB: -30, seconds: 10)
        var (p, pool) = memoryProject(s)
        let before = LoudnessMeter.measure(PlanCompiler.compile(p, pool: pool), 0..<p.length)
        let plan = try #require(LoudnessPreset.applePodcasts.plan(for: before))
        try p.changeGain(0..<p.length, by: plan.gainDB)
        let after = LoudnessMeter.measure(PlanCompiler.compile(p, pool: pool), 0..<p.length)
        #expect(abs((after.integrated ?? 0) - (-16)) < 0.1)
        #expect(after.truePeak <= -1 + 0.05)
    }
}
