import Foundation
import JammerEngine
import Testing
@testable import JammerCore

/// The peak meters (the comfort block, step 4) against a known reference: squares of known amplitude, whose sample
/// peak is exact, and the master checked against the highest sample of the render itself.
@Suite("Meters: post-fader sample peaks per track, bus and master")
struct MeterTests {
    static let n = 48_000
    /// Mono or stereo tracks playing squares of the given amplitudes (100 Hz), all in phase.
    static func document(_ amplitudes: [Float], channels: Int = 1) -> (Project, SourcePool) {
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: channels, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: Int64(n), chunks: [], bext: nil, ixml: nil, markers: [])
        let pool = SourcePool()
        var p: Project?
        for (k, a) in amplitudes.enumerated() {
            let src = SourceRef(name: "s\(k)", path: "/dev/null", info: info)
            pool.register(src.id, memory: (0..<n).flatMap { i -> [Float] in
                let v: Float = (i / 240) % 2 == 0 ? a : -a
                return Array(repeating: v, count: channels)
            }, channels: channels)
            if p == nil { p = Project(source: src) } else { _ = p!.addTrack(source: src, name: "t\(k)") }
        }
        return (p!, pool)
    }

    @Test("Each track's peak is its own after its fader, and the master's is the highest sample of what leaves")
    func plain() throws {
        var (p, pool) = Self.document([0.1, 0.2, 0.3])
        p.tracks[1].gainDB = 20 * log10(0.5)
        let plan = PlanCompiler.compile(p, pool: pool)
        let tracks = plan.peaks(0..<Frame(Self.n), kind: 0, count: 3)
        #expect(abs(tracks[0] - 0.1) < 1e-6 && abs(tracks[1] - 0.1) < 1e-6 && abs(tracks[2] - 0.3) < 1e-6, "\(tracks)")
        let master = plan.peaks(0..<Frame(Self.n), kind: 2, count: 1)[0]
        let rendered = plan.render(from: 0, frames: Self.n).map(abs).max() ?? 0
        #expect(abs(master - 0.5) < 1e-6 && master == rendered, "master \(master), render \(rendered)")
    }

    @Test("A muted track reads nothing; the track's own pan doesn't change its meter (it is before the pan)")
    func muteAndPan() throws {
        var (p, pool) = Self.document([0.4, 0.2], channels: 2)
        p.tracks[1].isMuted = true
        try p.setTrackRoute(p.tracks[0].id, pan: -1)
        let peaks = PlanCompiler.compile(p, pool: pool).peaks(0..<Frame(Self.n), kind: 0, count: 2)
        #expect(abs(peaks[0] - 0.4) < 1e-6 && peaks[1] == 0, "\(peaks)")
    }

    @Test("A bus reads the sum of what goes to it, after its own fader; the track before it reads its own")
    func bus() throws {
        var (p, pool) = Self.document([0.2, 0.3])
        let bus = try p.addBus(name: "B")
        try p.setTrackRoute(p.tracks[0].id, output: .some(bus.id))
        try p.setTrackRoute(p.tracks[1].id, output: .some(bus.id))
        if let i = p.buses.firstIndex(where: { $0.id == bus.id }) { p.buses[i].gainDB = 20 * log10(0.5) }
        let plan = PlanCompiler.compile(p, pool: pool)
        let tracks = plan.peaks(0..<Frame(Self.n), kind: 0, count: 2), buses = plan.peaks(0..<Frame(Self.n), kind: 1, count: 1)
        #expect(abs(tracks[0] - 0.2) < 1e-6 && abs(tracks[1] - 0.3) < 1e-6, "\(tracks)")
        #expect(abs(buses[0] - 0.25) < 1e-6, "\(buses)")
        #expect(abs(plan.peaks(0..<Frame(Self.n), kind: 2, count: 1)[0] - 0.25) < 1e-6)
    }

    @Test("Above full scale reads above 1 (the clip light's case): nothing is clamped")
    func overFullScale() {
        var (p, pool) = Self.document([0.8, 0.7])
        p.tracks[0].gainDB = 0
        let master = PlanCompiler.compile(p, pool: pool).peaks(0..<Frame(Self.n), kind: 2, count: 1)[0]
        #expect(abs(master - 1.5) < 1e-6)
    }

    @Test("Metering doesn't change a sample: a render with meters is the render without them")
    func bitExact() {
        let (p, pool) = Self.document([0.1, 0.2, 0.3])
        let plan = PlanCompiler.compile(p, pool: pool)
        let before = plan.render(from: 0, frames: Self.n)
        _ = plan.peaks(0..<Frame(Self.n), kind: 0, count: 3)
        #expect(PlanCompiler.compile(p, pool: pool).render(from: 0, frames: Self.n) == before)
    }
}
