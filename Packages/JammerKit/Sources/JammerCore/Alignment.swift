import Accelerate
import AudioToolbox
import Foundation

/// Lines up separately recorded tracks (double-enders): where does `other` sit against
/// `reference`? Coarse cross-correlation by FFT on a 4 kHz copy, then exact to the
/// sample at the full rate around the peak. Drift (two recorders' clocks disagreeing)
/// is measured by aligning the start and the end separately.
public enum Alignment {
    public struct Result: Sendable, Equatable {
        /// Frames to move `other` right (negative: left) so it lines up with `reference`.
        public var offset: Frame
        /// Normalised correlation (Pearson) of the two at that offset: near 1 for the same
        /// sound through different mics, near 0 for unrelated audio. Above 0.5 is a clear match.
        public var confidence: Double
    }

    public struct Drift: Sendable, Equatable {
        public var start: Result
        public var end: Result
        /// How far the two clocks part over the stretch measured, in frames.
        public var frames: Frame
        public var partsPerMillion: Double
    }

    /// Mono at `rate` from interleaved samples.
    static func mono(_ x: [Float], channels: Int) -> [Float] {
        guard channels > 1 else { return x }
        let n = x.count / channels
        return (0..<n).map { i in (0..<channels).reduce(Float(0)) { $0 + x[i * channels + $1] } / Float(channels) }
    }

