import Foundation

/// Sample rate conversion as the rest of Jämmer sees it. The converter itself (r8brain, in the
/// JammerResample module) registers here, the way the MP3 encoder does, so that the core and the batch
/// runner can convert without linking it: one converter in the app, wherever a rate has to change.
public enum SampleRateConversion {
    /// A running conversion: interleaved blocks in, interleaved blocks out; `finish` gives what is still held.
    public typealias Stream = (process: ([Float]) -> [Float], finish: () -> [Float])
    nonisolated(unsafe) public static var factory: ((_ from: Double, _ to: Double, _ channels: Int) throws -> Stream)?

    /// The rates a file can be written at.
    public static let rates: [Double] = [8_000, 11_025, 16_000, 22_050, 32_000, 44_100, 48_000, 88_200, 96_000, 176_400, 192_000]
    public static var ratesList: String { rates.map { String(Int($0)) }.joined(separator: ", ") }

    public struct Unavailable: Error, LocalizedError {
        public var errorDescription: String? { "Sample rate conversion isn't available in this build." }
    }

    /// `range` of `plan` at `rate`, written as a 32-bit float WAV at `url`: what an export at another rate
    /// than the document's is then made from. `progress` gets 0…1.
    public static func render(_ plan: RenderPlan, range: Range<Frame>, to rate: Double, into url: URL,
                              progress: (Double) -> Void = { _ in }) throws -> SourceRef {
        guard let factory else { throw Unavailable() }
        let stream = try factory(plan.sampleRate, rate, plan.channels)
        let writer = try WAVWriter(url: url, options: .init(encoding: .float32, channels: plan.channels, sampleRate: rate))
        let total = Double(max(1, range.count))
        var done = 0.0
        try plan.render(range) { block in
            try writer.write(stream.process(Array(block)))
            done += Double(block.count / plan.channels)
            progress(done / total)
        }
        try writer.write(stream.finish())
        try writer.finish()
        return SourceRef(name: "converted", path: url.path, info: try AudioFileReader.info(at: url))
    }

    /// A whole buffer.
    public static func convert(_ interleaved: [Float], channels: Int, from: Double, to: Double) throws -> [Float] {
        if from == to { return interleaved }
        guard let factory else { throw Unavailable() }
        let s = try factory(from, to, channels)
        return s.process(interleaved) + s.finish()
    }
}
