import Foundation
import JammerEngine

/// Open engine sources, one per project source, shared by plans. Thread-safe:
/// engine sources read with pread, and the table is behind a lock.
public final class SourcePool: @unchecked Sendable {
    private let lock = NSLock()
    private var open: [UUID: OpaquePointer] = [:]
    private var missingIDs: Set<UUID> = []
    private var refusedIDs: [UUID: Refusal] = [:]
    private var policy: (@Sendable (URL) -> Bool)?

    /// Why a source's file isn't used although something is there.
    public enum Refusal: Sendable, Equatable {
        /// It lies outside where this document may read (the package and the folders the user allowed).
        case notAllowed(URL)
        /// It isn't the audio the project says it is: not a WAV or AIFF, or its header says otherwise.
        case notAsDescribed(URL)
    }

    public init() {}

    /// Limits which files this pool opens: the real location of each file (symlinks followed)
    /// is put to `allows`. nil (the default) allows everything, for audio the user picked directly.
    public func restrict(_ allows: (@Sendable (URL) -> Bool)?) {
        lock.withLock {
            policy = allows
            // Everything is asked again under the new rule: also files that were already open,
            // which may no longer be allowed.
            for (_, s) in open { jm_source_release(s) }
            open = [:]
            missingIDs = []
            refusedIDs = [:]
        }
    }

    /// Files that are there but weren't used, and why.
    public var refused: [UUID: Refusal] { lock.withLock { refusedIDs } }

    deinit { for (_, s) in open { jm_source_release(s) } }

    public var missing: Set<UUID> { lock.withLock { missingIDs } }

    /// The engine source for `ref`, opened on first use. nil if the file is gone.
    public func source(for ref: SourceRef) -> OpaquePointer? {
        lock.withLock {
            if let s = open[ref.id] { return s }
            if missingIDs.contains(ref.id) { return nil }
            // No path and no bookmark is no file (an empty path would otherwise mean "here").
            guard !ref.path.isEmpty || ref.bookmark != nil else {
                missingIDs.insert(ref.id)
                return nil
            }
            let url = Self.real(Self.resolve(ref))
            if let policy, !policy(url) {
                refusedIDs[ref.id] = .notAllowed(url)
                missingIDs.insert(ref.id)
                return nil
            }
            // A project says which bytes of which file are sound. That is never taken on trust: the
            // file must itself be a WAV or AIFF whose own header says the same, or it could be made to
            // read any file on the disk as "audio" (and an export would carry it out).
            guard FileManager.default.fileExists(atPath: url.path) else {
                missingIDs.insert(ref.id)
                return nil
            }
            guard let actual = try? AudioFileReader.info(at: url), actual.sampleFormat == ref.info.sampleFormat, actual.channels == ref.info.channels,
                  actual.sampleRate == ref.info.sampleRate, actual.bigEndian == ref.info.bigEndian, actual.dataOffset == ref.info.dataOffset else {
                refusedIDs[ref.id] = .notAsDescribed(url)
                missingIDs.insert(ref.id)
                return nil
            }
            var info = ref.info
            info.frames = min(ref.info.frames, actual.frames)
            guard let s = AudioFileReader.openSource(info, at: url) else {
                missingIDs.insert(ref.id)
                return nil
            }
            missingIDs.remove(ref.id)
            open[ref.id] = s
            return s
        }
    }

    /// Adds an in-memory source (generated audio, tests).
    public func register(_ id: UUID, memory: [Float], channels: Int) {
        let frames = memory.count / max(1, channels)
        let s = memory.withUnsafeBufferPointer { jm_source_create_memory($0.baseAddress!, Int64(frames), Int32(channels)) }
        lock.withLock {
            open[id].map { jm_source_release($0) }
            open[id] = s
        }
    }

    /// Where a file really is: symlinks followed all the way.
    public static func real(_ url: URL) -> URL {
        realpath(url.path, nil).map { p in defer { free(p) }; return URL(fileURLWithPath: String(cString: p)) } ?? url.standardizedFileURL
    }

    public static func resolve(_ ref: SourceRef) -> URL {
        if let bm = ref.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bm, options: [.withoutUI], bookmarkDataIsStale: &stale) { return url }
        }
        return URL(fileURLWithPath: ref.path)
    }

    /// Reads interleaved float frames of a source (for peaks and analysis).
    public func read(_ ref: SourceRef, from frame: Frame, count: Int) -> [Float] {
        guard let s = source(for: ref), count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count * ref.info.channels)
        let got = Int(jm_source_read(s, frame, Int64(count), &out))
        if got < count { out.removeLast((count - got) * ref.info.channels) }
        return out
    }
}

