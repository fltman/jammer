import AVFAudio
import Foundation
import JammerCore

/// Audio for speech models: one source, mono, 16 kHz (AVAudioConverter at its best quality).
public enum SpeechAudio {
    public static func mono16k(_ source: SourceRef, pool: SourcePool) throws -> [Float] {
        let rate = source.info.sampleRate, channels = source.info.channels
        guard let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFmt, to: outFmt) else { throw TranscriptionError.unreadableSource }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        var out: [Float] = []
        out.reserveCapacity(Int(Double(source.info.frames) * 16_000 / rate) + 1)
        let piece = Int(rate * 30)
        var at: Frame = 0
        while at < source.info.frames {
            let raw = pool.read(source, from: at, count: Int(min(Frame(piece), source.info.frames - at)))
            let n = raw.count / max(1, channels)
            guard n > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(n)) else { throw TranscriptionError.unreadableSource }
            inBuf.frameLength = AVAudioFrameCount(n)
            let d = inBuf.floatChannelData![0]
            for i in 0..<n {
                var v: Float = 0
                for c in 0..<channels { v += raw[i * channels + c] }
                d[i] = v / Float(channels)
            }
            let last = at + Frame(n) >= source.info.frames
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: AVAudioFrameCount(Double(n) * 16_000 / rate) + 1024) else { throw TranscriptionError.unreadableSource }
            var given = false
            var error: NSError?
            _ = converter.convert(to: outBuf, error: &error) { _, state in
                if given { state.pointee = last ? .endOfStream : .noDataNow; return nil }
                given = true
                state.pointee = .haveData
                return inBuf
            }
            if let error { throw TranscriptionError.failed(error.localizedDescription) }
            out += UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength))
            at += Frame(n)
        }
        return out
    }
}
