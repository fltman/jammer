import Foundation

/// Writes a WAV file as it streams in, switching to RF64 (EBU Tech 3306) by
/// itself when the result outgrows 4 GB. Keeps Broadcast Wave metadata, iXML,
/// markers and any foreign chunks it is handed, which Apple's converters drop.
public final class WAVWriter {
    public enum Encoding: String, Sendable, Codable, CaseIterable {
        case int16, int24, float32

        var bytes: Int { self == .int16 ? 2 : (self == .int24 ? 3 : 4) }
        var formatTag: UInt16 { self == .float32 ? 3 : 1 }
    }

    public struct Options: Sendable {
        public var encoding: Encoding
        public var channels: Int
        public var sampleRate: Double
        public var channelMask: UInt32?
        public var bext: BroadcastExtension?
        public var ixml: String?
        public var markers: [FileMarker]
        /// Chunks to carry over byte for byte (id, payload).
        public var foreignChunks: [(id: String, payload: Data)]
        /// TPDF dither when writing integers, on the samples that rounding would change. Off by default.
        public var dither: Bool
        /// Write RF64 even when the file would fit in a plain WAV.
        public var alwaysRF64 = false

        public init(encoding: Encoding, channels: Int, sampleRate: Double, channelMask: UInt32? = nil,
                    bext: BroadcastExtension? = nil, ixml: String? = nil, markers: [FileMarker] = [],
                    foreignChunks: [(id: String, payload: Data)] = [], dither: Bool = false) {
            self.encoding = encoding
            self.channels = channels
            self.sampleRate = sampleRate
            self.channelMask = channelMask
            self.bext = bext
            self.ixml = ixml
            self.markers = markers
            self.foreignChunks = foreignChunks
            self.dither = dither
        }
    }

    public let url: URL
    public let options: Options
    private let handle: FileHandle
    private var dataStart: Int64 = 0
    private var dataBytes: Int64 = 0
    private var junkOffset: Int64 = 0
    private var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
    private var buffer: [UInt8] = []
    private var finished = false

    public init(url: URL, options: Options) throws {
        guard options.channels > 0, options.sampleRate > 0 else { throw AudioFileError.unsupported(Said("error.export.invalid_channel_count_sample", "Invalid channel count or sample rate.")) }
        self.url = url
        self.options = options
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else {
            throw AudioFileError.unreadable(Said("error.file.can_t_write", "Can't write to %@.", "\(url.lastPathComponent)"))
        }
        handle = h
        var head = Data()
        head.fourCC("RIFF"); head.u32le(0); head.fourCC("WAVE")
        // Room for a ds64 chunk, in case the file grows past 4 GB.
        junkOffset = Int64(head.count)
        head.fourCC("JUNK"); head.u32le(28); head.append(Data(count: 28))
        head.append(Self.fmtChunk(options))
        if let bext = options.bext { head.append(Self.chunk("bext", Self.bextPayload(bext))) }
        if let ixml = options.ixml { head.append(Self.chunk("iXML", Data(ixml.utf8))) }
        for c in options.foreignChunks { head.append(Self.chunk(c.id, c.payload)) }
        head.fourCC("data"); head.u32le(0)
        try handle.write(contentsOf: head)
        dataStart = Int64(head.count)
    }

    deinit { try? handle.close() }

    /// Appends interleaved float frames.
    public func write(_ samples: UnsafeBufferPointer<Float>) throws {
        precondition(!finished)
        let enc = options.encoding
        buffer.removeAll(keepingCapacity: true)
        buffer.reserveCapacity(samples.count * enc.bytes)
        for x in samples {
            switch enc {
            case .float32:
                let u = x.bitPattern
                buffer.append(UInt8(u & 0xFF)); buffer.append(UInt8((u >> 8) & 0xFF))
                buffer.append(UInt8((u >> 16) & 0xFF)); buffer.append(UInt8(u >> 24))
            case .int16:
                let v = quantize(x, scale: 32_768)
                buffer.append(UInt8(truncatingIfNeeded: v)); buffer.append(UInt8(truncatingIfNeeded: v >> 8))
            case .int24:
                let v = quantize(x, scale: 8_388_608)
                buffer.append(UInt8(truncatingIfNeeded: v)); buffer.append(UInt8(truncatingIfNeeded: v >> 8))
                buffer.append(UInt8(truncatingIfNeeded: v >> 16))
            }
        }
        try handle.write(contentsOf: buffer)
        dataBytes += Int64(buffer.count)
    }