/// An immutable, finalized engine plan. Safe to hand to another thread.
public final class RenderPlan: @unchecked Sendable {
    public let pointer: OpaquePointer
    public let channels: Int
    public let sampleRate: Double

    init(_ pointer: OpaquePointer, channels: Int, sampleRate: Double) {
        self.pointer = pointer
        self.channels = channels
        self.sampleRate = sampleRate
    }

    deinit { jm_plan_release(pointer) }

    public var length: Frame { jm_plan_length(pointer) }

    /// Renders `frames` frames from `start` as interleaved float.
    public func render(from start: Frame, frames: Int) -> [Float] {
        var out = [Float](repeating: 0, count: frames * channels)
        _ = jm_render(pointer, start, Int64(frames), &out)
        return out
    }

    /// Renders a range in blocks, handing each to `body` (offline export, analysis).
    /// The longest path through the mixer, in frames: what the plugins on the buses add, and what every
    /// other path is delayed to match. 0 without plugins on buses. The mix itself comes out on the sample.
    public var totalLatency: Int64 { jm_plan_total_latency(pointer) }
    /// The part of it that the master adds (its plugins and its limiter).
    public var masterLatency: Int64 { jm_plan_master_latency(pointer) }
    /// The sidechain keys the plan carries (those the engine kept).
    public var keyCount: Int { Int(jm_plan_key_count(pointer)) }
    /// The delay added to a track's (or a bus's) own way out so that it lines up with the longest path it meets.
    public func compensation(bus: Bool, index: Int) -> Int64 { jm_plan_compensation(pointer, bus, Int32(index)) }

    public func render(_ range: Range<Frame>, blockFrames: Int = 65_536, _ body: (UnsafeBufferPointer<Float>) throws -> Void) rethrows {
        var buffer = [Float](repeating: 0, count: blockFrames * channels)
        var at = range.lowerBound
        while at < range.upperBound {
            let n = Int(min(Frame(blockFrames), range.upperBound - at))
            buffer.withUnsafeMutableBufferPointer { b in _ = jm_render(pointer, at, Int64(n), b.baseAddress!) }
            try buffer.withUnsafeBufferPointer { try body(UnsafeBufferPointer(rebasing: $0[0..<(n * channels)])) }
            at += Frame(n)
        }
    }
}

