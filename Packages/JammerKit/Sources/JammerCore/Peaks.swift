import CryptoKit
import Foundation

/// Min/max overviews of a source at several resolutions, so a waveform of a
/// multi-hour file draws at any zoom without reading the file.
/// Level 0 has one min/max pair per 256 frames; each further level merges 4.
public final class PeakIndex: @unchecked Sendable {
    public static let baseBlock = 256
    public static let fanout = 4

    public let channels: Int
    public let frames: Int64
    /// levels[l][(block * channels + ch) * 2 + 0/1] = min/max.
    public let levels: [[Float]]

    init(channels: Int, frames: Int64, level0: [Float]) {
        self.channels = channels
        self.frames = frames
        var levels = [level0]
        while let last = levels.last, last.count / (2 * channels) > 1 {
            let blocks = last.count / (2 * channels)
            let next = (blocks + Self.fanout - 1) / Self.fanout
            var out = [Float](repeating: 0, count: next * channels * 2)
            for b in 0..<next {
                for ch in 0..<channels {
                    var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
                    for k in (b * Self.fanout)..<min(blocks, (b + 1) * Self.fanout) {
                        lo = min(lo, last[(k * channels + ch) * 2])
                        hi = max(hi, last[(k * channels + ch) * 2 + 1])
                    }
                    out[(b * channels + ch) * 2] = lo
                    out[(b * channels + ch) * 2 + 1] = hi
                }
            }
            levels.append(out)
        }
        self.levels = levels
    }

    public func blockSize(level: Int) -> Int64 {
        var s = Int64(Self.baseBlock)
        for _ in 0..<level { s *= Int64(Self.fanout) }
        return s
    }

    /// Min and max of `channel` over source frames `range`, exact to the 256-frame
    /// blocks it touches: coarse levels cover the middle, fine levels the edges.
    public func minMax(channel: Int, _ range: Range<Int64>) -> (Float, Float)? {
        let lo = max(0, range.lowerBound), hi = min(frames, range.upperBound)
        guard lo < hi, channel < channels else { return nil }
        let base = Int64(Self.baseBlock)
        var b = Int(lo / base)
        let last = Int((hi - 1) / base)
        var mn = Float.greatestFiniteMagnitude, mx = -Float.greatestFiniteMagnitude
        while b <= last {
            // The coarsest level whose block starts at b and ends inside the range.
            var level = 0
            var span = 1
            while level + 1 < levels.count, b % (span * Self.fanout) == 0, b + span * Self.fanout - 1 <= last {
                level += 1
                span *= Self.fanout
            }
            let i = (b / span * channels + channel) * 2
            let data = levels[level]
            if i + 1 < data.count {
                mn = min(mn, data[i])
                mx = max(mx, data[i + 1])
            }
            b += span
        }
        return mn <= mx ? (mn, mx) : nil
    }

    // MARK: Building

    /// Scans the source. `progress` gets 0…1; return false from it to cancel.
    public static func build(reading read: (Int64, Int) -> [Float], channels: Int, frames: Int64,
                             progress: (Double) -> Bool = { _ in true }) -> PeakIndex? {
        let chunkBlocks = 1_024
        let chunk = chunkBlocks * baseBlock
        let blocks = Int((frames + Int64(baseBlock) - 1) / Int64(baseBlock))
        var level0 = [Float](repeating: 0, count: max(1, blocks) * channels * 2)
        var at: Int64 = 0
        var block = 0
        while at < frames {
            let samples = read(at, chunk)
            let got = samples.count / channels
            if got == 0 { break }
            samples.withUnsafeBufferPointer { s in
                var f = 0
                while f < got {
                    let n = min(baseBlock, got - f)
                    for ch in 0..<channels {
                        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
                        var i = (f * channels) + ch
                        for _ in 0..<n {
                            let v = s[i]
                            if v < lo { lo = v }
                            if v > hi { hi = v }
                            i += channels
                        }
                        level0[(block * channels + ch) * 2] = lo
                        level0[(block * channels + ch) * 2 + 1] = hi
                    }
                    block += 1
                    f += n
                }
            }
            at += Int64(got)
            if !progress(Double(at) / Double(max(1, frames))) { return nil }
        }
        return PeakIndex(channels: channels, frames: frames, level0: level0)
    }

    // MARK: Cache

    private static let magic: UInt32 = 0x4A4D_504B // "JMPK"

    /// A stable cache name for a file's samples (path, size and modification date).
    public static func cacheKey(for url: URL, info: AudioFileInfo) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let date = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let text = "\(url.path)|\(size)|\(date)|\(info.dataOffset)|\(info.frames)|\(info.channels)|\(info.sampleFormat.rawValue)"
        return SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public func write(to url: URL) throws {
        var d = Data()
        d.u32le(Self.magic); d.u32le(1); d.u32le(UInt32(channels)); d.u64le(UInt64(frames))
        d.u64le(UInt64(levels[0].count))
        levels[0].withUnsafeBytes { d.append(contentsOf: $0) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try d.write(to: url, options: .atomic)
    }

    public static func read(from url: URL) -> PeakIndex? {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe), d.count >= 28 else { return nil }
        func u32(_ o: Int) -> UInt32 { d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
        func u64(_ o: Int) -> UInt64 { d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self) } }
        guard u32(0) == magic, u32(4) == 1 else { return nil }
        let channels = Int(u32(8)), frames = Int64(u64(12)), count = Int(u64(20))
        guard channels > 0, d.count == 28 + count * 4 else { return nil }
        let level0 = d.withUnsafeBytes { raw in
            Array(UnsafeBufferPointer(start: raw.baseAddress!.advanced(by: 28).assumingMemoryBound(to: Float.self), count: count))
        }
        return PeakIndex(channels: channels, frames: frames, level0: level0)
    }
}