    public func write(_ samples: [Float]) throws {
        try samples.withUnsafeBufferPointer { try write($0) }
    }

    private func quantize(_ x: Float, scale: Double) -> Int32 {
        var v = Double(x) * scale
        // Dither is for what rounding would otherwise distort. A sample that already sits on a step of the
        // target depth is written as it is: audio that is already 16 bits is not dithered a second time,
        // and digital silence stays silence. (In processed audio about one sample in 256 happens to sit on
        // a 16-bit step; leaving those out changes the noise by a hundredth of a dB.)
        if options.dither, v != v.rounded() {
            // Triangular dither of ±1 LSB from two uniform values.
            v += nextUniform() - nextUniform()
            ditheredSamples += 1
        }
        return Int32(max(-scale, min(scale - 1, v.rounded())))
    }

    /// How many samples got dither so far. 0 with dither on means there was nothing to dither.
    public private(set) var ditheredSamples: Int64 = 0

    private func nextUniform() -> Double {
        rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(rng >> 11) / Double(1 << 53)
    }

    /// Writes the trailing chunks and the sizes. Call once.
    public func finish() throws {
        guard !finished else { return }
        finished = true
        if dataBytes & 1 == 1 { try handle.write(contentsOf: Data([0])) }
        var tail = Data()
        if !options.markers.isEmpty { tail.append(Self.cueChunks(options.markers)) }
        try handle.write(contentsOf: tail)
        let total = Int64(try handle.offset())
        let riffSize = total - 8
        if options.alwaysRF64 || riffSize > 0xFFFF_FFFF || dataBytes > 0xFFFF_FFFF {
            // RF64: sizes move to ds64, the 32-bit fields become -1.
            var ds64 = Data()
            ds64.u64le(UInt64(riffSize)); ds64.u64le(UInt64(dataBytes))
            ds64.u64le(UInt64(dataBytes / Int64(options.encoding.bytes * options.channels))); ds64.u32le(0)
            try patch(0, Data("RF64".utf8) + Data(le32: 0xFFFF_FFFF))
            try patch(junkOffset, Data("ds64".utf8) + Data(le32: 28) + ds64)
            try patch(dataStart - 4, Data(le32: 0xFFFF_FFFF))
        } else {
            try patch(4, Data(le32: UInt32(riffSize)))
            try patch(dataStart - 4, Data(le32: UInt32(dataBytes)))
        }
        try handle.close()
    }

