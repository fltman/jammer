import Foundation
import JammerEngine

/// The limiter as the last thing on the master. The streaming limiter gives back what it is given in
/// pieces of its own size; the engine wants a quantum out for every quantum in. So this holds a queue:
/// it starts with `latency` frames of silence in it, the limiter's output goes in at one end and a
/// quantum comes out at the other. What comes out is then the limited mix, exactly `latency` frames
/// late, and the mixer hides that lateness like any plugin's.
final class MasterLimiterUnit: @unchecked Sendable {
    let settings: Limiter
    let channels: Int
    let sampleRate: Double
    let marginDB: Double
    /// Frames: one of the limiter's own pieces, the reach of its oversampler, its lookahead, and a few to spare.
    let latency: Int
    private var processor: Limiter.Processor
    private var queue: [Float]
    private var head = 0
    private var scratch: [Float] = []

    init(_ settings: Limiter, channels: Int, sampleRate: Double, marginDB: Double) throws {
        self.settings = settings
        self.channels = channels
        self.sampleRate = sampleRate
        self.marginDB = marginDB
        processor = try Limiter.Processor(settings, channels: channels, sampleRate: sampleRate, marginDB: marginDB)
        latency = Limiter.Processor.chunk + Limiter.Processor.reach + processor.lookahead + 8
        queue = [Float](repeating: 0, count: latency * channels)
    }

    /// Planar in, planar out, `frames` of each. False (the chain then passes the input on, as late) only
    /// if the limiter fell behind what the queue allows for, which the latency above rules out.
    func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        if scratch.count != frames * channels { scratch = [Float](repeating: 0, count: frames * channels) }
        for c in 0..<channels { for i in 0..<frames { scratch[i * channels + c] = input[c * frames + i] } }
        queue.append(contentsOf: processor.process(scratch))
        guard queue.count - head >= frames * channels else { return false }
        for c in 0..<channels { for i in 0..<frames { output[c * frames + i] = queue[head + i * channels + c] } }
        head += frames * channels
        if head > 1 << 16 { queue.removeFirst(head); head = 0 }
        return true
    }

    func reset() {
        // The settings were valid when this was made; they still are.
        if let p = try? Limiter.Processor(settings, channels: channels, sampleRate: sampleRate, marginDB: marginDB) { processor = p }
        queue = [Float](repeating: 0, count: latency * channels)
        head = 0
    }

    /// A chain holding this limiter and nothing else (the caller releases it).
    static func chain(_ settings: Limiter, channels: Int, sampleRate: Double, marginDB: Double) -> OpaquePointer? {
        guard let me = try? MasterLimiterUnit(settings, channels: channels, sampleRate: sampleRate, marginDB: marginDB) else { return nil }
        let unit = jm_unit_create_processor(Int32(channels), Unmanaged.passRetained(me).toOpaque(), { ctx, input, output, _, frames in
            guard let ctx else { return false }
            return Unmanaged<MasterLimiterUnit>.fromOpaque(ctx).takeUnretainedValue().process(input, output, frames: Int(frames))
        }, { ctx in
            if let ctx { Unmanaged<MasterLimiterUnit>.fromOpaque(ctx).takeUnretainedValue().reset() }
        }, { ctx in
            if let ctx { Unmanaged<MasterLimiterUnit>.fromOpaque(ctx).release() }
        })
        // Run-in after a seek: the release has to have died away from whatever came before.
        let preroll = Int64(max(0.25, min(2, settings.releaseMs / 1_000 * 5)) * sampleRate)
        let chain = jm_chain_create(Int32(channels), preroll)
        jm_chain_add(chain, unit, Int64(me.latency))
        jm_unit_release(unit)
        return chain
    }
}

/// Keeps the master's limiter alive from one playing plan to the next. A limiter made anew for every
/// plan has no memory of the level it was holding, and a plan with a new limiter can't go on from the
/// one before it (every plugin would start afresh, cutting a reverb's tail at each mix change). With a
/// keeper, plans whose limiter settings are the same get the very same limiter, state and all. Only
/// the plan that plays uses one: an export or a measurement makes its own limiter, as before.
public final class LimiterKeeper: @unchecked Sendable {
    private struct Key: Equatable { var settings: Limiter; var channels: Int; var sampleRate: Double; var marginDB: Double }
    private var key: Key?
    private var kept: OpaquePointer?
    private let lock = NSLock()
    public init() {}
    deinit { if let kept { jm_chain_release(kept) } }

    /// The limiter's chain for these settings: the one from last time when they are the same, a new one
    /// otherwise. Owned by the keeper: the caller hands it to a plan and does not release it.
    func chain(_ settings: Limiter, channels: Int, sampleRate: Double, marginDB: Double) -> OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        let wanted = Key(settings: settings, channels: channels, sampleRate: sampleRate, marginDB: marginDB)
        if wanted == key, let kept { return kept }
        if let kept { jm_chain_release(kept) }
        kept = MasterLimiterUnit.chain(settings, channels: channels, sampleRate: sampleRate, marginDB: marginDB)
        key = kept == nil ? nil : wanted
        return kept
    }
}

