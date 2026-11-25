import Foundation
import JammerEngine
import Testing
@testable import JammerCore

/// Automation, step 1: gain lanes on tracks, buses and the master (docs/MIXER.md, "Automation").
@Suite("Mixer: automation of levels")
struct AutomationTests {
    static let n = MixerGraphTests.n
    /// A steady source (0.25 on the left, half on the right), so that what a sample was multiplied by can be read off it.
    static func steady() -> OpaquePointer {
        var x = [Float](repeating: 0, count: n * 2)
        for i in 0..<n { x[i * 2] = 0.25; x[i * 2 + 1] = 0.125 }
        return x.withUnsafeBufferPointer { jm_source_create_memory($0.baseAddress!, Int64(n), 2) }
    }
    static func curve(_ plan: OpaquePointer, kind: Int32, index: Int32, _ points: [(Int64, Float)]) {
        jm_plan_set_gain_curve(plan, kind, index, points.map(\.0), points.map(\.1), Int32(points.count))
    }
    /// What the dB line through `points` is at frame `t`, as a gain.
    static func line(_ points: [(Int64, Float)], _ t: Int) -> Double {
        if Int64(t) <= points.first!.0 { return pow(10, Double(points.first!.1) / 20) }
        if Int64(t) >= points.last!.0 { return pow(10, Double(points.last!.1) / 20) }
        let i = points.firstIndex { $0.0 > Int64(t) }!
        let a = points[i - 1], b = points[i]
        return pow(10, (Double(a.1) + Double(b.1 - a.1) * Double(Int64(t) - a.0) / Double(b.0 - a.0)) / 20)
    }
    static func oneTrack() -> (Project, SourcePool) {
        var (p, pool) = MixerTests.document()
        p.tracks = [p.tracks[0]]
        return (p, pool)
    }
    static func points(_ list: [(Double, Double)], _ p: Project) -> [AutomationPoint] { list.map { AutomationPoint(frame: p.frames($0.0), value: $0.1) } }

    @Test("Without a lane nothing is different; a lane of 0 dB is the same sound; a lane makes the project format 3")
    func untouched() throws {
        var (p, pool) = Self.oneTrack()
        let plain = MixerTests.render(p, pool)
        let first = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
        #expect(!p.usesAutomation && !first.contains("automation"))
        try p.setAutomation(strip: p.tracks[0].id, points: [AutomationPoint(frame: 0, value: 0), AutomationPoint(frame: p.length, value: 0)])
        #expect(MixerTests.render(p, pool) == plain)
        let json = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
        #expect(p.usesAutomation && json.contains("\"formatVersion\":3") && json.contains("\"automation\""))
        #expect(try JSONDecoder().decode(Project.self, from: Data(json.utf8)) == p)
        // A file marked with a format this build doesn't know is refused in words, not opened without what it has.
        let newer = json.replacingOccurrences(of: "\"formatVersion\":3", with: "\"formatVersion\":\(Project.newestFormatVersion + 1)")
        #expect(throws: Project.NeedsNewer(version: Project.newestFormatVersion + 1)) { try JSONDecoder().decode(Project.self, from: Data(newer.utf8)) }
        // (A build from before automation knew formats up to 2 and refuses 3 by the same check; format 4 is a document wider than stereo.)
        #expect(Project.automationFormatVersion == 3 && Project.immersiveFormatVersion == 4 && Project.fieldFormatVersion == 5 && Project.orderFormatVersion == 6 && Project.voiceFormatVersion == 7 && Project.takeFormatVersion == 8 && Project.newestFormatVersion == 8)
        // Cleared, it is the project it was.
        let cleared = try p.clearAutomation(strip: p.tracks[0].id, param: .gain)
        #expect(cleared == 2)
        let again = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
        #expect(!p.usesAutomation && again.contains("\"formatVersion\":1"))
        // A copy made to render one track by itself has no lanes.
        try p.setAutomation(strip: p.tracks[0].id, points: [AutomationPoint(frame: 0, value: -6)])
        var solo = p
        solo.withoutMixer()
        #expect(!solo.usesAutomation)
        // A lane whose strip is gone is not saved and not heard.
        var gone = p
        gone.automation[0].strip = UUID()
        #expect(!gone.usesAutomation && MixerTests.render(gone, pool) == plain)
    }