    /// Cross-correlation by FFT: c[k] = Σ a[n] b[n + k] for k in −(b.count−1)…(a.count−1).
    static func correlate(_ a: [Float], _ b: [Float]) -> (values: [Float], zeroIndex: Int) {
        let n = a.count + b.count - 1
        var size = 1
        var log2n = 0
        while size < n { size <<= 1; log2n += 1 }
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return ([], 0) }
        defer { vDSP_destroy_fftsetup(setup) }
        func spectrum(_ x: [Float]) -> ([Float], [Float]) {
            var padded = x + [Float](repeating: 0, count: size - x.count)
            var re = [Float](repeating: 0, count: size / 2), im = [Float](repeating: 0, count: size / 2)
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    padded.withUnsafeMutableBytes { raw in
                        vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(size / 2))
                    }
                    vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(kFFTDirection_Forward))
                }
            }
            return (re, im)
        }
        // corr(a, b)[k] = IFFT(conj(A) · B) gives Σ a[n] b[n+k]; reverse roles for our sign.
        let (ar, ai) = spectrum(a), (br, bi) = spectrum(b)
        var pr = [Float](repeating: 0, count: size / 2), pi = [Float](repeating: 0, count: size / 2)
        // DC and Nyquist are packed in [0]: real parts only.
        pr[0] = ar[0] * br[0]
        pi[0] = ai[0] * bi[0]
        for k in 1..<(size / 2) {
            // conj(B) · A  → correlation of a against shifts of b
            pr[k] = ar[k] * br[k] + ai[k] * bi[k]
            pi[k] = ai[k] * br[k] - ar[k] * bi[k]
        }
        var out = [Float](repeating: 0, count: size)
        pr.withUnsafeMutableBufferPointer { r in
            pi.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(kFFTDirection_Inverse))
                out.withUnsafeMutableBytes { raw in
                    vDSP_ztoc(&split, 1, raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(size / 2))
                }
            }
        }
        // out[m] = Σ a[n] b[n − m] (circular); lag m ≥ 0 at m, negative at size + m.
        return (out, size)
    }

    /// Where `other` lines up against `reference`, searching ±`maxLag` frames.
    public static func offset(reference: [Float], other: [Float], sampleRate: Double, maxLag: Frame) -> Result {
        // Coarse at 4 kHz (absolute values, so phase differences between mics don't cancel).
        let step = max(1, Int(sampleRate / 4_000))
        func decimate(_ x: [Float]) -> [Float] {
            stride(from: 0, to: x.count - step + 1, by: step).map { i in
                var s: Float = 0
                for k in i..<(i + step) { s += abs(x[k]) }
                return s / Float(step)
            }
        }
        var a = decimate(reference), b = decimate(other)
        let meanA = a.reduce(0, +) / Float(max(1, a.count)), meanB = b.reduce(0, +) / Float(max(1, b.count))
        a = a.map { $0 - meanA }
        b = b.map { $0 - meanB }
        let (c, size) = correlate(a, b)
        let maxCoarse = Int(maxLag) / step + 1
        var best = 0, bestV = -Float.infinity
        for m in -maxCoarse...maxCoarse {
            let idx = m >= 0 ? m : size + m
            guard idx >= 0, idx < c.count else { continue }
            if c[idx] > bestV { bestV = c[idx]; best = m }
        }
        // Fine: the sample lag around the coarse one, at the full rate. A positive coarse m
        // means reference[n] matches other[n − m·step], i.e. other must move right by m·step.
        let coarse = best * step
        var fineBest = coarse, fineV = -Double.infinity
        let span = 2 * step
        let len = min(reference.count, other.count) - 2 * span - abs(coarse)
        if len > 0 {
            let sampleStep = max(1, len / 200_000)
            for lag in (coarse - span)...(coarse + span) {
                var v = 0.0
                var n = span + max(0, lag)
                while n < span + max(0, lag) + len {
                    let j = n - lag
                    if j >= 0, j < other.count, n < reference.count { v += Double(reference[n]) * Double(other[j]) }
                    n += sampleStep
                }
                if v > fineV { fineV = v; fineBest = lag }
            }
        }
        // Confidence: Pearson correlation over the overlap at the found offset.
        var sab = 0.0, saa = 0.0, sbb = 0.0
        let lo = max(0, fineBest), hi = min(reference.count, other.count + fineBest)
        let by = max(1, (hi - lo) / 400_000)
        var n = lo
        while n < hi {
            let a = Double(reference[n]), b = Double(other[n - fineBest])
            sab += a * b; saa += a * a; sbb += b * b
            n += by
        }
        let rho = saa > 0 && sbb > 0 ? sab / (saa * sbb).squareRoot() : 0
        return Result(offset: Frame(fineBest), confidence: (rho * 1_000).rounded() / 1_000)
    }

    /// Aligns a window at the start and one at the end, at the same places in both files;
    /// the difference between the two offsets is how far the clocks parted.
    public static func drift(reference: [Float], other: [Float], sampleRate: Double, maxLag: Frame, window: Double = 60) -> Drift? {
        let w = Int(sampleRate * window)
        let n = min(reference.count, other.count)
        guard n > 3 * w else { return nil }
        let start = offset(reference: Array(reference[0..<w]), other: Array(other[0..<w]), sampleRate: sampleRate, maxLag: maxLag)
        let tail = n - w
        let end = offset(reference: Array(reference[tail..<n]), other: Array(other[tail..<n]), sampleRate: sampleRate, maxLag: maxLag)
        let parted = end.offset - start.offset
        return Drift(start: start, end: end, frames: parted, partsPerMillion: Double(parted) / Double(tail) * 1_000_000)
    }
}

extension Project {
    /// Adds a track playing all of `source` from `start`.
    @discardableResult
    public mutating func addTrack(source: SourceRef, name: String? = nil, start: Frame = 0) -> Track {
        if self.source(source.id) == nil { sources.append(source) }
        let t = Track(name: name ?? source.name, clips: [Clip(sourceID: source.id, start: start, length: source.info.frames)])
        tracks.append(t)
        return t
    }

    /// One track's own audio, mono, over `range` (track gain and mute ignored).
    func soloMono(_ t: Int, _ range: Range<Frame>, pool: SourcePool) -> [Float] {
        var solo = self
        solo.tracks = [tracks[t]]
        solo.withoutMixer()
        solo.tracks[0].isMuted = false
        solo.tracks[0].gainDB = 0
        let raw = PlanCompiler.compile(solo, pool: pool).render(from: range.lowerBound, frames: range.count)
        return Alignment.mono(raw, channels: channels)
    }

