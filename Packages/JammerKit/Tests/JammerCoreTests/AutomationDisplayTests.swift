import Foundation
import Testing
@testable import JammerCore

/// What a window draws for a lane is taken from the curve the engine is given, not read from the points
/// a second time. These hold the two together.
@Suite("Automation as it is shown")
struct AutomationDisplayTests {
    static func pts(_ list: [(Frame, Double)]) -> [AutomationPoint] { list.map { AutomationPoint(frame: $0.0, value: $0.1) } }

    @Test("The shown line is what plays: with the group's lane in it and the fader on top, the sound follows it within 0.003 dB at every sample")
    func line() throws {
        var (p, pool) = AutomationTests.oneTrack()
        let plain = MixerTests.render(p, pool)
        let t = p.tracks[0].id
        #expect(p.shownLane(.gain, of: t) == nil)
        p.tracks[0].gainDB = -3
        let group = try p.addVCA(name: "Voices")
        try p.setVCA(group.id, gainDB: -2)
        try p.setMember(t, vca: group.id)
        try p.setAutomation(strip: t, points: Self.pts([(1_000, -3), (6_000, 3), (15_000, -6)]))
        try p.setAutomation(strip: group.id, points: Self.pts([(2_000, 0), (10_000, -12)]))
        let shown = try #require(p.shownLane(.gain, of: t))
        #expect(shown.plays && shown.own && shown.group == group.id && shown.onTopDB == -5)
        #expect(shown.frames == [1_000, 2_000, 6_000, 10_000, 15_000] && shown.points.map(\.frame) == shown.frames)
        let heard = MixerTests.render(p, pool)
        var worst = 0.0, compared = 0
        for i in 0..<Int(p.length) where abs(plain[i * 2]) > 0.02 {
            let db = 20 * log10(Double(heard[i * 2] / plain[i * 2]))
            worst = max(worst, abs(db - (shown.value(at: Frame(i)) + shown.onTopDB)))
            compared += 1
        }
        #expect(compared > 10_000 && worst < 0.003, "worst \(worst) dB over \(compared) samples")

        // A member without a lane of its own shows the group's, and says it isn't its own.
        try p.clearAutomation(strip: t, param: .gain)
        let groups = try #require(p.shownLane(.gain, of: t))
        #expect(!groups.own && groups.group == group.id && groups.frames == [2_000, 10_000] && groups.values == [0, -12])
        // The group itself: its lane as written, with its own fader on top.
        let g = try #require(p.shownLane(.gain, of: group.id))
        #expect(g.plays && g.group == nil && g.onTopDB == -2 && g.values == [0, -12])
        // Switched off: nothing plays, and the line says so.
        try p.setAutomation(strip: group.id, points: Self.pts([(2_000, 0), (10_000, -12)]), enabled: false)
        #expect(p.shownLane(.gain, of: t) == nil && p.shownLane(.gain, of: group.id)?.plays == false)
        #expect(MixerTests.render(p, pool).elementsEqual(plain.map { $0 * Float(dbToGain(-5)) }) { abs($0 - $1) < 1e-7 })
    }

    @Test("A shown mute has the ramps the engine makes, and its points are the changes; a shown pan is the pan the engine follows")
    func muteAndPan() throws {
        var (p, pool) = AutomationTests.oneTrack()
        let plain = MixerTests.render(p, pool)
        let t = p.tracks[0].id
        try p.setAutomation(strip: t, param: .mute, points: Self.pts([(0, 0), (5_000, 1), (5_500, 1), (8_000, 0)]))
        let mute = try #require(p.shownLane(.mute, of: t))
        #expect(mute.frames == [0, 5_000, 5_240, 8_000, 8_240] && mute.values == [1, 1, 0, 0, 1])
        #expect(mute.points == Self.pts([(0, 0), (5_000, 1), (8_000, 0)]))
        let heard = MixerTests.render(p, pool)
        var worst = 0.0
        for i in 0..<Int(p.length) where abs(plain[i * 2]) > 0.02 {
            worst = max(worst, abs(Double(heard[i * 2] / plain[i * 2]) - mute.value(at: Frame(i))))
        }
        #expect(worst < 0.001, "worst \(worst)")
        // Switched off: a step as written, with no ramp claimed.
        try p.setAutomation(strip: t, param: .mute, points: Self.pts([(0, 0), (5_000, 1), (8_000, 0)]), enabled: false)
        let off = try #require(p.shownLane(.mute, of: t))
        #expect(!off.plays && off.value(at: 4_998) == 1 && off.value(at: 5_000) == 0 && off.value(at: 7_998) == 0 && off.value(at: 8_000) == 1)
        try p.clearAutomation(strip: t, param: .mute)

        try p.setAutomation(strip: t, param: .pan, points: Self.pts([(0, -1), (20_000, 1)]))
        let pan = try #require(p.shownLane(.pan, of: t))
        #expect(pan.plays && pan.value(at: 10_000) == 0 && pan.onTopDB == 0)
        let panned = MixerTests.render(p, pool)
        var off2 = 0.0
        for i in stride(from: 0, to: 20_000, by: 7) where abs(plain[i * 2]) > 0.02 {
            let want = Mixer.panGains(pan.value(at: Frame(i)))
            off2 = max(off2, abs(Double(panned[i * 2] / plain[i * 2]) - Double(want.0)), abs(Double(panned[i * 2 + 1] / plain[i * 2 + 1]) - Double(want.1)))
        }
        #expect(off2 < 0.01, "worst \(off2)")
    }

    @Test("Heights and values go both ways, 0 dB and −24 dB sit where they are said to, and the points in view are found without walking the lane")
    func heightsAndView() {
        for v in [-96.0, -60, -24, -12, 0, 6, 24] {
            #expect(abs(Automation.value(atHeight: Automation.height(of: v, .gain), .gain) - v) < 1e-9)
        }
        #expect(Automation.height(of: 0, .gain) == 0.7 && Automation.height(of: -24, .gain) == 0.3 && Automation.height(of: 24, .gain) == 1 && Automation.height(of: -96, .gain) == 0)
        #expect(Automation.height(of: -1, .pan) == 1 && Automation.height(of: 1, .pan) == 0 && Automation.value(atHeight: 0.5, .pan) == 0)
        let lane = ShownLane(strip: UUID(), param: .gain, to: nil, frames: (0..<10_000).map { Frame($0 * 100) }, values: [Double](repeating: 0, count: 10_000),
                             plays: true, group: nil, own: true, onTopDB: 0, points: (0..<10_000).map { AutomationPoint(frame: Frame($0 * 100), value: 0) })
        let view = lane.points(in: 5_000...9_999, limit: 20)
        #expect(view.count == 50 && view.shown.count == 20 && view.shown.first?.frame == 5_000)
        #expect(lane.points(in: 2_000_000...3_000_000, limit: 20).count == 0)
    }
}