    private func patch(_ offset: Int64, _ bytes: Data) throws {
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: bytes)
        try handle.seekToEnd()
    }

    // MARK: Chunks

    /// A LIST chunk's payload of type INFO with one comment (ICMT), NUL-terminated and padded to even length.
    public static func infoList(comment: String) -> Data {
        var text = Data(comment.utf8)
        text.append(0)
        var d = Data("INFO".utf8)
        d.append(Data("ICMT".utf8))
        d.u32le(UInt32(text.count))
        d.append(text)
        if text.count % 2 == 1 { d.append(0) }
        return d
    }

    static func chunk(_ id: String, _ payload: Data) -> Data {
        var d = Data()
        d.fourCC(id); d.u32le(UInt32(payload.count)); d.append(payload)
        if payload.count & 1 == 1 { d.append(0) }
        return d
    }

    static func fmtChunk(_ o: Options) -> Data {
        let bits = o.encoding.bytes * 8
        let blockAlign = o.encoding.bytes * o.channels
        let extensible = o.channels > 2 || o.channelMask != nil
        var p = Data()
        p.u16le(extensible ? 0xFFFE : o.encoding.formatTag)
        p.u16le(UInt16(o.channels))
        p.u32le(UInt32(o.sampleRate))
        p.u32le(UInt32(Int(o.sampleRate) * blockAlign))
        p.u16le(UInt16(blockAlign))
        p.u16le(UInt16(bits))
        if extensible {
            p.u16le(22)
            p.u16le(UInt16(bits))
            p.u32le(o.channelMask ?? defaultMask(o.channels))
            // KSDATAFORMAT_SUBTYPE_PCM / _IEEE_FLOAT: tag + fixed GUID tail.
            p.u16le(o.encoding.formatTag)
            p.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
        }
        return chunk("fmt ", p)
    }

    static func defaultMask(_ channels: Int) -> UInt32 {
        switch channels {
        case 1: 0x4
        case 2: 0x3
        case 6: 0x3F // 5.1
        case 8: 0x63F // 7.1
        case 12: 0x2D63F // 7.1.4: 7.1 and the four top corners
        default: channels >= 32 ? 0xFFFF_FFFF : (UInt32(1) << UInt32(channels)) - 1
        }
    }

    static func bextPayload(_ b: BroadcastExtension) -> Data {
        var p = Data()
        func text(_ s: String, _ n: Int) {
            var bytes = Array(s.utf8.prefix(n))
            bytes += Array(repeating: 0, count: n - bytes.count)
            p.append(contentsOf: bytes)
        }
        text(b.description, 256)
        text(b.originator, 32)
        text(b.originatorReference, 32)
        text(b.originationDate, 10)
        text(b.originationTime, 8)
        p.u32le(UInt32(b.timeReference & 0xFFFF_FFFF))
        p.u32le(UInt32(b.timeReference >> 32))
        p.u16le(2)
        var umid = b.umid.prefix(64)
        if umid.count < 64 { umid.append(Data(count: 64 - umid.count)) }
        p.append(umid)
        func loud(_ v: Double?) { p.u16le(UInt16(bitPattern: v.map { Int16(max(-32_767, min(32_766, ($0 * 100).rounded()))) } ?? 0x7FFF)) }
        loud(b.loudnessValue)
        loud(b.loudnessRange)
        loud(b.maxTruePeakLevel)
        loud(b.maxMomentaryLoudness)
        loud(b.maxShortTermLoudness)
        p.append(Data(count: 180))
        p.append(Data(b.codingHistory.utf8))
        return p
    }

    static func cueChunks(_ markers: [FileMarker]) -> Data {
        var cue = Data()
        cue.u32le(UInt32(markers.count))
        var adtl = Data("adtl".utf8)
        for (i, m) in markers.enumerated() {
            let id = UInt32(i + 1)
            let pos = UInt32(clamping: m.position)
            cue.u32le(id); cue.u32le(pos); cue.fourCC("data"); cue.u32le(0); cue.u32le(0); cue.u32le(pos)
            var label = Data(); label.u32le(id); label.append(Data(m.name.utf8)); label.append(0)
            adtl.append(chunk("labl", label))
            if m.length > 0 {
                var ltxt = Data(); ltxt.u32le(id); ltxt.u32le(UInt32(clamping: m.length)); ltxt.fourCC("rgn ")
                ltxt.u16le(0); ltxt.u16le(0); ltxt.u16le(0); ltxt.u16le(0)
                adtl.append(chunk("ltxt", ltxt))
            }
        }
        return chunk("cue ", cue) + chunk("LIST", adtl)
    }
}

extension Data {
    init(le32 v: UInt32) { self.init(); u32le(v) }
    mutating func fourCC(_ s: String) { append(contentsOf: Array(s.utf8.prefix(4)) + Array(repeating: 0x20, count: Swift.max(0, 4 - s.utf8.count))) }
    mutating func u16le(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func u32le(_ v: UInt32) { for i in 0..<4 { append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
    mutating func u64le(_ v: UInt64) { u32le(UInt32(v & 0xFFFF_FFFF)); u32le(UInt32(v >> 32)) }
}