    /// Moves `tracks` (default: every other track) so they line up with `reference`,
    /// measured on the first `window` seconds. Only matches above `minConfidence` move.
    public mutating func alignTracks(to reference: UUID, tracks ids: [UUID]? = nil, pool: SourcePool, window: Double = 120,
                                     maxLag: Double = 30, minConfidence: Double = 0.5) -> [UUID: Alignment.Result] {
        guard let r = tracks.firstIndex(where: { $0.id == reference }) else { return [:] }
        let span = 0..<min(length, frames(window + maxLag))
        let ref = soloMono(r, span, pool: pool)
        var out: [UUID: Alignment.Result] = [:]
        for t in tracks.indices where t != r && (ids?.contains(tracks[t].id) ?? true) {
            let other = soloMono(t, span, pool: pool)
            let res = Alignment.offset(reference: ref, other: other, sampleRate: sampleRate, maxLag: frames(maxLag))
            out[tracks[t].id] = res
            guard res.confidence >= minConfidence, res.offset != 0 else { continue }
            for c in tracks[t].clips.indices { tracks[t].clips[c].start += res.offset }
            // A track can't start before 0: trim the front instead.
            tracks[t].clips = tracks[t].clips.compactMap { c in
                guard c.start < 0 else { return c }
                var c = c
                let cut = -c.start
                guard cut < c.length else { return nil }
                c.sourceStart += cut
                c.length -= cut
                c.start = 0
                c.fadeIn = max(0, c.fadeIn - cut)
                return c
            }
        }
        return out
    }
}

extension Project {
    /// How far `track` drifts against `reference` over their overlap (two windows only, so
    /// it's quick on long files). nil when they overlap less than three windows.
    public func drift(of track: UUID, against reference: UUID, pool: SourcePool, window: Double = 30, maxLag: Double = 1) -> Alignment.Drift? {
        guard let t = tracks.firstIndex(where: { $0.id == track }), let r = tracks.firstIndex(where: { $0.id == reference }) else { return nil }
        let end = min(tracks[t].end, tracks[r].end)
        let begin = max(tracks[t].clips.first?.start ?? 0, tracks[r].clips.first?.start ?? 0)
        let w = frames(window)
        guard end - begin > 3 * w else { return nil }
        let a = begin..<(begin + w), b = (end - w)..<end
        let s = Alignment.offset(reference: soloMono(r, a, pool: pool), other: soloMono(t, a, pool: pool), sampleRate: sampleRate, maxLag: frames(maxLag))
        let e = Alignment.offset(reference: soloMono(r, b, pool: pool), other: soloMono(t, b, pool: pool), sampleRate: sampleRate, maxLag: frames(maxLag))
        let parted = e.offset - s.offset
        return Alignment.Drift(start: s, end: e, frames: parted, partsPerMillion: Double(parted) / Double(end - w - begin) * 1_000_000)
    }
}

extension Project {
    /// The track that lines up best with all the others: in a double-ender that's the call
    /// recording (Zoom, Riverside, phone), where every speaker can be heard.
    public func suggestedReference(pool: SourcePool, window: Double = 60, maxLag: Double = 10) -> UUID? {
        guard tracks.count > 2 else { return tracks.first?.id }
        let span = 0..<min(length, frames(window + maxLag))
        let monos = tracks.indices.map { soloMono($0, span, pool: pool) }
        var best: (Int, Double)?
        for i in tracks.indices {
            let score = tracks.indices.filter { $0 != i }.map {
                Alignment.offset(reference: monos[i], other: monos[$0], sampleRate: sampleRate, maxLag: frames(maxLag)).confidence
            }.reduce(0, +)
            if best == nil || score > best!.1 { best = (i, score) }
        }
        return best.map { tracks[$0.0].id }
    }
}

