import AVFAudio
import Foundation
import JammerCore

/// Audio for speech models: one source, mono, 16 kHz (AVAudioConverter at its best quality).
public enum SpeechAudio {
    public static func mono16k(_ source: SourceRef, pool: SourcePool, maxFrames: Frame? = nil) throws -> [Float] {
        let rate = source.info.sampleRate, channels = source.info.channels
        guard let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFmt, to: outFmt) else { throw TranscriptionError.unreadableSource }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let frames = min(source.info.frames, maxFrames ?? source.info.frames)
        var out: [Float] = []
        out.reserveCapacity(Int(Double(frames) * 16_000 / rate) + 1)
        let piece = Int(rate * 30)
        var at: Frame = 0
        while at < frames {
            try Task.checkCancellation()
            let raw = pool.read(source, from: at, count: Int(min(Frame(piece), frames - at)))
            let n = raw.count / max(1, channels)
            guard n > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(n)) else { throw TranscriptionError.unreadableSource }
            inBuf.frameLength = AVAudioFrameCount(n)
            let d = inBuf.floatChannelData![0]
            for i in 0..<n {
                var v: Float = 0
                for c in 0..<channels { v += raw[i * channels + c] }
                d[i] = v / Float(channels)
            }
            let last = at + Frame(n) >= frames
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

    static let rate = 16_000

    /// Where to cut `samples` into pieces of at most `limit` samples: each cut at the quietest 0.4 s
    /// within `search` samples before the limit. Returns the piece boundaries, first 0, last `count`.
    static func cuts(_ samples: [Float], limit: Int, search: Int) -> [Int] {
        var out = [0]
        let window = max(1, rate * 4 / 10), hop = max(1, window / 4)
        while samples.count - out.last! > limit {
            let end = out.last! + limit
            let from = max(out.last! + limit / 2, end - search)
            var best = end, quietest = Float.greatestFiniteMagnitude
            var at = from
            while at + window <= end {
                var e: Float = 0
                for i in at..<(at + window) { e += samples[i] * samples[i] }
                if e < quietest { quietest = e; best = at + window / 2 }
                at += hop
            }
            out.append(best)
        }
        out.append(samples.count)
        return out
    }

    /// The words of a piece, spread over it by their length: there are no times to go by.
    static func spread(_ text: String, over range: Range<Frame>) -> [Word] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let total = tokens.reduce(0) { $0 + $1.count }
        guard total > 0, !range.isEmpty else { return [] }
        var out: [Word] = []
        var done = 0
        for t in tokens {
            let a = range.lowerBound + Frame(Double(range.count) * Double(done) / Double(total))
            done += t.count
            let b = range.lowerBound + Frame(Double(range.count) * Double(done) / Double(total))
            out.append(Word(text: t, start: a, end: max(a + 1, b), untimed: true))
        }
        return out
    }

    static func pcm16(_ samples: ArraySlice<Float>) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = Int16(max(-1, min(1, sample)) * 32_767).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }
}