    @Test("A lane is added to the fader: a constant one is a gain, and a ramp follows the dB line without steps, each point on its own frame")
    func shape() {
        let s = Self.steady()
        defer { jm_source_release(s) }
        func render(gain: Float, _ points: [(Int64, Float)]) -> [Float] {
            let plan = jm_plan_create(2, 48_000)
            let t = MixerGraphTests.track(plan, s, gain: gain)
            Self.curve(plan, kind: 0, index: t, points)
            jm_plan_finalize(plan)
            defer { jm_plan_release(plan) }
            return MixerGraphTests.render(plan)
        }
        // Constant: the fader's gain times the lane's.
        let flat = render(gain: 0.5, [(0, -6)])
        let g = Float(0.5) * Float(pow(10, -6.0 / 20))
        #expect(flat.enumerated().allSatisfy { abs($0.element - ($0.offset % 2 == 0 ? 0.25 : 0.125) * g) < 1e-7 })
        // A fade from 0 to −40 dB between frames 1 000 and 13 000 (160 dB a second), then up 30 dB in 100 frames (14 400 dB a second).
        let pts: [(Int64, Float)] = [(1_000, 0), (13_000, -40), (13_100, -10)]
        let y = render(gain: 1, pts)
        var worst = 0.0, worstFast = 0.0, biggestStep = 0.0
        for i in 0..<Self.n {
            let got = Double(y[i * 2]) / 0.25, want = Self.line(pts, i)
            let off = abs(20 * log10(got / want))
            if i < 13_000 { worst = max(worst, off) } else { worstFast = max(worstFast, off) }
            if i > 0, i < 13_000 { biggestStep = max(biggestStep, abs(20 * log10(got / (Double(y[(i - 1) * 2]) / 0.25)))) }
            // Both channels alike.
            #expect(abs(y[i * 2 + 1] * 2 - y[i * 2]) < 1e-7)
        }
        print(String(format: "AUTOMATION off the dB line: %.5f dB at 160 dB/s, %.4f dB at 14 400 dB/s; biggest step between samples in the slow fade %.5f dB (a 512-frame block would step %.2f dB)", worst, worstFast, biggestStep, 160.0 * 512 / 48_000))
        #expect(worst < 0.001 && worstFast < 0.01)
        // No staircase: from one sample to the next the level moves by what the line moves, not by a block's worth.
        #expect(biggestStep < 0.01)
        // On the points themselves the value is the point's, exactly on that frame.
        for (f, db) in pts { #expect(abs(Double(y[Int(f) * 2]) / 0.25 - pow(10, Double(db) / 20)) < 1e-6) }
        // Before the first point and after the last: their values.
        #expect(y[0] == 0.25 && abs(Double(y[(Self.n - 1) * 2]) / 0.25 - pow(10, -10.0 / 20)) < 1e-6)
    }

    @Test("However fast a fade is, the level stays within a hundredth of a dB of the line")
    func anySpeed() {
        let s = Self.steady()
        defer { jm_source_release(s) }
        var table: [String] = [], worstOfAll = 0.0
        // 40 dB down, over anything from 2 frames to a third of a second.
        for frames in [2, 5, 16, 40, 100, 127, 128, 129, 255, 256, 257, 600, 1_500, 4_000, 16_000] {
            let pts: [(Int64, Float)] = [(1_001, 0), (Int64(1_001 + frames), -40)]
            let plan = jm_plan_create(2, 48_000)
            let t = MixerGraphTests.track(plan, s)
            Self.curve(plan, kind: 0, index: t, pts)
            jm_plan_finalize(plan)
            let y = MixerGraphTests.render(plan)
            jm_plan_release(plan)
            var worst = 0.0
            for i in 0..<Self.n { worst = max(worst, abs(20 * log10(Double(y[i * 2]) / 0.25 / Self.line(pts, i)))) }
            worstOfAll = max(worstOfAll, worst)
            table.append(String(format: "%.0f dB/s: %.5f", 40.0 / Double(frames) * 48_000, worst))
        }
        print("AUTOMATION off the dB line by speed: " + table.joined(separator: "; "))
        #expect(worstOfAll < 0.01)
    }

    @Test("What a frame is multiplied by depends only on where it is on the timeline: blocks of any size and a seek give the same samples, bit for bit")
    func position() {
        let s = Self.steady(), tone = MixerGraphTests.source(331)
        defer { jm_source_release(s); jm_source_release(tone) }
        func plan() -> OpaquePointer {
            let plan = jm_plan_create(2, 48_000)
            let t = MixerGraphTests.track(plan, s), _ = MixerGraphTests.track(plan, tone)
            Self.curve(plan, kind: 0, index: t, [(777, 0), (9_001, -30), (15_000, 3)])
            Self.curve(plan, kind: 2, index: 0, [(100, -3), (19_000, 0)])
            jm_plan_finalize(plan)
            return plan
        }
        let a = plan()
        let whole = MixerGraphTests.render(a)
        jm_plan_release(a)
        for block in [1, 63, 64, 500, 512, 4_099] {
            let b = plan()
            var got: [Float] = []
            var at = 0
            while at < Self.n { let k = min(block, Self.n - at); got += MixerGraphTests.render(b, from: at, frames: k); at += k }
            jm_plan_release(b)
            #expect(got == whole, "blocks of \(block)")
        }
        let c = plan()
        for (from, frames) in [(9_000, 3_000), (0, 100), (14_990, 2_000), (5, 700)] {
            #expect(MixerGraphTests.render(c, from: from, frames: frames) == Array(whole[(from * 2)..<((from + frames) * 2)]), "seek to \(from)")
        }
        jm_plan_release(c)
    }

    @Test("Automation lands where it was drawn whatever plugins are before it: on a track with latency, on a bus with latency, and on the master")
    func withLatency() {
        let s = Self.steady()
        defer { jm_source_release(s) }
        let pts: [(Int64, Float)] = [(4_000, 0), (4_001, -20), (12_000, -20), (12_001, 0)]
        // No plugin anywhere: what the lane gives.
        func render(_ build: (OpaquePointer, Int32) -> Void) -> [Float] {
            let plan = jm_plan_create(2, 48_000)
            let t = MixerGraphTests.track(plan, s)
            build(plan, t)
            jm_plan_finalize(plan)
            defer { jm_plan_release(plan) }
            return MixerGraphTests.render(plan)
        }
        let want = render { plan, t in Self.curve(plan, kind: 0, index: t, pts) }
        #expect(want[3_999 * 2] == 0.25 && abs(want[4_001 * 2] - 0.025) < 1e-7 && want[12_001 * 2] == 0.25)
        for latency in [1, 100, 512, 777] {
            // A plugin on the track, the lane on the track.
            let onTrack = render { plan, t in
                let c = MixerGraphTests.chain([DelayPlugin(latency: latency)]); jm_plan_set_chain(plan, t, c); jm_chain_release(c)
                Self.curve(plan, kind: 0, index: t, pts)
            }
            #expect(onTrack == want, "track, latency \(latency)")
            // The track into a bus with a plugin, the lane on the bus.
            let onBus = render { plan, t in
                let bus = jm_plan_add_bus(plan, 1, false, 1, 1)
                jm_plan_set_track_route(plan, t, bus, 1, 1)
                let c = MixerGraphTests.chain([DelayPlugin(latency: latency)]); jm_plan_set_bus_chain(plan, bus, c); jm_chain_release(c)
                Self.curve(plan, kind: 1, index: bus, pts)
            }
            #expect(onBus == want, "bus, latency \(latency)")
            // Plugins on the track and on the master, the lane on the master.
            let onMaster = render { plan, t in
                let c = MixerGraphTests.chain([DelayPlugin(latency: latency)]); jm_plan_set_chain(plan, t, c); jm_chain_release(c)
                let m = MixerGraphTests.chain([DelayPlugin(latency: 33)]); jm_plan_set_master(plan, 1, m, nil); jm_chain_release(m)
                Self.curve(plan, kind: 2, index: 0, pts)
            }
            #expect(onMaster == want, "master, latency \(latency)")
        }
    }

    @Test("A send after the fader follows the lane, a send before it doesn't; a curve that isn't one is not half used")
    func sends() {
        let s = Self.steady()
        defer { jm_source_release(s) }
        func render(pre: Bool, _ points: [(Int64, Float)] = [(0, -20)]) -> [Float] {
            let plan = jm_plan_create(2, 48_000)
            let t = MixerGraphTests.track(plan, s)
            let dry = jm_plan_add_bus(plan, 1, true, 1, 1), wet = jm_plan_add_bus(plan, 1, false, 1, 1)
            jm_plan_set_track_route(plan, t, dry, 1, 1)   // the track's own way out ends in a muted bus: only the send is heard
            jm_plan_add_track_send(plan, t, wet, 1, pre)
            Self.curve(plan, kind: 0, index: t, points)
            jm_plan_finalize(plan)
            defer { jm_plan_release(plan) }
            return MixerGraphTests.render(plan)
        }
        #expect(render(pre: true).allSatisfy { $0 == 0.25 || $0 == 0.125 })
        #expect(render(pre: false).enumerated().allSatisfy { abs($0.element - ($0.offset % 2 == 0 ? 0.025 : 0.0125)) < 1e-7 })
        // Frames that don't rise, or a value that isn't a number: no curve at all.
        #expect(render(pre: false, [(100, -20), (100, 0)]).allSatisfy { $0 == 0.25 || $0 == 0.125 })
        #expect(render(pre: false, [(100, -20), (50, 0)]).allSatisfy { $0 == 0.25 || $0 == 0.125 })
        #expect(render(pre: false, [(100, .nan)]).allSatisfy { $0 == 0.25 || $0 == 0.125 })
    }

    @Test("In a project: lanes on a track, a bus and the master are heard as written, with the VCA and the fader")
    func inProject() throws {
        var (p, pool) = MixerTests.document()
        let plain = MixerTests.render(p, pool)
        let end = p.length
        // The master, constant −6: everything, once.
        try p.setAutomation(strip: Master.id, points: [AutomationPoint(frame: 0, value: -6)])
        let g = Float(dbToGain(-6))
        #expect(zip(MixerTests.render(p, pool), plain).allSatisfy { abs($0 - $1 * g) < 1e-7 })
        #expect(p.level(of: Master.id, at: 10)?.totalDB == -6)
        try p.clearAutomation(strip: Master.id, param: .gain)
        // A bus that everything goes through, constant −6: the same.
        let bus = try p.addBus(name: "All")
        for t in p.tracks { try p.setTrackRoute(t.id, output: .some(bus.id)) }
        try p.setAutomation(strip: bus.id, points: [AutomationPoint(frame: end / 2, value: -6)])
        #expect(zip(MixerTests.render(p, pool), plain).allSatisfy { abs($0 - $1 * g) < 1e-7 })
        // Switched off, the lane is kept and not heard.
        try p.setAutomation(strip: bus.id, points: p.lane(strip: bus.id, param: .gain)!.points, enabled: false)
        #expect(p.usesAutomation && zip(MixerTests.render(p, pool), plain).allSatisfy { abs($0 - $1) < 1e-7 })
        // The level at a time: fader, VCA and lane together.
        var q = p
        q.automation = []
        let t = q.tracks[0].id
        q.tracks[0].gainDB = -3
        let vca = try q.addVCA(name: "V")
        try q.setVCA(vca.id, gainDB: -2)
        try q.setMember(t, vca: vca.id)
        try q.setAutomation(strip: t, points: [AutomationPoint(frame: 0, value: 0), AutomationPoint(frame: 1_000, value: -10)])
        let level = try #require(q.level(of: t, at: 500))
        #expect(level.faderDB == -5 && level.automationDB == -5 && level.totalDB == -10 && !level.muted)
        #expect(q.level(of: UUID(), at: 0) == nil)
    }

    @Test("Writing a lane: only inside the range given, nothing outside it; and what is refused, by name")
    func writing() throws {
        var (p, _) = Self.oneTrack()
        let t = p.tracks[0].id, end = p.seconds(p.length)
        try p.setAutomation(strip: t, points: Self.points([(0, 0), (0.1, -6), (0.2, -12), (0.3, 0)], p))
        // Replace what is between 0.05 and 0.25 s with one point: the points at 0 and 0.3 stay as they were.
        try p.setAutomation(strip: t, points: Self.points([(0.15, -3)], p), range: p.frames(0.05)...p.frames(0.25))
        #expect(p.lane(strip: t, param: .gain)?.points == Self.points([(0, 0), (0.15, -3), (0.3, 0)], p))
        // Clear a range; then all.
        let some = try p.clearAutomation(strip: t, param: .gain, range: p.frames(0.1)...p.frames(0.2))
        #expect(some == 1)
        #expect(p.lane(strip: t, param: .gain)?.points.count == 2)
        // Points given out of order are sorted.
        try p.setAutomation(strip: t, points: Self.points([(0.3, -1), (0.1, -2)], p))
        #expect(p.lane(strip: t, param: .gain)?.points.map(\.value) == [-2, -1])
        let before = p
        func refused(_ what: String, _ body: () throws -> Void) {
            do { try body(); Issue.record("not refused: \(what)") } catch let e as Automation.Failure {
                #expect(e.errorDescription?.contains(what) == true, "\(e.errorDescription ?? "")")
            } catch { Issue.record("\(error)") }
        }
        refused("points[1]") { try p.setAutomation(strip: t, points: Self.points([(0, 0), (end + 1, 0)], p)) }
        refused("points[0]") { try p.setAutomation(strip: t, points: [AutomationPoint(frame: -1, value: 0)]) }
        refused("points[0] has the value 30") { try p.setAutomation(strip: t, points: Self.points([(0, 30)], p)) }
        refused("points[0]") { try p.setAutomation(strip: t, points: [AutomationPoint(frame: 0, value: .nan)]) }
        refused("outside the range given") { try p.setAutomation(strip: t, points: Self.points([(0.3, 0)], p), range: p.frames(0)...p.frames(0.2)) }
        refused("two points") { try p.setAutomation(strip: t, points: Self.points([(0.1, 0), (0.1, -3)], p)) }
        refused("no track, bus or VCA group") { try p.setAutomation(strip: UUID(), points: []) }
        refused("has no send") { try p.setAutomation(strip: t, param: .send, to: UUID(), points: [AutomationPoint(frame: 0, value: -6)]) }
        refused("has no send") { try p.setAutomation(strip: t, param: .send, points: [AutomationPoint(frame: 0, value: -6)]) }
        refused("goes with a send lane only") { try p.setAutomation(strip: t, param: .gain, to: UUID(), points: [AutomationPoint(frame: 0, value: -6)]) }
        refused("a pan is −1 (left) to 1 (right)") { try p.setAutomation(strip: t, param: .pan, points: [AutomationPoint(frame: 0, value: 2)]) }
        refused("a mute is 1 (muted) or 0 (heard)") { try p.setAutomation(strip: t, param: .mute, points: [AutomationPoint(frame: 0, value: 0.5)]) }
        refused("holds each value") { try p.setAutomation(strip: t, param: .mute, points: [AutomationPoint(frame: 0, value: 1)], shape: .linear) }
        refused("not a pan, a mute or a send") { try p.setAutomation(strip: Master.id, param: .pan, points: [AutomationPoint(frame: 0, value: 0)]) }
        refused("not a pan, a mute or a send") { try p.setAutomation(strip: Master.id, param: .mute, points: [AutomationPoint(frame: 0, value: 1)]) }
        refused("\(Automation.maxPoints) points") {
            try p.setAutomation(strip: t, points: (0...Automation.maxPoints).map { AutomationPoint(frame: Frame($0), value: 0) })
        }
        #expect(p == before)
        // The value between points, as the engine reads it.
        let lane = try #require(p.lane(strip: t, param: .gain))
        #expect(lane.value(at: 0) == -2 && lane.value(at: p.frames(0.2)) == -1.5 && lane.value(at: p.length) == -1)
    }

    @Test("Freezing: a lane on what feeds a frozen strip makes it stale; the strip's own lane, after the file, doesn't")
    func freezing() throws {
        var (p, _) = MixerTests.document()
        let bus = try p.addBus(name: "Music")
        let fed = p.tracks[0].id, other = p.tracks[1].id
        try p.setTrackRoute(fed, output: .some(bus.id))
        let was = try #require(p.content(of: bus.id)), wasTrack = try #require(p.content(of: fed))
        // The bus's own lane and the master's: after the bus's file.
        var a = p
        try a.setAutomation(strip: bus.id, points: [AutomationPoint(frame: 0, value: -6)])
        try a.setAutomation(strip: Master.id, points: [AutomationPoint(frame: 0, value: -6)])
        #expect(a.content(of: bus.id) == was)
        // A track that doesn't reach the bus.
        try a.setAutomation(strip: other, points: [AutomationPoint(frame: 0, value: -6)])
        #expect(a.content(of: bus.id) == was)
        // The track that feeds it: stale. Its own content (before its fader) is what it was.
        var b = p
        try b.setAutomation(strip: fed, points: [AutomationPoint(frame: 0, value: -6)])
        #expect(b.content(of: bus.id) != was && b.content(of: fed) == wasTrack)
        // Switched off, the lane is not in it.
        try b.setAutomation(strip: fed, points: b.lane(strip: fed, param: .gain)!.points, enabled: false)
        #expect(b.content(of: bus.id) == was)
        // The copy a strip is frozen from has neither the strip's own lanes nor the master's.
        let context = try #require(a.freezeContext(for: bus.id))
        #expect(context.lanes(of: bus.id).isEmpty && context.lanes(of: Master.id).isEmpty && context.lanes(of: other).count == 1)
    }
}

@Suite("Mixer: automation follows edits that close or open the whole timeline")
struct AutomationEditTests {
    static func lane(_ p: Project, _ id: UUID) -> [(Double, Double)] { (p.lane(strip: id, param: .gain)?.points ?? []).map { (p.seconds($0.frame), $0.value) } }

