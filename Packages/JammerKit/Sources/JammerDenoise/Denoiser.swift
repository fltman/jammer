import AVFoundation
import DeepFilter
import Foundation
import JammerCore

/// DeepFilterNet 3 noise reduction through libDF. Works on 48 kHz mono frames of
/// 480 samples; other rates are converted there and back. The model's delay is
/// removed, so the output lines up with the input sample for sample.
public final class Denoiser: @unchecked Sendable {
    public let modelPath: URL
    /// Measured with an impulse; see the tests.
    public static let delay = 1_440

    public init(modelPath: URL) throws {
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw Restoration.ApplyError.unreadable(modelPath.lastPathComponent)
        }
        self.modelPath = modelPath
    }

    /// The most the model may attenuate, from the amount control: 50 % → 6 dB,
    /// 90 % → 20 dB, 99 % → 40 dB, 100 % → no limit.
    public static func attenuationLimit(amount: Float) -> Float {
        amount >= 1 ? 100 : min(100, 20 * log10(1 / max(1e-5, 1 - amount)))
    }

    /// Denoises one channel at 48 kHz with a fresh model state, delay removed.
    public func process48k(_ x: [Float], amount: Float, delay: Int = Denoiser.delay) -> [Float] {
        guard let st = modelPath.path.withCString({ df_create($0, Self.attenuationLimit(amount: amount), nil) }) else { return x }
        defer { df_free(st) }
        let frame = Int(df_get_frame_length(st))
        let padded = x + [Float](repeating: 0, count: delay + frame)
        var out = [Float](repeating: 0, count: padded.count)
        var inBuf = [Float](repeating: 0, count: frame), outBuf = [Float](repeating: 0, count: frame)
        var i = 0
        while i + frame <= padded.count {
            for k in 0..<frame { inBuf[k] = padded[i + k] }
            _ = df_process_frame(st, &inBuf, &outBuf)
            for k in 0..<frame { out[i + k] = outBuf[k] }
            i += frame
        }
        return Array(out[delay..<(delay + x.count)])
    }

    /// Any rate: converted to 48 kHz and back around `process48k`.
    public func process(_ x: [Float], sampleRate: Double, amount: Float) -> [Float] {
        if sampleRate == 48_000 { return process48k(x, amount: amount) }
        guard let up = Self.convert(x, from: sampleRate, to: 48_000) else { return x }
        let y = process48k(up, amount: amount)
        guard var back = Self.convert(y, from: 48_000, to: sampleRate) else { return x }
        if back.count < x.count { back += [Float](repeating: 0, count: x.count - back.count) }
        return Array(back.prefix(x.count))
    }

    static func convert(_ x: [Float], from: Double, to: Double) -> [Float]? {
        guard let a = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 1, interleaved: false),
              let b = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: 1, interleaved: false),
              let c = AVAudioConverter(from: a, to: b),
              let inBuf = AVAudioPCMBuffer(pcmFormat: a, frameCapacity: AVAudioFrameCount(x.count)),
              let outBuf = AVAudioPCMBuffer(pcmFormat: b, frameCapacity: AVAudioFrameCount(Double(x.count) * to / from) + 4_096) else { return nil }
        c.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        inBuf.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer { inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
        var given = false
        var err: NSError?
        _ = c.convert(to: outBuf, error: &err) { _, state in
            if given { state.pointee = .endOfStream; return nil }
            given = true
            state.pointee = .haveData
            return inBuf
        }
        guard err == nil else { return nil }
        return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
    }

    /// Makes `Restoration` able to denoise (call once at start-up).
    public func register() {
        Restoration.denoiser = { [self] x, rate, amount in process(x, sampleRate: rate, amount: amount) }
    }
}
