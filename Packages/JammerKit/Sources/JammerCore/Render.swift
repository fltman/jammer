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
    /// Where each track and bus is in the plan (kind 0 a track, 1 a bus), for a level put on while it plays.
    public internal(set) var strips: [UUID: (kind: Int32, index: Int32)] = [:]
    /// Which plan this is among all that have been made: what a level under a hand is tied to.
    public var serial: UInt64 { jm_plan_serial(pointer) }

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
    /// A source whose place moves: the engine's panner gets the layout once and the azimuth and elevation as
    /// lines over the timeline (a lane's points, or the track's fixed value as one point).
    static func placeMoving(_ plan: OpaquePointer, source: Int32, position: SurroundPosition, azimuth: AutomationLane?, elevation: AutomationLane?, layout: ChannelLayout) {
        setPanLayout(plan, layout)
        func line(_ lane: AutomationLane?, _ fixed: Double) -> ([Int64], [Float]) {
            guard let lane else { return ([0], [Float(fixed)]) }
            return (lane.points.map { Int64($0.frame) }, lane.points.map { Float($0.value) })
        }
        var (af, av) = line(azimuth, position.azimuth), (ef, ev) = line(elevation, position.elevation)
        jm_plan_set_source_placement(plan, source, &af, &av, Int32(af.count), &ef, &ev, Int32(ef.count), position.width)
    }
    static func setPanLayout(_ plan: OpaquePointer, _ layout: ChannelLayout) {
        if let order = layout.ambisonicOrder { jm_plan_set_pan_layout(plan, Int32(order), nil, nil, nil, 0); return }
        var ch: [Int32] = [], az: [Double] = [], el: [Double] = []
        for (i, s) in layout.speakers.enumerated() {
            guard let d = s.direction(in: layout) else { continue }
            ch.append(Int32(i)); az.append(d.azimuth); el.append(d.elevation)
        }
        jm_plan_set_pan_layout(plan, 0, &ch, &az, &el, Int32(ch.count))
    }

    /// Compiles the project into what the engine plays. Clips whose file is missing are left out.
    /// Inserts run only when `inserts` supplies their chains; without it the plan is the
    /// dry mix (what the bounced effects and restoration work from).
    /// `masterMargin`: how far under its ceiling the master's limiter aims (dB); an export that measured
    /// its file over the ceiling renders again with more.
    /// `ridable`: every track is worked as a strip of its own, so that a fader can be ridden on it while
    /// the plan plays (the mixer window is in use). The sound is the same; only the playing plan asks for it.
    public static func compile(_ project: Project, pool: SourcePool, inserts: ChainProvider? = nil, masterMargin: Double = Mixer.masterMargins[0], ridable: Bool = false,
                               limiters: LimiterKeeper? = nil) -> RenderPlan {
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
                // A bus's image turned round the listener: fixed, or by its azimuth lane.
                let turnLane = project.lane(strip: b.id, param: .azimuth).flatMap { $0.enabled && !$0.points.isEmpty ? $0 : nil }
                if project.channels > 2, !project.layout.isAmbisonic, b.azimuth != nil || turnLane != nil {
                    setPanLayout(plan, project.layout)
                    var f: [Int64] = turnLane?.points.map { Int64($0.frame) } ?? [0]
                    var v: [Float] = turnLane?.points.map { Float($0.value) } ?? [Float(b.azimuth ?? 0)]
                    jm_plan_set_bus_turn(plan, index, &f, &v, Int32(f.count))
                }
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
            if ridable { jm_plan_set_track_live(plan, track, true) }
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
            // A track placed by the surround panner has its own copies of its mono and stereo sources in the
            // plan, each with its place: fixed, or moving by its azimuth and elevation lanes, worked out by the
            // engine as it plays (the same source on another track is placed there).
            let azLane = project.lane(strip: t.id, param: .azimuth).flatMap { $0.enabled && !$0.points.isEmpty ? $0 : nil }
            let elLane = project.lane(strip: t.id, param: .elevation).flatMap { $0.enabled && !$0.points.isEmpty ? $0 : nil }
            let panned: SurroundPosition? = project.channels > 2 && (t.position != nil || azLane != nil || elLane != nil) ? (t.position ?? SurroundPosition()) : nil
            var ownIndices: [UUID: Int32] = [:]
            for c in t.clips {
                guard let ref = project.source(c.sourceID) else { continue }
                let index: Int32
                if let position = panned, ref.info.channels <= 2 {
                    if let i = ownIndices[ref.id] {
                        index = i
                    } else {
                        guard let s = pool.source(for: ref) else { continue }
                        index = jm_plan_add_source(plan, s)
                        ownIndices[ref.id] = index
                        if azLane == nil, elLane == nil {
                            let m = Panner.matrix(position, sourceChannels: ref.info.channels, in: project.layout)
                            m.withUnsafeBufferPointer { jm_plan_set_source_matrix(plan, index, $0.baseAddress!, Int32(ref.info.channels)) }
                        } else {
                            Self.placeMoving(plan, source: index, position: position, azimuth: azLane, elevation: elLane, layout: project.layout)
                        }
                    }
                } else if let i = indices[ref.id] {
                    index = i
                } else {
                    guard let s = pool.source(for: ref) else { continue }
                    index = jm_plan_add_source(plan, s)
                    indices[ref.id] = index
                    // Into a layout wider than stereo (or from one): each channel to its loudspeaker.
                    if let m = project.layout.matrix(sourceChannels: ref.info.channels, sourceMask: ref.info.channelMask) {
                        m.withUnsafeBufferPointer { jm_plan_set_source_matrix(plan, index, $0.baseAddress!, Int32(ref.info.channels)) }
                    }
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
        // Lanes on plugins' parameters: where the plugin runs and can be set while it does (see InsertUnit.address).
        if let inserts {
            func parameters(_ strip: UUID, kind: Int32, index: Int32) {
                let on = project.inserts(of: strip)
                for lane in project.pluginLanes(of: strip) {
                    guard let insert = lane.insert, let name = lane.parameter, let place = inserts.parameterPlace(of: insert, among: on, identifier: name) else { continue }
                    jm_plan_add_param_curve(plan, kind, index, place.unit, place.parameter, lane.points.map(\.frame), lane.points.map { Float($0.value) }, Int32(lane.points.count))
                }
            }
            for t in project.tracks { if let i = trackIndex[t.id] { parameters(t.id, kind: 0, index: i) } }
            for b in project.buses { if let i = busIndex[b.id] { parameters(b.id, kind: 1, index: i) } }
            parameters(Master.id, kind: 2, index: 0)
        }
        // The master, when it does anything: its plugins (with a provider), its gain, its limiter last.
        let master = project.master
        if !master.isDefault {
            let chain = inserts.flatMap { master.inserts.contains(where: { !$0.bypass }) ? $0.masterChain(for: master) : nil }
            // The plan that plays keeps its limiter from the plan before it (see LimiterKeeper); any other render makes its own.
            if let limiters {
                let limiter = master.limiter.flatMap { limiters.chain($0.settings, channels: project.channels, sampleRate: project.sampleRate, marginDB: masterMargin) }
                jm_plan_set_master(plan, Float(dbToGain(master.gainDB)), chain, limiter)
            } else {
                let limiter = master.limiter.flatMap { MasterLimiterUnit.chain($0.settings, channels: project.channels, sampleRate: project.sampleRate, marginDB: masterMargin) }
                jm_plan_set_master(plan, Float(dbToGain(master.gainDB)), chain, limiter)
                if let limiter { jm_chain_release(limiter) }
            }
        }
        jm_plan_finalize(plan)
        let made = RenderPlan(plan, channels: project.channels, sampleRate: project.sampleRate)
        for (id, i) in trackIndex { made.strips[id] = (0, i) }
        for (id, i) in busIndex { made.strips[id] = (1, i) }
        return made
    }
}

/// 0 dB is exactly 1, so untouched clips stay bit-exact.
public func dbToGain(_ db: Double) -> Double { db == 0 ? 1 : pow(10, db / 20) }
public func gainToDB(_ g: Double) -> Double { g > 0 ? 20 * log10(g) : -.infinity }
