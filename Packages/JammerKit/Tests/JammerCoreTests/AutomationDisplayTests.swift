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

    @Test("A point moved by hand stops one frame short of its neighbours, stays on the timeline and inside its values; a point is never added onto another")
    func byHand() {
        let lane = AutomationLane(strip: UUID(), points: Self.pts([(100, 0), (200, -6), (300, -12)]))
        #expect(lane.placed(1, frame: 50, value: -6, limit: 1_000) == AutomationPoint(frame: 101, value: -6))
        #expect(lane.placed(1, frame: 900, value: -6, limit: 1_000) == AutomationPoint(frame: 299, value: -6))
        #expect(lane.placed(1, frame: 250, value: 99, limit: 1_000) == AutomationPoint(frame: 250, value: 24))
        #expect(lane.placed(0, frame: -40, value: -200, limit: 1_000) == AutomationPoint(frame: 0, value: -96))
        #expect(lane.placed(2, frame: 5_000, value: 0, limit: 1_000) == AutomationPoint(frame: 1_000, value: 0))
        // With a neighbour on each of the frames beside it, it has nowhere to go in time; its value still moves.
        let tight = AutomationLane(strip: UUID(), points: Self.pts([(10, 0), (11, 0), (12, 0)]))
        #expect(tight.placed(1, frame: 500, value: -3, limit: 1_000) == AutomationPoint(frame: 11, value: -3))
        #expect(lane.moving(1, frame: 0, value: -6, limit: 1_000).points.map(\.frame) == [100, 101, 300])
        let added = lane.adding(frame: 150, value: -3)
        #expect(added?.index == 1 && added?.lane.points.map(\.frame) == [100, 150, 200, 300])
        #expect(lane.adding(frame: 200, value: 0) == nil && lane.adding(frame: 400, value: 0)?.index == 3)
        let mute = AutomationLane(strip: UUID(), param: .mute, shape: .hold, points: Self.pts([(0, 0), (500, 1)]))
        #expect(mute.placed(1, frame: 700, value: 0.7, limit: 1_000).value == 1 && mute.adding(frame: 800, value: 0.2)?.lane.points.last?.value == 0)
        // The keys give exact values.
        #expect(Automation.stepped(-3.04, by: 0.5, grain: 0.1, .gain) == -2.5 && Automation.stepped(-2.5, by: -0.1, grain: 0.1, .gain) == -2.6)
        #expect(Automation.stepped(23.9, by: 3, grain: 0.1, .gain) == 24 && Automation.stepped(0.97, by: 0.05, grain: 0.01, .pan) == 1)
        #expect(Automation.stepped(1, by: 0.5, grain: 0.1, .mute) == 0 && Automation.stepped(0, by: -0.5, grain: 0.1, .mute) == 1)
    }

    @Test("Several points moved together go as one piece: it stops a frame short of a neighbour that isn't moving, at the timeline's ends and at the edge of the values, and keeps its shape")
    func together() {
        let lane = AutomationLane(strip: UUID(), points: Self.pts([(100, 0), (200, -6), (300, -12), (400, -3), (500, 0)]))
        // The middle two, to the right: the piece stops with its last point one frame before the point at 400, which is not moving.
        #expect(lane.moving([1, 2], byFrames: 500, byValue: 0, limit: 10_000).points.map(\.frame) == [100, 299, 399, 400, 500])
        #expect(lane.moving([1, 2], byFrames: -500, byValue: 0, limit: 10_000).points.map(\.frame) == [100, 101, 201, 400, 500])
        // Two that aren't beside each other: each is held by its own neighbours, and the tighter one decides.
        #expect(lane.moving([1, 3], byFrames: 500, byValue: 0, limit: 10_000).points.map(\.frame) == [100, 299, 300, 499, 500])
        // All of them: only the timeline's ends hold them.
        #expect(lane.moving([0, 1, 2, 3, 4], byFrames: -1_000, byValue: 0, limit: 10_000).points.map(\.frame) == [0, 100, 200, 300, 400])
        #expect(lane.moving([0, 1, 2, 3, 4], byFrames: 1_000, byValue: 0, limit: 700).points.map(\.frame) == [300, 400, 500, 600, 700])
        // Values: the piece stops when its highest reaches the top (or its lowest the bottom); the differences stay.
        #expect(lane.moving([1, 2], byFrames: 0, byValue: 100, limit: 10_000).points.map(\.value) == [0, 24, 18, -3, 0])
        #expect(lane.moving([1, 2], byFrames: 0, byValue: -100, limit: 10_000).points.map(\.value) == [0, -90, -96, -3, 0])
        #expect(lane.moving([1, 2], byFrames: 10, byValue: 1.5, limit: 10_000).points[1...2].map { [$0.value] } == [[-4.5], [-10.5]])
        // A mute's values stay; nothing chosen, or an index that isn't there, changes nothing.
        let mute = AutomationLane(strip: UUID(), param: .mute, shape: .hold, points: Self.pts([(0, 0), (500, 1), (900, 0)]))
        #expect(mute.moving([1, 2], byFrames: 50, byValue: 1, limit: 10_000).points == Self.pts([(0, 0), (550, 1), (950, 0)]))
        #expect(lane.moving([], byFrames: 50, byValue: 1, limit: 10_000) == lane && lane.moving([9], byFrames: 50, byValue: 1, limit: 10_000) == lane)
    }

    @Test("A pass written from a fader: the line is within 0.1 dB of what was heard at every frame of it, in far fewer points; outside the stretch the lane is what it was, at every frame; a pass of nothing changes nothing")
    func written() {
        // What a hand does over 30 s, as the engine would have put it on: a value a block (512 frames), wandering.
        var heard: [AutomationPoint] = []
        var v = -6.0, seed: UInt64 = 42
        func random() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) - 0.5 }
        var drift = 0.0
        for k in 0..<2_800 {
            if k % 90 == 0 { drift = random() * 0.25 }
            v = min(12, max(-40, v + drift + random() * 0.02))
            heard.append(AutomationPoint(frame: 100_000 + Frame(k) * 512, value: v))
        }
        let old = AutomationLane(strip: UUID(), points: Self.pts([(0, -3), (50_000, -3), (400_000, -12), (3_000_000, 0)]))
        let (lane, used) = old.written(heard)
        #expect(used == Automation.writeTolerance)
        // Within the tolerance at every frame that was heard, and between them (the engine goes straight from one block's value to the next).
        var worst = 0.0
        for (i, h) in heard.enumerated() {
            worst = max(worst, abs(lane.value(at: h.frame)! - h.value))
            if i > 0 { let mid = (heard[i - 1].frame + h.frame) / 2; worst = max(worst, abs(lane.value(at: mid)! - (heard[i - 1].value + h.value) / 2)) }
        }
        #expect(worst <= Automation.writeTolerance + 1e-9, "worst \(worst) dB")
        #expect(lane.points.count < 400 && lane.points.count > 10, "\(lane.points.count) points for \(heard.count) heard")
        // Outside the stretch: the same level as before at every frame looked at, right up to its edges.
        let a = heard.first!.frame, b = heard.last!.frame
        for f in [Frame(0), 49_999, 50_000, 75_000, a - 2, a - 1, b + 1, b + 2, 2_000_000, 3_000_000, 4_000_000] {
            #expect(abs(lane.value(at: f)! - old.value(at: f)!) < 1e-9, "at \(f)")
        }
        #expect(lane.points.map(\.frame) == lane.points.map(\.frame).sorted() && Set(lane.points.map(\.frame)).count == lane.points.count)
        // Where there was no lane: nothing is added outside the stretch, before it or after it.
        let fresh = AutomationLane(strip: UUID(), points: []).written(heard).lane
        #expect(fresh.value(at: a - 1) == 0 && fresh.value(at: 0) == 0 && fresh.value(at: b + 1) == 0 && fresh.value(at: 9_000_000) == 0)
        #expect(abs(fresh.value(at: heard[1_000].frame)! - heard[1_000].value) <= Automation.writeTolerance)
        // A pass of nothing; and a pass of one value.
        #expect(old.written([]).lane == old)
        let one = old.written([AutomationPoint(frame: 200_000, value: -20)]).lane
        #expect(one.value(at: 200_000) == -20 && abs(one.value(at: 199_999)! - old.value(at: 199_999)!) < 1e-9 && abs(one.value(at: 200_001)! - old.value(at: 200_001)!) < 1e-9)
        // A steady hand is two points; and a pass too long for a lane is thinned further, and says so.
        #expect(Automation.thinned((0..<1_000).map { AutomationPoint(frame: Frame($0), value: -6) }, tolerance: 0.1).count == 2)
        let wild = (0..<40_000).map { AutomationPoint(frame: Frame($0) * 64, value: $0 % 2 == 0 ? -1 : 1) }
        let long = AutomationLane(strip: UUID(), points: []).written(wild)
        #expect(long.lane.points.count <= Automation.maxPoints && long.tolerance > Automation.writeTolerance)
    }
}
