import Foundation
import Testing
@testable import JammerCore

@Suite("Ambisonics: a field decoded to loudspeakers and turned, fixed and by lanes")
struct AmbisonicFieldTests {
    let sr = 48_000.0

    /// A mono noise encoded into a third-order field from a direction, written as a 16-channel file.
    func field(_ dir: TempDir, name: String, azimuth: Double, elevation: Double, seconds: Double, order: Int = 3) throws -> (SourceRef, [Float]) {
        let n = Int(sr * seconds), c = (order + 1) * (order + 1)
        let mono = noise(count: n, seed: 7).map { $0 * 0.2 }
        let y = Ambisonics.encode(azimuth: azimuth, elevation: elevation, order: order)
        var x = [Float](repeating: 0, count: n * c)
        for i in 0..<n { for k in 0..<c { x[i * c + k] = mono[i] * y[k] } }
        let url = dir.file(name)
        try writeWAV(x, to: url, channels: c)
        var ref = SourceRef(name: name, path: url.path, info: try AudioFileReader.info(at: url))
        ref.fieldOrder = order
        return (ref, mono)
    }

    /// The mono signal decoded from a direction into a layout: what a field from there should sound like.
    func decoded(_ mono: [Float], azimuth: Double, elevation: Double, order: Int, to layout: ChannelLayout) -> [Float] {
        let d = AmbisonicDecoder.cached(order: order, to: layout), y = Ambisonics.encode(azimuth: azimuth, elevation: elevation, order: order)
        let c = (order + 1) * (order + 1), out = layout.channels
        let g = (0..<out).map { ch in (0..<c).reduce(Float(0)) { $0 + y[$1] * d[$1 * out + ch] } }
        return mono.flatMap { s in g.map { s * $0 } }
    }

    @Test("A field marked as such is decoded into 7.1.4 by AllRAD (and into stereo by way of 5.1); unmarked it would go channel for channel")
    func decodedIntoLoudspeakers() throws {
        let dir = TempDir()
        let (ref, mono) = try field(dir, name: "f.wav", azimuth: 40, elevation: 20, seconds: 0.5)
        var p = Project(source: ref)
        p.channels = ChannelLayout.immersive714.channels
        let out = PlanCompiler.compile(p, pool: SourcePool()).render(from: 0, frames: mono.count)
        let want = decoded(mono, azimuth: 40, elevation: 20, order: 3, to: .immersive714)
        #expect(zip(out, want).map { abs($0 - $1) }.max()! < 1e-5)
        // The loudest loudspeaker is the one nearest the source (top front left, at 45° up 30°).
        let energy = (0..<12).map { ch in stride(from: ch, to: out.count, by: 12).reduce(Float(0)) { $0 + out[$1] * out[$1] } }
        #expect(ChannelLayout.immersive714.speakers[energy.firstIndex(of: energy.max()!)!] == .topFrontLeft, "\(energy)")
        p.channels = 2
        let stereo = PlanCompiler.compile(p, pool: SourcePool()).render(from: 0, frames: mono.count)
        let l = stride(from: 0, to: stereo.count, by: 2).reduce(Float(0)) { $0 + stereo[$1] * stereo[$1] }
        let r = stride(from: 1, to: stereo.count, by: 2).reduce(Float(0)) { $0 + stereo[$1] * stereo[$1] }
        #expect(l > 2 * r, "a field from the left is heard on the left in stereo too: \(l) / \(r)")
    }

    @Test("A fixed turn: a field turned by yaw, pitch and roll sounds as the source from the turned direction")
    func fixedTurn() throws {
        let dir = TempDir()
        let (ref, mono) = try field(dir, name: "f.wav", azimuth: 10, elevation: 5, seconds: 0.5)
        var p = Project(source: ref)
        p.channels = ChannelLayout.immersive714.channels
        p.tracks[0].rotation = FieldRotation(yaw: 70, pitch: 15, roll: -20)
        let out = PlanCompiler.compile(p, pool: SourcePool()).render(from: 0, frames: mono.count)
        let t = Ambisonics.angles(Ambisonics.rotate(Ambisonics.vector(10, 5), yaw: 70, pitch: 15, roll: -20))
        let want = decoded(mono, azimuth: t.azimuth, elevation: t.elevation, order: 3, to: .immersive714)
        #expect(zip(out, want).map { abs($0 - $1) }.max()! < 2e-5)
    }

    @Test("A moving turn (a yaw lane, 80° in 2 s, as the place lanes' test): within 2·10⁻⁵ of every sample turned at its own angle along the stretch; a render from the middle gives the same samples")
    func movingTurn() throws {
        let dir = TempDir()
        let seconds = 2.0
        let (ref, mono) = try field(dir, name: "f.wav", azimuth: 0, elevation: 10, seconds: seconds)
        var p = Project(source: ref)
        p.channels = ChannelLayout.ambix3.channels
        let n = mono.count
        p.automation = [AutomationLane(strip: p.tracks[0].id, param: .yaw, points: [AutomationPoint(frame: 0, value: 0), AutomationPoint(frame: Frame(n), value: 80)])]
        let plan = PlanCompiler.compile(p, pool: SourcePool())
        let out = plan.render(from: 0, frames: n)
        // The ideal: each sample's field turned by its own yaw.
        var worst = 0.0, peak = 0.0
        for i in stride(from: 0, to: n - 1_024, by: 37) {
            let yaw = 80 * Double(i) / Double(n)
            let y = Ambisonics.encode(azimuth: yaw, elevation: 10, order: 3)
            for k in 0..<16 {
                let want = Double(mono[i] * y[k]), got = Double(out[i * 16 + k])
                worst = max(worst, abs(got - want)); peak = max(peak, abs(want))
            }
        }
        #expect(worst / peak < 2e-5, "worst \(worst) of a peak \(peak): \(worst / peak)")
        // Where the path turns (a point off the grid, the yaw going back): within the place lanes' 2·10⁻³ there.
        let corner = 50_001
        p.automation = [AutomationLane(strip: p.tracks[0].id, param: .yaw, points: [AutomationPoint(frame: 0, value: 0), AutomationPoint(frame: Frame(corner), value: 60),
                                                                                    AutomationPoint(frame: Frame(n), value: 0)])]
        let turning = PlanCompiler.compile(p, pool: SourcePool()).render(from: 0, frames: n)
        var near = 0.0
        for i in (corner - 1_536)..<(corner + 1_536) {
            let yaw = i <= corner ? 60 * Double(i) / Double(corner) : 60 * (1 - Double(i - corner) / Double(n - corner))
            let y = Ambisonics.encode(azimuth: yaw, elevation: 10, order: 3)
            for k in 0..<16 { near = max(near, abs(Double(turning[i * 16 + k]) - Double(mono[i] * y[k]))) }
        }
        print("TURN corner: \(near / peak), straight: \(worst / peak)")
        #expect(near / peak < 2e-3, "at the corner: \(near / peak)")
        // From the middle: the same samples.
        let from = 33_333
        let part = plan.render(from: Frame(from), frames: 20_000)
        #expect(Array(out[(from * 16)..<((from + 20_000) * 16)]) == part)
    }
}