extension Alignment {
    /// Interleaved float from one rate to another with AudioConverter (highest quality).
    public static func resample(_ x: [Float], channels: Int, from: Double, to: Double) throws -> [Float] {
        var inFmt = AudioStreamBasicDescription(mSampleRate: from, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
                                                mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var outFmt = inFmt
        outFmt.mSampleRate = to
        var conv: AudioConverterRef?
        guard AudioConverterNew(&inFmt, &outFmt, &conv) == noErr, let conv else { throw ExportError.unsupported("Can't resample.") }
        defer { AudioConverterDispose(conv) }
        var complexity = kAudioConverterSampleRateConverterComplexity_Mastering
        AudioConverterSetProperty(conv, kAudioConverterSampleRateConverterComplexity, 4, &complexity)
        var quality = kAudioConverterQuality_Max
        AudioConverterSetProperty(conv, kAudioConverterSampleRateConverterQuality, 4, &quality)
        let inFrames = x.count / channels
        let outCapacity = Int(Double(inFrames) * to / from) + 4_096
        var out = [Float](repeating: 0, count: outCapacity * channels)
        final class Feed { var data: [Float]; var given = false; init(_ d: [Float]) { data = d } }
        let feed = Feed(x)
        var packets = UInt32(outCapacity)
        let status = out.withUnsafeMutableBytes { raw -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            return AudioConverterFillComplexBuffer(conv, { _, ioPackets, ioData, _, user in
                let f = Unmanaged<Feed>.fromOpaque(user!).takeUnretainedValue()
                if f.given { ioPackets.pointee = 0; ioData.pointee.mBuffers.mDataByteSize = 0; return noErr }
                f.given = true
                let ch = Int(ioData.pointee.mBuffers.mNumberChannels)
                ioPackets.pointee = UInt32(f.data.count / max(1, ch))
                f.data.withUnsafeMutableBytes { r in
                    ioData.pointee.mBuffers.mData = r.baseAddress
                    ioData.pointee.mBuffers.mDataByteSize = UInt32(r.count)
                }
                return noErr
            }, Unmanaged.passUnretained(feed).toOpaque(), &packets, &list, nil)
        }
        guard status == noErr else { throw ExportError.encoder("resample", status) }
        return Array(out.prefix(Int(packets) * channels))
    }
}

extension Project {
    /// Corrects a recorder's clock drift: the track is resampled by `ppm` (positive: it ran
    /// fast) into a new file, anchored where it starts, so it stays in sync to the end.
    public func correctingDrift(of track: UUID, ppm: Double, pool: SourcePool, media: URL) throws -> Project {
        guard let t = tracks.firstIndex(where: { $0.id == track }), let first = tracks[t].clips.first?.start else { throw EffectError.nothingInRange }
        guard abs(ppm) < 2_000 else { throw EffectError.badValue("A drift of \(ppm) ppm is beyond what a recorder does; check the measurement.") }
        let end = tracks[t].end
        var solo = self
        solo.tracks = [tracks[t]]
        solo.withoutMixer()
        solo.tracks[0].gainDB = 0
        solo.tracks[0].isMuted = false
        let raw = PlanCompiler.compile(solo, pool: pool).render(from: first, frames: Int(end - first))
        // Played at sampleRate·(1 + ppm/1e6) it would match; so stretch it by that factor.
        let corrected = try Alignment.resample(raw, channels: channels, from: sampleRate, to: sampleRate * (1 + ppm / 1_000_000))
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let url = media.appending(path: "\(UUID().uuidString.prefix(8)) drift.wav")
        // Noted as made by Jämmer: only such a file can ever be offered for removal (MediaStorage).
        MediaRegister.made(url, kind: "drift", in: media)
        let w = try WAVWriter(url: url, options: .init(encoding: .float32, channels: channels, sampleRate: sampleRate))
        try w.write(corrected)
        try w.finish()
        let src = SourceRef(name: "\(tracks[t].name) (drift corrected)", path: url.path, info: try AudioFileReader.info(at: url)).withRepairs(repairsCarried(by: tracks[t]))
        var p = self
        p.sources.append(src)
        // Words and speaker turns go to the new file, stretched like the audio.
        let scale = 1 + ppm / 1_000_000
        let words = placedWords(in: first..<end).filter { $0.track == t }.map { w -> Word in
            var w2 = w.word
            w2.start = Frame((Double(w.start - first) * scale).rounded())
            w2.end = Frame((Double(w.end - first) * scale).rounded())
            return w2
        }
        if !words.isEmpty {
            p.setTranscript(SourceTranscript(sourceID: src.id, language: transcripts.first?.language ?? "und", engine: "carried", words: words, speakers: speakers))
        }
        p.addCarriedTurns(turnsForBounce(track: t, range: first..<end, scale: scale), to: src.id)
        p.tracks[t].clips = [Clip(sourceID: src.id, start: first, length: src.info.frames)]
        p.pruneSources()
        return p
    }
}