    @Test("A rippling delete moves the later points with the sound, takes away the points in what was removed, and keeps the level on each side of the cut")
    func delete() throws {
        var (p, pool) = AutomationTests.oneTrack()
        let t = p.tracks[0].id, sr = p.sampleRate
        func f(_ s: Double) -> Frame { Frame(s * sr) }
        // 0 dB until 0.1 s, down to −20 at 0.2 s, a point inside at 0.25 (−12), back to 0 at 0.3 s.
        try p.setAutomation(strip: t, points: [(0.1, 0.0), (0.2, -20), (0.25, -12), (0.3, 0)].map { AutomationPoint(frame: f($0.0), value: $0.1) })
        let before = p
        func level(_ q: Project, _ frame: Frame) -> Double { q.lane(strip: t, param: .gain)!.value(at: frame)! }
        // Cut 0.15–0.26 s: on a slope at the start, a point inside, on a slope at the end.
        let cut = f(0.15)..<f(0.26)
        try p.delete(cut)
        let n = Frame(cut.count)
        // Just before the cut and just after it, the level is what it was there.
        #expect(abs(level(p, cut.lowerBound - 1) - level(before, cut.lowerBound - 1)) < 1e-9)
        #expect(abs(level(p, cut.lowerBound) - level(before, cut.upperBound)) < 1e-9)
        // Everything later is where its sound is now, with the level it had.
        for s in [0.27, 0.3, 0.35] { #expect(abs(level(p, f(s) - n) - level(before, f(s))) < 1e-9, "\(s)") }
        // And everything before is untouched.
        for s in [0.0, 0.1, 0.12] { #expect(abs(level(p, f(s)) - level(before, f(s))) < 1e-9, "\(s)") }
        // The points inside are gone; no two at one frame; still sorted.
        let frames = p.lane(strip: t, param: .gain)!.points.map(\.frame)
        #expect(frames == frames.sorted() && Set(frames).count == frames.count && !frames.contains(f(0.2)))
        // As sound: what is left is the old render with the stretch taken out, sample for sample.
        let old = MixerTests.render(before, pool), new = MixerTests.render(p, pool)
        let ch = p.channels
        let want = Array(old[0..<(Int(cut.lowerBound) * ch)]) + Array(old[(Int(cut.upperBound) * ch)...])
        #expect(new.count == want.count)
        var worst: Float = 0
        for i in 0..<new.count { worst = max(worst, abs(new[i] - want[i])) }
        // (Within what a ramp piece differs when its ends moved: the line is the same, its pieces fall elsewhere.)
        #expect(worst < 2e-4, "\(worst)")
        // A delete that doesn't close the gap leaves the lane alone; so does one after every point where the line is flat.
        var q = before
        try q.delete(cut, ripple: false)
        #expect(q.automation == before.automation)
        var r = before
        try r.delete(f(0.32)..<f(0.34))
        #expect(r.automation == before.automation)
        // One undo: the edit is a value, and the lane is in it.
        #expect(before.lane(strip: t, param: .gain)?.points.count == 4)
    }

    @Test("An opened gap (insert, paste) moves the later points with the sound and keeps the level on each side")
    func gap() throws {
        var (p, _) = AutomationTests.oneTrack()
        let t = p.tracks[0].id, sr = p.sampleRate
        func f(_ s: Double) -> Frame { Frame(s * sr) }
        try p.setAutomation(strip: t, points: [AutomationPoint(frame: f(0.1), value: 0), AutomationPoint(frame: f(0.3), value: -20)])
        try p.setAutomation(strip: Master.id, points: [AutomationPoint(frame: f(0.2), value: -3)])
        let before = p
        func level(_ q: Project, _ frame: Frame) -> Double { q.lane(strip: t, param: .gain)!.value(at: frame)! }
        let at = f(0.2), length = f(0.05)
        p.insertGap(at: at, length: length)
        #expect(abs(level(p, at - 1) - level(before, at - 1)) < 1e-9)
        for s in [0.2, 0.25, 0.3, 0.35] { #expect(abs(level(p, f(s) + length) - level(before, f(s))) < 1e-9, "\(s)") }
        for s in [0.0, 0.1, 0.15] { #expect(abs(level(p, f(s)) - level(before, f(s))) < 1e-9, "\(s)") }
        // The master's lane is on the same timeline: its point moved too.
        #expect(p.lane(strip: Master.id, param: .gain)?.points == [AutomationPoint(frame: f(0.2) + length, value: -3)])
        // A flat lane needs no new points.
        #expect(p.lane(strip: Master.id, param: .gain)?.points.count == 1)
    }
}

@Suite("Automation in a hostile or broken project")
struct AutomationSafetyTests {
    @Test("Lanes that can't be lanes are left out or put right, in words; a good one is left alone")
    func hostile() throws {
        var (p, pool) = MixerTests.document()
        let a = p.tracks[0].id, b = p.tracks[1].id, c = p.tracks[2].id
        let good = AutomationLane(strip: a, points: [AutomationPoint(frame: 0, value: 0), AutomationPoint(frame: 1_000, value: -6)])
        p.automation = [
            good,
            AutomationLane(strip: UUID(), points: [AutomationPoint(frame: 0, value: -6)]),                       // a strip that isn't there
            AutomationLane(strip: a, points: [AutomationPoint(frame: 5, value: -60)]),                           // a twin of the first
            AutomationLane(strip: b, param: .send, to: UUID(), points: [AutomationPoint(frame: 0, value: 1)]),   // a send that isn't there
            AutomationLane(strip: b, points: [AutomationPoint(frame: 900, value: .nan), AutomationPoint(frame: -4, value: 0)]),   // nothing usable
            AutomationLane(strip: c, points: [AutomationPoint(frame: 800, value: 400), AutomationPoint(frame: 100, value: -3),    // out of order, out of range,
                                              AutomationPoint(frame: 100, value: -9), AutomationPoint(frame: .max, value: 0),     // doubled, beyond the horizon,
                                              AutomationPoint(frame: 300, value: .infinity)]),                                    // not a number
        ]
        let notes = try ProjectSafety.check(&p)
        #expect(p.automation.count == 2 && p.automation[0] == good)
        #expect(p.automation[1].points == [AutomationPoint(frame: 100, value: -3), AutomationPoint(frame: 800, value: 24)])
        #expect(notes.contains { $0.text.hasPrefix("4 automation lanes in the project were for a track or bus that isn't there") })
        #expect(notes.contains { $0.text.hasPrefix("1 automation lane had points that were out of order") })
        // It renders, and a second look finds nothing more.
        _ = MixerTests.render(p, pool)
        var again = p
        #expect(try ProjectSafety.check(&again).isEmpty && again == p)
        // Far too many points: cut to what Jämmer writes, not refused and not kept.
        var many = p
        many.automation = [AutomationLane(strip: a, points: (0..<(Automation.maxPoints + 500)).map { AutomationPoint(frame: Frame($0), value: 0) })]
        _ = try ProjectSafety.check(&many)
        #expect(many.automation[0].points.count == Automation.maxPoints)
        // Mute and pan: a mute's values become 1 or 0 and it holds; a pan is brought into range; the master has neither.
        var mp = MixerTests.document().0
        let own = mp.tracks[0].id
        mp.automation = [
            AutomationLane(strip: own, param: .mute, shape: .linear, points: [AutomationPoint(frame: 0, value: 0.7), AutomationPoint(frame: 50, value: -3)]),
            AutomationLane(strip: own, param: .pan, points: [AutomationPoint(frame: 0, value: -7)]),
            AutomationLane(strip: Master.id, param: .pan, points: [AutomationPoint(frame: 0, value: 0.5)]),
            AutomationLane(strip: Master.id, param: .mute, points: [AutomationPoint(frame: 0, value: 1)]),
        ]
        _ = try ProjectSafety.check(&mp)
        #expect(mp.automation.count == 2)
        #expect(mp.automation[0].shape == .hold && mp.automation[0].points.map(\.value) == [1, 0])
        #expect(mp.automation[1].points == [AutomationPoint(frame: 0, value: -1)])
        // A pan lane in a mono project is left out.
        var mono = MixerTests.document(channels: 1).0
        mono.automation = [AutomationLane(strip: mono.tracks[0].id, param: .pan, points: [AutomationPoint(frame: 0, value: 0.5)])]
        _ = try ProjectSafety.check(&mono)
        #expect(mono.automation.isEmpty)
        // A project without lanes is not touched by any of this.
        var none = MixerTests.document().0
        let was = none
        #expect(try ProjectSafety.check(&none).isEmpty && none == was)
    }
}

/// Automation, step 2: an automated mute and an automated pan.
@Suite("Mixer: automation of mute and pan")
struct AutomationMutePanTests {
    static let n = MixerGraphTests.n
    static func plan(_ build: (OpaquePointer, Int32) -> Void) -> [Float] {
        let s = AutomationTests.steady()
        defer { jm_source_release(s) }
        let plan = jm_plan_create(2, 48_000)
        let t = MixerGraphTests.track(plan, s)
        build(plan, t)
        jm_plan_finalize(plan)
        defer { jm_plan_release(plan) }
        return MixerGraphTests.render(plan)
    }

    @Test("A mute point closes the sound over 5 ms beginning at the point, without a jump, and opens it the same way")
    func muteHasNoClick() throws {
        var (p, pool) = AutomationTests.oneTrack()
        let t = p.tracks[0].id
        // A steady source, so that what each sample was multiplied by can be read.
        let info = p.sources[0].info
        let src = SourceRef(name: "steady", path: "/dev/null", info: info)
        pool.register(src.id, memory: [Float](repeating: 0.25, count: Int(info.frames) * 2), channels: 2)
        p.sources = [src]
        p.tracks[0].clips = [Clip(sourceID: src.id, start: 0, length: info.frames)]
        let on: Frame = 5_000, off: Frame = 12_000, ramp = 240   // 5 ms at 48 kHz
        try p.setAutomation(strip: t, param: .mute, points: [AutomationPoint(frame: 0, value: 0), AutomationPoint(frame: on, value: 1), AutomationPoint(frame: off, value: 0)])
        #expect(p.lane(strip: t, param: .mute)?.shape == .hold)
        let y = MixerTests.render(p, pool)
        func g(_ i: Int) -> Float { y[i * 2] / 0.25 }
        // Heard up to the point; closing from it; silent 5 ms later; silent until the next point; open 5 ms after that.
        #expect(g(Int(on) - 1) == 1 && g(Int(on)) == 1 && g(Int(on) + 1) < 1)
        #expect(abs(g(Int(on) + ramp / 2) - 0.5) < 0.01)
        #expect(g(Int(on) + ramp) == 0 && g(Int(off) - 1) == 0 && g(Int(off)) == 0)
        #expect(g(Int(off) + ramp) == 1 && g(Int(info.frames) - 1) == 1)
        // No jump anywhere: from one sample to the next the gain never moves more than the ramp's own step.
        var biggest: Float = 0
        for i in 1..<Int(info.frames) { biggest = max(biggest, abs(g(i) - g(i - 1))) }
        #expect(biggest <= 1 / Float(ramp) + 1e-5, "\(biggest)")
        print(String(format: "AUTOMATION mute: the biggest step between two samples is %.5f of full level (a ramp of %d frames; a mute without one steps 1.0)", biggest, ramp))
        // What an agent reads at a time.
        #expect(p.level(of: t, at: on - 1)?.muted == false && p.level(of: t, at: on)?.muted == true && p.level(of: t, at: off)?.muted == false)
        // The button mutes whatever the lane says; and with the lane switched off it is the button alone.
        var q = p
        q.tracks[0].isMuted = true
        #expect(MixerTests.render(q, pool).allSatisfy { $0 == 0 })
        try p.setAutomation(strip: t, param: .mute, points: p.lane(strip: t, param: .mute)!.points, enabled: false)
        #expect(MixerTests.render(p, pool).allSatisfy { $0 == 0.25 })
    }

    @Test("Two mute points closer together than the ramp: the second starts from where the first had got to, still without a jump; a lane that begins muted is silent from the start")
    func muteCloseTogether() throws {
        var (p, _) = AutomationTests.oneTrack()
        let t = p.tracks[0].id
        try p.setAutomation(strip: t, param: .mute, points: [AutomationPoint(frame: 0, value: 0), AutomationPoint(frame: 1_000, value: 1), AutomationPoint(frame: 1_060, value: 0)])
        let c = try #require(p.muteCurve(of: t))
        // Down from 1 000; at 1 060 it has come a quarter of the way (60 of 240 frames), and turns up from there.
        #expect(c.frames == [0, 1_000, 1_060, 1_300] && c.values[0] == 1 && c.values[1] == 1 && abs(c.values[2] - 0.75) < 1e-6 && c.values[3] == 1)
        #expect(zip(c.frames, c.frames.dropFirst()).allSatisfy { $0 < $1 })
        // Two points that say the same thing are one state.
        try p.setAutomation(strip: t, param: .mute, points: [AutomationPoint(frame: 0, value: 1), AutomationPoint(frame: 500, value: 1), AutomationPoint(frame: 900, value: 0)])
        let d = try #require(p.muteCurve(of: t))
        #expect(d.frames == [0, 900, 1_140] && d.values == [0, 0, 1])
    }

    @Test("An automated mute silences a send before the fader too, as the mute button does")
    func muteAndSends() {
        func render(pre: Bool) -> [Float] {
            Self.plan { plan, t in
                let dry = jm_plan_add_bus(plan, 1, true, 1, 1), wet = jm_plan_add_bus(plan, 1, false, 1, 1)
                jm_plan_set_track_route(plan, t, dry, 1, 1)
                jm_plan_add_track_send(plan, t, wet, 1, pre)
                let frames: [Int64] = [0, 1_000, 1_240], values: [Float] = [1, 1, 0]
                jm_plan_set_curve(plan, 0, t, 1, frames, values, 3)
            }
        }
        for pre in [true, false] {
            let y = render(pre: pre)
            #expect(y[999 * 2] == 0.25 && y[1_240 * 2] == 0 && y[(Self.n - 1) * 2] == 0, "pre \(pre)")
        }
    }

    @Test("An automated pan is the fixed pan's law at every point, moves without steps, and takes the slider's place")
    func pan() throws {
        // Constant: exactly what the fixed pan gives.
        for p in [-1.0, -0.5, 0, 0.3, 1] {
            let fixed = Mixer.panGains(p)
            let y = Self.plan { plan, t in
                let frames: [Int64] = [0], values: [Float] = [Float(p)]
                jm_plan_set_curve(plan, 0, t, 2, frames, values, 1)
            }
            #expect(y[100] == 0.25 * fixed.left && y[101] == 0.125 * fixed.right, "pan \(p)")
        }
        // From hard left to hard right over 8 000 frames: at each end one side is exactly silent, in the middle both are whole.
        let pts: [(Int64, Float)] = [(2_000, -1), (10_000, 1)]
        let y = Self.plan { plan, t in jm_plan_set_curve(plan, 0, t, 2, pts.map(\.0), pts.map(\.1), 2) }
        #expect(y[1_999 * 2] == 0.25 && y[1_999 * 2 + 1] == 0 && y[10_000 * 2] == 0 && y[10_000 * 2 + 1] == 0.125)
        // (The middle falls inside a piece, so it is the law to within what a piece strays, measured below.)
        #expect(abs(y[6_000 * 2] - 0.25) < 1e-4 && abs(y[6_000 * 2 + 1] - 0.125) < 1e-4)
        var worst = 0.0, biggest: Float = 0
        for i in 2_000..<10_000 {
            let pan = -1 + 2 * Double(i - 2_000) / 8_000, want = Mixer.panGains(pan)
            worst = max(worst, abs(Double(y[i * 2] / 0.25) - Double(want.left)), abs(Double(y[i * 2 + 1] / 0.125) - Double(want.right)))
            biggest = max(biggest, abs(y[i * 2] - y[(i - 1) * 2]) / 0.25, abs(y[i * 2 + 1] - y[(i - 1) * 2 + 1]) / 0.125)
        }
        print(String(format: "AUTOMATION pan: off the pan law by at most %.6f of full level; the biggest step between two samples %.6f", worst, biggest))
        #expect(worst < 0.0005 && biggest < 0.001)
        // In a project: the lane takes the slider's place, and the slider is back when the lane is cleared or switched off.
        var (p, pool) = AutomationTests.oneTrack()
        let t = p.tracks[0].id
        try p.setTrackRoute(t, pan: -1)
        let left = MixerTests.render(p, pool)
        try p.setAutomation(strip: t, param: .pan, points: [AutomationPoint(frame: 0, value: 1)])
        let right = MixerTests.render(p, pool)
        #expect(left.enumerated().allSatisfy { $0.offset % 2 == 0 || $0.element == 0 } && right.enumerated().allSatisfy { $0.offset % 2 == 1 || $0.element == 0 })
        try p.setAutomation(strip: t, param: .pan, points: p.lane(strip: t, param: .pan)!.points, enabled: false)
        #expect(MixerTests.render(p, pool) == left)
        // Only a pan lane, nothing else of the mixer: heard all the same.
        var (q, qpool) = AutomationTests.oneTrack()
        try q.setAutomation(strip: q.tracks[0].id, param: .pan, points: [AutomationPoint(frame: 0, value: -1)])
        #expect(!q.usesMixer && MixerTests.render(q, qpool).enumerated().allSatisfy { $0.offset % 2 == 0 || $0.element == 0 })
        // A mono document has no pan.
        var (m, _) = MixerTests.document(channels: 1)
        do { try m.setAutomation(strip: m.tracks[0].id, param: .pan, points: [AutomationPoint(frame: 0, value: 0.5)]); Issue.record("not refused") } catch { #expect(error.localizedDescription.contains("mono")) }
    }

    @Test("Mute and pan land where they were drawn behind a plugin with latency, and give the same samples in any blocks and after a seek")
    func placeAndBlocks() {
        func build(_ plan: OpaquePointer, _ t: Int32, latency: Int) {
            if latency > 0 { let c = MixerGraphTests.chain([DelayPlugin(latency: latency)]); jm_plan_set_chain(plan, t, c); jm_chain_release(c) }
            let mf: [Int64] = [0, 3_000, 3_240, 9_000, 9_240], mv: [Float] = [1, 1, 0, 0, 1]
            jm_plan_set_curve(plan, 0, t, 1, mf, mv, 5)
            let pf: [Int64] = [1_000, 15_000], pv: [Float] = [-0.8, 0.9]
            jm_plan_set_curve(plan, 0, t, 2, pf, pv, 2)
            let gf: [Int64] = [500, 18_000], gv: [Float] = [0, -9]
            jm_plan_set_curve(plan, 0, t, 0, gf, gv, 2)
        }
        let want = Self.plan { build($0, $1, latency: 0) }
        for latency in [1, 100, 777] { #expect(Self.plan { build($0, $1, latency: latency) } == want, "latency \(latency)") }
        let s = AutomationTests.steady()
        defer { jm_source_release(s) }
        func make() -> OpaquePointer {
            let plan = jm_plan_create(2, 48_000)
            build(plan, MixerGraphTests.track(plan, s), latency: 100)
            jm_plan_finalize(plan)
            return plan
        }
        for block in [1, 63, 512, 4_099] {
            let b = make()
            var got: [Float] = []
            var at = 0
            while at < Self.n { let k = min(block, Self.n - at); got += MixerGraphTests.render(b, from: at, frames: k); at += k }
            jm_plan_release(b)
            #expect(got == want, "blocks of \(block)")
        }
        let c = make()
        for (from, frames) in [(3_100, 500), (0, 100), (9_100, 2_000)] {
            #expect(MixerGraphTests.render(c, from: from, frames: frames) == Array(want[(from * 2)..<((from + frames) * 2)]), "seek to \(from)")
        }
        jm_plan_release(c)
    }
}

/// Automation, step 3: a send's level, and a VCA group's lanes.
@Suite("Mixer: automation of sends and VCA groups")
struct AutomationSendVCATests {
    @Test("A send's lane moves the send and nothing else, on the strip's timeline; it goes when the send goes")
    func sendLane() throws {
        var (p, pool) = MixerTests.document()
        let t = p.tracks[0].id
        let wet = try p.addBus(name: "Wet")
        try p.setSend(from: t, to: wet.id, gainDB: -6)
        let before = MixerTests.render(p, pool)
        // A lane of 0 dB: the same samples. A lane of −96: the send is as good as gone, the track itself untouched.
        try p.setAutomation(strip: t, param: .send, to: wet.id, points: [AutomationPoint(frame: 0, value: 0)])
        #expect(MixerTests.render(p, pool) == before)
        try p.setAutomation(strip: t, param: .send, to: wet.id, points: [AutomationPoint(frame: 0, value: -96)])
        var noSend = p
        noSend.automation = []
        try noSend.setSend(from: t, to: wet.id, remove: true)
        let dry = MixerTests.render(noSend, pool), down = MixerTests.render(p, pool)
        #expect(zip(down, dry).allSatisfy { abs($0 - $1) < 1e-5 })
        // Constant −6 on the lane is the send at −12.
        try p.setAutomation(strip: t, param: .send, to: wet.id, points: [AutomationPoint(frame: 0, value: -6)])
        var byHand = p
        byHand.automation = []
        try byHand.setSend(from: t, to: wet.id, gainDB: -12)
        #expect(zip(MixerTests.render(p, pool), MixerTests.render(byHand, pool)).allSatisfy { abs($0 - $1) < 1e-6 })
        // A send before the fader has its own lane all the same, and doesn't follow the fader's.
        try p.setSend(from: t, to: wet.id, pre: true)
        try p.setAutomation(strip: t, points: [AutomationPoint(frame: 0, value: -20)])
        var preByHand = byHand
        try preByHand.setSend(from: t, to: wet.id, gainDB: -12, pre: true)
        preByHand.tracks[0].gainDB = -20
        #expect(zip(MixerTests.render(p, pool), MixerTests.render(preByHand, pool)).allSatisfy { abs($0 - $1) < 1e-6 })
        // The lane is saved with its bus, and is gone (not saved, not heard) when the send is removed.
        let json = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
        #expect(try JSONDecoder().decode(Project.self, from: Data(json.utf8)) == p)
        #expect(p.lane(strip: t, param: .send, to: wet.id) != nil)
        try p.setSend(from: t, to: wet.id, remove: true)
        #expect(p.lane(strip: t, param: .send, to: wet.id) == nil && p.lanes(of: t).count == 1)
        // Freezing: a send's lane into a bus is part of what the bus is made from.
        var (f, _) = MixerTests.document()
        let bus = try f.addBus(name: "B")
        try f.setSend(from: f.tracks[0].id, to: bus.id)
        let was = f.content(of: bus.id)
        try f.setAutomation(strip: f.tracks[0].id, param: .send, to: bus.id, points: [AutomationPoint(frame: 0, value: -3)])
        #expect(f.content(of: bus.id) != was)
    }

    @Test("A VCA group's lanes are added to its members': the same samples as writing the summed values on each member by hand")
    func vcaLanes() throws {
        var (p, pool) = MixerTests.document()
        let a = p.tracks[0].id, b = p.tracks[1].id, c = p.tracks[2].id
        let group = try p.addVCA(name: "Voices")
        try p.setMember(a, vca: group.id)
        try p.setMember(b, vca: group.id)
        func pts(_ list: [(Frame, Double)]) -> [AutomationPoint] { list.map { AutomationPoint(frame: $0.0, value: $0.1) } }
        // The group goes down 12 dB between 2 000 and 10 000; member a has a lane of its own with other points; b has none; c is outside.
        let groupLane = pts([(2_000, 0), (10_000, -12)]), own = pts([(1_000, -3), (6_000, 3), (15_000, -6)])
        try p.setAutomation(strip: group.id, points: groupLane)
        try p.setAutomation(strip: a, points: own)
        // By hand: on every member, the sum of the two lines at the points of both.
        var byHand = p
        byHand.automation = []
        let g = AutomationLane(strip: group.id, points: groupLane), o = AutomationLane(strip: a, points: own)
        let frames: [Frame] = [1_000, 2_000, 6_000, 10_000, 15_000]
        try byHand.setAutomation(strip: a, points: frames.map { AutomationPoint(frame: $0, value: g.value(at: $0)! + o.value(at: $0)!) })
        try byHand.setAutomation(strip: b, points: groupLane)
        #expect(MixerTests.render(p, pool) == MixerTests.render(byHand, pool))
        // The level an agent reads has the group's lane in it; the outsider's doesn't.
        #expect(p.level(of: a, at: 6_000)?.automationDB == 3 + -6 && p.level(of: b, at: 6_000)?.automationDB == -6 && p.level(of: c, at: 6_000)?.automationDB == nil)
        // The group's mute lane mutes its members, with the ramp, and not the outsider.
        try p.setAutomation(strip: group.id, param: .mute, points: pts([(0, 0), (12_000, 1)]))
        var mutedByHand = byHand
        for m in [a, b] { try mutedByHand.setAutomation(strip: m, param: .mute, points: pts([(0, 0), (12_000, 1)])) }
        #expect(MixerTests.render(p, pool) == MixerTests.render(mutedByHand, pool))
        #expect(p.level(of: a, at: 12_000)?.muted == true && p.level(of: c, at: 12_000)?.muted == false)
        // A member muted by its own lane earlier and the group later: muted when either says so.
        try p.setAutomation(strip: a, param: .mute, points: pts([(0, 0), (5_000, 1), (8_000, 0)]))
        let curve = try #require(p.muteCurve(of: a))
        #expect(curve.frames == [0, 5_000, 5_240, 8_000, 8_240, 12_000, 12_240] && curve.values == [1, 1, 0, 0, 1, 1, 0])
        // A group has a level and a mute, nothing else; and freezing sees the group's lanes through its members.
        do { try p.setAutomation(strip: group.id, param: .pan, points: pts([(0, 0)])); Issue.record("not refused") } catch { #expect(error.localizedDescription.contains("VCA group has a level and a mute")) }
        var (f, _) = MixerTests.document()
        let bus = try f.addBus(name: "B"), v = try f.addVCA(name: "V")
        try f.setTrackRoute(f.tracks[0].id, output: .some(bus.id))
        try f.setMember(f.tracks[0].id, vca: v.id)
        let was = f.content(of: bus.id)
        try f.setAutomation(strip: v.id, points: pts([(0, -3)]))
        #expect(f.content(of: bus.id) != was)
        // Removing the group takes its lanes out of the sound and out of the file.
        try p.removeVCA(group.id)
        #expect(p.lanes(of: group.id).isEmpty && p.liveLanes.allSatisfy { $0.strip != group.id })
    }
}
