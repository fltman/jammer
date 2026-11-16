import Foundation
import JammerResampleC

/// Sample rate conversion for exports, with r8brain-free-src (see docs/LICENSES.md and docs/MASTERING.md
/// for what it was measured to). Feed interleaved blocks to `process`, then call `finish`: together they
/// return exactly round(frames in × to / from) frames, starting where the input started.
public final class Resampler {
    public enum Failure: Error, LocalizedError, Equatable {
        case badRate(String)
        public var errorDescription: String? { if case .badRate(let m) = self { return m }; return nil }
    }

    /// The rates an export may ask for.
    public static let rates: [Double] = [8_000, 11_025, 16_000, 22_050, 32_000, 44_100, 48_000, 88_200, 96_000, 176_400, 192_000]
    public static var version: String { String(cString: jr_version()) }

    public let from: Double, to: Double, channels: Int
    private let handle: OpaquePointer
    private var out: [Float]
    private var framesIn: Int64 = 0, framesOut: Int64 = 0
    private var finished = false
    static let block = 4_096

    public init(from: Double, to: Double, channels: Int) throws {
        guard from.isFinite, to.isFinite, (1_000...1_000_000).contains(from) else { throw Failure.badRate("The audio's sample rate can't be converted from.") }
        guard Self.rates.contains(to) else {
            throw Failure.badRate("sampleRate must be one of \(Self.rates.map { String(Int($0)) }.joined(separator: ", ")).")
        }
        guard (1...64).contains(channels), let h = jr_create(from, to, Int32(channels), Int32(Self.block)) else { throw Failure.badRate("That channel count can't be converted.") }
        self.from = from; self.to = to; self.channels = channels
        handle = h
        out = [Float](repeating: 0, count: Int(jr_max_out(h)) * channels)
    }
    deinit { jr_destroy(handle) }

    private var owed: Int64 { Int64((Double(framesIn) * to / from).rounded()) - framesOut }

    private func run(_ x: UnsafePointer<Float>, _ frames: Int, into all: inout [Float], limit: Int64) {
        let n = Int(jr_process(handle, x, Int32(frames), &out, Int32(out.count / channels)))
        guard n > 0 else { return }
        let take = Int(min(Int64(n), max(0, limit)))
        all.append(contentsOf: out[0..<(take * channels)])
        framesOut += Int64(take)
    }

    public func process(_ interleaved: [Float]) -> [Float] {
        precondition(!finished && interleaved.count % channels == 0)
        var all: [Float] = []
        all.reserveCapacity(Int(Double(interleaved.count) * to / from) + channels * 64)
        interleaved.withUnsafeBufferPointer { p in
            var at = 0
            let frames = interleaved.count / channels
            while at < frames {
                let n = min(Self.block, frames - at)
                framesIn += Int64(n)
                // Never more than the input so far amounts to at the new rate.
                run(p.baseAddress! + at * channels, n, into: &all, limit: owed)
                at += n
            }
        }
        return all
    }

    /// What the converter still holds: silence is fed until every frame the input amounts to has come out.
    public func finish() -> [Float] {
        guard !finished else { return [] }
        finished = true
        var all: [Float] = []
        let silence = [Float](repeating: 0, count: Self.block * channels)
        var tries = 0
        while owed > 0, tries < 10_000 {
            silence.withUnsafeBufferPointer { run($0.baseAddress!, Self.block, into: &all, limit: owed) }
            tries += 1
        }
        return all
    }

    /// A whole buffer at once.
    public static func convert(_ interleaved: [Float], channels: Int, from: Double, to: Double) throws -> [Float] {
        if from == to { return interleaved }
        let r = try Resampler(from: from, to: to, channels: channels)
        return r.process(interleaved) + r.finish()
    }
}
