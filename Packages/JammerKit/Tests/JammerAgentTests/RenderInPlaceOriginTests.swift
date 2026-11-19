import Foundation
import Testing
@testable import JammerAgent
@testable import JammerCore

/// Every step that renders audio in place keeps the clip's origin, so Send to Flimmer sends a take of the clip and
/// not a new clip with the original "deleted" (round D, 2026-11-19; the coordinator). The steps are found in the
/// registry, not listed by hand: a step that refuses to run without the app's media folder renders audio.
@Suite("Steps that render in place keep the clip's origin")
struct RenderInPlaceOriginTests {
    let sr = 48_000.0

    func film() -> (Project, SourcePool, dialog: UUID, music: UUID) {
        let n = Int(sr * 8)
        // Speech-like bursts with a little noise on one track, a tone on the other.
        var g = SystemRandomNumberGenerator()
        let speech = (0..<n).flatMap { i -> [Float] in
            let on = (i / 12_000) % 3 != 2
            let v = (on ? Float(0.2 * sin(Double(i) * 0.05) * (0.6 + 0.4 * sin(Double(i) * 0.0007))) : 0) + Float.random(in: -0.003...0.003, using: &g)
            return [v, v]
        }
        let music = (0..<n).flatMap { i -> [Float] in let v = Float(0.15 * sin(Double(i) * 0.031)); return [v, v] }
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: sr,
                                 channelMask: nil, dataOffset: 0, frames: Int64(n), chunks: [], bext: nil, ixml: nil, markers: [])
        let a = SourceRef(name: "dialog", path: "/dev/null", info: info), b = SourceRef(name: "music", path: "/dev/null", info: info)
        let pool = SourcePool()
        pool.register(a.id, memory: speech, channels: 2)
        pool.register(b.id, memory: music, channels: 2)
        func clip(_ s: SourceRef, id: String, track: String) -> Clip {
            var c = Clip(sourceID: s.id, start: 0, length: Frame(n))
            var o = Origin(app: "flimmer", clipId: id, trackId: track, exportVersion: "2")
            var snap = Origin.Snapshot()
            snap.start = c.start; snap.length = c.length; snap.sourceID = c.sourceID
            o.snapshot = snap
            c.origin = o
            return c
        }
        func track(_ name: String, _ id: String, _ c: Clip) -> Track {
            var t = Track(name: name, clips: [c])
            var o = Origin(app: "flimmer", trackId: id, exportVersion: "2")
            o.snapshot = Origin.Snapshot()
            t.origin = o
            return t
        }
        var p = Project(sampleRate: sr, channels: 2, tracks: [track("Dialog", "T1", clip(a, id: "C1", track: "T1")),
                                                              track("Musik", "T2", clip(b, id: "C2", track: "T2"))], sources: [a, b])
        p.imported = .init(app: "flimmer", exportVersion: "2", clipIds: ["C1", "C2"], length: p.length, projectId: "P1", storyId: "S1")
        return (p, pool, p.tracks[0].id, p.tracks[1].id)
    }

    /// Values for a step's parameters, by their name and kind (never by the step): enough to make each run.
    func params(_ spec: OperationSpec, dialog: UUID, music: UUID) -> [String: JSONValue] {
        let named: [String: JSONValue] = [
            "start": .number(2), "end": .number(6), "tracks": .array([.string(dialog.uuidString)]), "track": .string(dialog.uuidString),
            "against": .string(music.uuidString), "reference": .string(music.uuidString), "under": .array([.string(music.uuidString)]),
            "low": .number(1_000), "high": .number(4_000), "db": .number(-6), "ppm": .number(100), "limit": .bool(true),
            "mode": .string("ride"), "action": .string("attenuate"), "shape": .string("box"), "ceiling": .number(-20), "amount": .number(-10), "method": .string("cancel"),
        ]
        var out: [String: JSONValue] = [:]
        for p in spec.params {
            if var v = named[p.name] {
                if let opts = p.options, case .string(let s) = v, !opts.contains(s) { v = .string(opts[0]) }
                out[p.name] = v
            } else if p.required {
                switch p.kind {
                case .number, .seconds: out[p.name] = .number(p.range.map { $0.lowerBound + ($0.upperBound - $0.lowerBound) / 4 } ?? 1)
                case .boolean: out[p.name] = .bool(false)
                case .string: out[p.name] = .string(p.options?.first ?? "x")
                default: break
                }
            }
        }
        return out
    }

    static let quiet: StepRunner.Measure = { _, _ in LoudnessResult(integrated: -30, range: nil, maxMomentary: nil, maxShortTerm: nil, samplePeak: 0.3, truePeak: 0.3, duration: 8) }

    @Test("Every rendering step in the registry: done, the new clips carry the origin, and Send would make takes, nothing new or deleted")
    func everyRenderingStep() throws {
        let (p, pool, dialog, music) = film()
        let media = FileManager.default.temporaryDirectory.appending(path: "jammer-rip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: media) }
        var renderers: [String] = []
        for spec in Operations.all {
            let step = Step(op: spec.name, params: params(spec, dialog: dialog, music: music))
            var without = EditState(project: p, pool: pool, media: nil)
            let r0 = StepRunner.run([step], on: &without, measure: Self.quiet)[0]
            guard r0.status == .failed, let key = r0.keyed?.key, key.hasSuffix(".app") || key.contains("app_render") || key.contains("needs_app") else { continue }
            renderers.append(spec.name)
            var with = EditState(project: p, pool: pool, media: media)
            let r = StepRunner.run([step], on: &with, measure: Self.quiet)[0]
            #expect(r.status == .done, "\(spec.name): \(r.error ?? "") \(step.params)")
            guard r.status == .done else { continue }
            let q = with.project
            let oldSources = Set(p.sources.map(\.id))
            let made = q.tracks.flatMap(\.clips).filter { !oldSources.contains($0.sourceID) }
            #expect(!made.isEmpty || r.info.values.allSatisfy { $0 == 0 }, "\(spec.name) rendered nothing: \(r.info)")
            #expect(made.allSatisfy { $0.origin?.clipId != nil }, "\(spec.name): a rendered clip without its origin")
            let plan = try FlimmerReturn.plan(q)
            #expect(plan.new.isEmpty && plan.missing.isEmpty, "\(spec.name): new \(plan.new.count), deleted \(plan.missing)")
            let kinds = FlimmerSend.items(q, plan: plan, mode: .takes).map(\.kind)
            #expect(!kinds.contains(.new) && (made.isEmpty || kinds.contains(.take)), "\(spec.name): \(kinds)")
        }
        // The ones known today must be among them (a guard on the discovery, not the list the test works from).
        for known in ["spectral_attenuate", "spectral_edit", "correct_drift", "debleed", "duck", "echo", "limit"] {
            #expect(renderers.contains(known), "\(known) wasn't found as a rendering step; found \(renderers)")
        }
    }
}