public enum PlanCompiler {
    /// Compiles the project into what the engine plays. Clips whose file is missing are left out.
    /// Inserts run only when `inserts` supplies their chains; without it the plan is the
    /// dry mix (what the bounced effects and restoration work from).
    /// `masterMargin`: how far under its ceiling the master's limiter aims (dB); an export that measured
    /// its file over the ceiling renders again with more.
    public static func compile(_ project: Project, pool: SourcePool, inserts: ChainProvider? = nil, masterMargin: Double = Mixer.masterMargins[0]) -> RenderPlan {
        // A frozen strip is played from its file (see `Project.played`); everything below sees that project.
        let project = project.played()
        let plan = jm_plan_create(Int32(project.channels), project.sampleRate)
        var indices: [UUID: Int32] = [:]
        var trackIndex: [UUID: Int32] = [:]
        // The buses first, when the project uses the mixer at all; otherwise the plan is the one it always was.
        var busIndex: [UUID: Int32] = [:]
        let routed = project.usesMixer
        if routed {
            for b in project.buses {
                // (A pan lane takes the fixed pan's place.)
                let pan = project.channels == 2 && project.panCurve(of: b.id) == nil ? Mixer.panGains(b.pan) : (1, 1)
                let fader = project.heard(gainDB: b.gainDB, muted: b.isMuted, vca: b.vca)
                let index = jm_plan_add_bus(plan, Float(dbToGain(fader.gainDB)), fader.muted, pan.0, pan.1)
                busIndex[b.id] = index
                if let inserts, b.inserts.contains(where: { !$0.bypass }) { inserts.attachChain(for: b, to: plan, index: index) }
            }
            for b in project.buses {
                guard let from = busIndex[b.id] else { continue }
                if let o = b.output, let to = busIndex[o] { jm_plan_set_bus_output(plan, from, to) }
                for s in b.sends {
                    guard let to = busIndex[s.to] else { continue }
                    jm_plan_add_bus_send(plan, from, to, Float(dbToGain(s.gainDB)), s.pre)
                    if let c = project.sendCurve(from: b.id, to: s.to) { jm_plan_set_send_curve(plan, true, from, to, c.frames, c.db, Int32(c.frames.count)) }
                }
            }
        }
        for t in project.tracks {
            // With a VCA its level is added to the fader; without one this is the track's own, bit for bit.
            let fader = project.heard(gainDB: t.gainDB, muted: t.isMuted, vca: t.vca)
            let track = jm_plan_add_track(plan, Float(dbToGain(fader.gainDB)), fader.muted)
            trackIndex[t.id] = track
            if routed {
                let pan = project.channels == 2 && project.panCurve(of: t.id) == nil ? Mixer.panGains(t.pan) : (1, 1)
                jm_plan_set_track_route(plan, track, t.output.flatMap { busIndex[$0] } ?? -1, pan.0, pan.1)
                for s in t.sends {
                    guard let to = busIndex[s.to] else { continue }
                    jm_plan_add_track_send(plan, track, to, Float(dbToGain(s.gainDB)), s.pre)
                    if let c = project.sendCurve(from: t.id, to: s.to) { jm_plan_set_send_curve(plan, false, track, to, c.frames, c.db, Int32(c.frames.count)) }
                }
            }
            if let inserts, t.inserts.contains(where: { !$0.bypass }) { inserts.attachChain(for: t, to: plan, index: track) }
            for c in t.clips {
                guard let ref = project.source(c.sourceID) else { continue }
                let index: Int32
                if let i = indices[ref.id] {
                    index = i
                } else {
                    guard let s = pool.source(for: ref) else { continue }
                    index = jm_plan_add_source(plan, s)
                    indices[ref.id] = index
                }
                jm_plan_add_clip(plan, track, index, c.sourceStart, c.start, c.length, Float(dbToGain(c.gainDB)),
                                 c.fadeIn, c.fadeOut, c.fadeShape == .linear ? JM_FADE_LINEAR : JM_FADE_EQUAL_POWER)
            }
        }
        // Sidechain keys: a plugin that listens to another strip. Only where the plugin runs and has the
        // input, and the strip it names is there; the engine drops any that would close a loop.
        if let inserts {
            func keys(_ list: [Insert], toBus: Bool, to: Int32) {
                for i in list where !i.bypass {
                    guard let source = i.key, let unit = inserts.keyUnit(of: i.id, among: list) else { continue }
                    if let from = trackIndex[source] { jm_plan_add_key(plan, toBus, to, unit, false, from) }
                    else if let from = busIndex[source] { jm_plan_add_key(plan, toBus, to, unit, true, from) }
                }
            }
            for t in project.tracks { if let to = trackIndex[t.id] { keys(t.inserts, toBus: false, to: to) } }
            for b in project.buses { if let to = busIndex[b.id] { keys(b.inserts, toBus: true, to: to) } }
        }
        // Automation of levels: each strip's enabled gain lane, as points on the timeline. Nothing is set
        // for a strip without one, and the plan is then what it always was.
        func curve(_ strip: UUID, kind: Int32, index: Int32) {
            if let c = project.gainCurve(of: strip) { jm_plan_set_gain_curve(plan, kind, index, c.frames, c.db, Int32(c.frames.count)) }
            guard kind != 2 else { return }
            if let c = project.muteCurve(of: strip) { jm_plan_set_curve(plan, kind, index, 1, c.frames, c.values, Int32(c.frames.count)) }
            if let c = project.panCurve(of: strip) { jm_plan_set_curve(plan, kind, index, 2, c.frames, c.values, Int32(c.frames.count)) }
        }
        for t in project.tracks { if let i = trackIndex[t.id] { curve(t.id, kind: 0, index: i) } }
        for b in project.buses { if let i = busIndex[b.id] { curve(b.id, kind: 1, index: i) } }
        curve(Master.id, kind: 2, index: 0)
        // The master, when it does anything: its plugins (with a provider), its gain, its limiter last.
        let master = project.master
        if !master.isDefault {
            let chain = inserts.flatMap { master.inserts.contains(where: { !$0.bypass }) ? $0.masterChain(for: master) : nil }
            let limiter = master.limiter.flatMap { MasterLimiterUnit.chain($0.settings, channels: project.channels, sampleRate: project.sampleRate, marginDB: masterMargin) }
            jm_plan_set_master(plan, Float(dbToGain(master.gainDB)), chain, limiter)
            if let limiter { jm_chain_release(limiter) }
        }
        jm_plan_finalize(plan)
        return RenderPlan(plan, channels: project.channels, sampleRate: project.sampleRate)
    }
}

/// 0 dB is exactly 1, so untouched clips stay bit-exact.
public func dbToGain(_ db: Double) -> Double { db == 0 ? 1 : pow(10, db / 20) }
public func gainToDB(_ g: Double) -> Double { g > 0 ? 20 * log10(g) : -.infinity }
