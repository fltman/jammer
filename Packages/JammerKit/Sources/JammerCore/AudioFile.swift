import Foundation
import JammerEngine

/// What Jammer knows about a PCM file after reading its chunks: where the
/// samples are, how they're encoded, and the metadata around them. Unknown
/// chunks are listed so a writer can carry them over untouched.
public struct AudioFileInfo: Sendable, Equatable, Codable {
    public enum Container: String, Sendable, Codable { case wav, rf64, bw64, aiff, aifc }

    /// What a file may claim and still be opened. A header is untrusted input: one that says
    /// 65 535 channels or a sample rate of four billion is refused, not believed.
    public static let maxChannels = 32
    public static let sampleRates: ClosedRange<Double> = 8_000...768_000

    /// Nil when the format is one Jämmer can work with; else why not, in words.
    public static func refusal(channels: Int, sampleRate: Double) -> Said? {
        guard channels >= 1 else { return Said("error.file.noChannels", "The file says it has no channels.") }
        guard channels <= maxChannels else { return Said("error.file.tooManyChannels", "The file says it has %1$@ channels; Jämmer takes up to %2$@.", "\(channels)", "\(maxChannels)") }
        guard sampleRate.isFinite, sampleRates.contains(sampleRate) else {
            // Formatted as text: a rate like 1e300 doesn't fit in any integer.
            let low = "\(Int(sampleRates.lowerBound))", high = "\(Int(sampleRates.upperBound))"
            return sampleRate.isFinite
                ? Said("error.file.badRate", "The file says its sample rate is %1$@ Hz; Jämmer takes %2$@ to %3$@ Hz.", values: [Said.n(sampleRate, 0), "\(low)", "\(high)"])
                : Said("error.file.rateNaN", "The file says its sample rate is not a number; Jämmer takes %1$@ to %2$@ Hz.", low, high)
        }
        return nil
    }

    public enum SampleFormat: String, Sendable, Codable {
        case uint8, int8, int16, int24, int32, float32, float64

        public var bitsPerSample: Int {
            switch self {
            case .uint8, .int8: 8
            case .int16: 16
            case .int24: 24
            case .int32, .float32: 32
            case .float64: 64
            }
        }

        public var isFloat: Bool { self == .float32 || self == .float64 }

        var engineFormat: jm_sample_format {
            switch self {
            case .uint8: JM_PCM_U8
            case .int8: JM_PCM_I8
            case .int16: JM_PCM_I16
            case .int24: JM_PCM_I24
            case .int32: JM_PCM_I32
            case .float32: JM_PCM_F32
            case .float64: JM_PCM_F64
            }
        }
    }

    /// A chunk as it sits in the file: id, where its payload starts and how long it is.
    public struct Chunk: Sendable, Equatable, Codable {
        public var id: String
        public var offset: Int64
        public var size: Int64
    }

    public var container: Container
    public var sampleFormat: SampleFormat
    public var bigEndian: Bool
    public var channels: Int
    public var sampleRate: Double
    /// WAVE_FORMAT_EXTENSIBLE channel mask, when the file has one.
    public var channelMask: UInt32?
    public var dataOffset: Int64
    public var frames: Int64
    public var chunks: [Chunk]
    public var bext: BroadcastExtension?
    public var ixml: String?
    public var markers: [FileMarker]
    /// The loudspeaker of each channel as an ADM BWF file's `chna` names it (5.1, 7.1, 7.1.4), when it does:
    /// it decides over the mask and the channel count (a file without a mask in BS.2051's order).
    public var channelOrder: [Speaker]?
    /// Set when the header says the file holds more sound than it does (it was cut off):
    /// the number of frames it claims. `frames` is what is really there.
    public var claimedFrames: Int64?

    public init(container: Container, sampleFormat: SampleFormat, bigEndian: Bool, channels: Int, sampleRate: Double,
                channelMask: UInt32? = nil, dataOffset: Int64, frames: Int64, chunks: [Chunk] = [],
                bext: BroadcastExtension? = nil, ixml: String? = nil, markers: [FileMarker] = []) {
        self.container = container
        self.sampleFormat = sampleFormat
        self.bigEndian = bigEndian
        self.channels = channels
        self.sampleRate = sampleRate
        self.channelMask = channelMask
        self.dataOffset = dataOffset
        self.frames = frames
        self.chunks = chunks
        self.bext = bext
        self.ixml = ixml
        self.markers = markers
    }

    public var bytesPerFrame: Int { sampleFormat.bitsPerSample / 8 * channels }
    public var duration: Double { sampleRate > 0 ? Double(frames) / sampleRate : 0 }

    /// Chunks Jammer doesn't interpret itself; a writer copies them as they are.
    public var foreignChunks: [Chunk] {
        let known: Set<String> = ["fmt ", "data", "ds64", "bext", "iXML", "cue ", "LIST", "JUNK", "junk", "FLLR", "PAD ",
                                  "COMM", "SSND", "MARK", "FVER"]
        return chunks.filter { !known.contains($0.id) }
    }
}

/// A cue point or region stored in the file (WAV cue/adtl or AIFF MARK).
public struct FileMarker: Sendable, Equatable, Codable {
    public var position: Int64
    public var length: Int64
    public var name: String

    public init(position: Int64, length: Int64 = 0, name: String) {
        self.position = position
        self.length = length
        self.name = name
    }
}

/// The EBU Broadcast Wave `bext` chunk (EBU Tech 3285, version 2).
public struct BroadcastExtension: Sendable, Equatable, Codable {
    public var description = ""
    public var originator = ""
    public var originatorReference = ""
    /// yyyy-mm-dd
    public var originationDate = ""
    /// hh:mm:ss
    public var originationTime = ""
    /// Samples since midnight of the first sample (the file's timecode).
    public var timeReference: UInt64 = 0
    public var version: UInt16 = 2
    public var umid = Data(count: 64)
    /// Loudness fields (version 2), in LUFS / LU / dBTP. nil when unset (0x7FFF).
    public var loudnessValue: Double?
    public var loudnessRange: Double?
    public var maxTruePeakLevel: Double?
    public var maxMomentaryLoudness: Double?
    public var maxShortTermLoudness: Double?
    public var codingHistory = ""

    public init() {}
}

public enum AudioFileError: Error, LocalizedError, Equatable, KeyedFailure {
    case unreadable(Said)
    case notPCM(Said)
    case unsupported(Said)

    public var errorDescription: String? { said.text }
    public var keyed: KeyedMessage? { said.keyed }
    var said: Said {
        switch self {
        case .unreadable(let m), .notPCM(let m), .unsupported(let m): m
        }
    }
}

// MARK: Reading

public enum AudioFileReader {
    /// Reads the chunk structure of a WAV, RF64, BW64, AIFF or AIFF-C file.
    /// Throws `notPCM` for files Jammer has to decode first (MP3, AAC, FLAC, CAF…).
    public static func info(at url: URL) throws -> AudioFileInfo {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw AudioFileError.unreadable(Said("error.file.can_t_open", "Can't open %@.", "\(url.lastPathComponent)"))
        }
        defer { try? handle.close() }
        let fileSize = Int64((try? handle.seekToEnd()) ?? 0)
        var reader = ByteReader(handle: handle, size: fileSize)
        let magic = try reader.fourCC(at: 0)
        switch magic {
        case "RIFF", "RF64", "BW64": return try parseWAV(&reader, magic: magic)
        case "FORM": return try parseAIFF(&reader)
        default: throw AudioFileError.notPCM(Said("error.file.isn_t_wav_aiff", "%@ isn't a WAV or AIFF file.", "\(url.lastPathComponent)"))
        }
    }

    /// Opens the samples for the engine.
    public static func openSource(_ info: AudioFileInfo, at url: URL) -> OpaquePointer? {
        jm_source_open(url.path, info.dataOffset, info.frames, Int32(info.channels), info.sampleFormat.engineFormat, info.bigEndian)
    }

    private static func parseWAV(_ r: inout ByteReader, magic: String) throws -> AudioFileInfo {
        guard try r.fourCC(at: 8) == "WAVE" else { throw AudioFileError.notPCM(Said("error.file.riff_file_without_wave", "RIFF file without WAVE.")) }
        let is64 = magic != "RIFF"
        var ds64Data: Int64?
        var ds64Table: [String: Int64] = [:]
        var chunks: [AudioFileInfo.Chunk] = []
        var claimedData: Int64?
        var pos: Int64 = 12
        while pos + 8 <= r.size {
            let id = try r.fourCC(at: pos)
            var size = Int64(try r.u32le(at: pos + 4))
            let payload = pos + 8
            if is64, id == "ds64" {
                // 64-bit sizes are whatever the file says: clamped, never trusted to fit.
                ds64Data = Int64(clamping: try r.u64le(at: payload + 8))
                let tableCount = Int(try r.u32le(at: payload + 24))
                for i in 0..<min(tableCount, 64) {
                    let e = payload + 28 + Int64(i) * 12
                    guard e + 12 <= payload + size, e + 12 <= r.size else { break }
                    ds64Table[try r.fourCC(at: e)] = Int64(clamping: try r.u64le(at: e + 4))
                }
            }
            if is64, size == 0xFFFF_FFFF {
                size = id == "data" ? (ds64Data ?? (r.size - payload)) : (ds64Table[id] ?? 0)
            }
            // No chunk is larger than what is left of the file, whatever its header says. For the
            // audio that also covers a recording that was cut off: what is there is used.
            // (0xFFFFFFFF is what recorders write when they don't know the length yet: not a claim.)
            if id == "data", size != 0xFFFF_FFFF, size > r.size - payload { claimedData = size }
            size = max(0, min(size, r.size - payload))
            chunks.append(.init(id: id, offset: payload, size: size))
            // A file made of nothing but headers doesn't get to keep us here.
            guard chunks.count <= 100_000 else { throw AudioFileError.unreadable(Said("error.file.file_has_too_many", "The file has too many chunks to be a recording.")) }
            pos = payload + size + (size & 1)
        }
        guard let fmt = chunks.first(where: { $0.id == "fmt " }), fmt.size >= 16 else {
            throw AudioFileError.unreadable(Said("error.file.file_cut_off_damaged", "The file is cut off or damaged: the part that says what kind of audio it holds is missing."))
        }
        guard let data = chunks.first(where: { $0.id == "data" }) else {
            throw AudioFileError.unreadable(Said("error.file.file_cut_off_damaged2", "The file is cut off or damaged: it has no audio in it."))
        }
        var tag = try r.u16le(at: fmt.offset)
        let channels = Int(try r.u16le(at: fmt.offset + 2))
        let rate = Double(try r.u32le(at: fmt.offset + 4))
        let bits = Int(try r.u16le(at: fmt.offset + 14))
        var mask: UInt32?
        if tag == 0xFFFE, fmt.size >= 40 {
            mask = try r.u32le(at: fmt.offset + 20)
            tag = try r.u16le(at: fmt.offset + 24) // first bytes of the SubFormat GUID
        }
        let sampleFormat: AudioFileInfo.SampleFormat
        switch (tag, bits) {
        case (1, 8): sampleFormat = .uint8
        case (1, 16): sampleFormat = .int16
        case (1, 24): sampleFormat = .int24
        case (1, 32): sampleFormat = .int32
        case (3, 32): sampleFormat = .float32
        case (3, 64): sampleFormat = .float64
        default: throw AudioFileError.notPCM(Said("error.file.wav_format_1_2", "WAV format %1$@ with %2$@ bits isn't plain PCM.", "\(tag)", "\(bits)"))
        }
        if let no = AudioFileInfo.refusal(channels: channels, sampleRate: rate) { throw AudioFileError.unreadable(no) }
        let frameBytes = Int64(bits / 8 * channels)
        var info = AudioFileInfo(container: magic == "RIFF" ? .wav : (magic == "RF64" ? .rf64 : .bw64),
                                 sampleFormat: sampleFormat, bigEndian: false, channels: channels, sampleRate: rate,
                                 channelMask: mask, dataOffset: data.offset, frames: data.size / frameBytes,
                                 chunks: chunks, bext: nil, ixml: nil, markers: [])
        if let claimedData, claimedData / frameBytes > info.frames { info.claimedFrames = claimedData / frameBytes }
        if let c = chunks.first(where: { $0.id == "chna" }), c.size >= 4, c.size < 1 << 20 {
            info.channelOrder = ADM.speakers(chna: try r.bytes(at: c.offset, count: Int(c.size)), channels: channels)
        }
        if let b = chunks.first(where: { $0.id == "bext" }), b.size >= 602 {
            info.bext = try parseBext(&r, b)
        }
        if let x = chunks.first(where: { $0.id == "iXML" }), x.size > 0, x.size < 16 << 20 {
            info.ixml = String(decoding: try r.bytes(at: x.offset, count: Int(x.size)), as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        }
        info.markers = try parseCues(&r, chunks)
        return info
    }

    private static func parseBext(_ r: inout ByteReader, _ c: AudioFileInfo.Chunk) throws -> BroadcastExtension {
        let o = c.offset
        func text(_ off: Int64, _ n: Int) throws -> String {
            let raw = try r.bytes(at: o + off, count: n)
            let end = raw.firstIndex(of: 0) ?? raw.endIndex
            return String(decoding: raw[raw.startIndex..<end], as: UTF8.self)
        }
        var b = BroadcastExtension()
        b.description = try text(0, 256)
        b.originator = try text(256, 32)
        b.originatorReference = try text(288, 32)
        b.originationDate = try text(320, 10)
        b.originationTime = try text(330, 8)
        b.timeReference = UInt64(try r.u32le(at: o + 338)) | (UInt64(try r.u32le(at: o + 342)) << 32)
        b.version = try r.u16le(at: o + 346)
        b.umid = try r.bytes(at: o + 348, count: 64)
        if b.version >= 2 {
            func loud(_ off: Int64) throws -> Double? {
                let v = Int16(bitPattern: try r.u16le(at: o + off))
                return v == 0x7FFF ? nil : Double(v) / 100
            }
            b.loudnessValue = try loud(412)
            b.loudnessRange = try loud(414)
            b.maxTruePeakLevel = try loud(416)
            b.maxMomentaryLoudness = try loud(418)
            b.maxShortTermLoudness = try loud(420)
        }
        if c.size > 602 { b.codingHistory = try text(602, Int(c.size - 602)) }
        return b
    }

    private static func parseCues(_ r: inout ByteReader, _ chunks: [AudioFileInfo.Chunk]) throws -> [FileMarker] {
        guard let cue = chunks.first(where: { $0.id == "cue " }), cue.size >= 4 else { return [] }
        let count = Int(try r.u32le(at: cue.offset))
        var points: [(id: UInt32, position: Int64)] = []
        for i in 0..<min(count, Int((cue.size - 4) / 24)) {
            let p = cue.offset + 4 + Int64(i) * 24
            points.append((try r.u32le(at: p), Int64(try r.u32le(at: p + 20))))
        }
        var labels: [UInt32: String] = [:]
        var lengths: [UInt32: Int64] = [:]
        for list in chunks where list.id == "LIST" && list.size >= 4 {
            guard try r.fourCC(at: list.offset) == "adtl" else { continue }
            var p = list.offset + 4
            let end = list.offset + list.size
            while p + 8 <= end {
                let id = try r.fourCC(at: p)
                let size = Int64(try r.u32le(at: p + 4))
                let body = p + 8
                if (id == "labl" || id == "note"), size >= 4 {
                    let cueID = try r.u32le(at: body)
                    let raw = try r.bytes(at: body + 4, count: Int(size - 4))
                    let s = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                    if id == "labl" || labels[cueID] == nil { labels[cueID] = s }
                } else if id == "ltxt", size >= 8 {
                    lengths[try r.u32le(at: body)] = Int64(try r.u32le(at: body + 4))
                }
                p = body + size + (size & 1)
            }
        }
        return points.map { FileMarker(position: $0.position, length: lengths[$0.id] ?? 0, name: labels[$0.id] ?? "Marker \($0.id)") }
            .sorted { $0.position < $1.position }
    }

    private static func parseAIFF(_ r: inout ByteReader) throws -> AudioFileInfo {
        let kind = try r.fourCC(at: 8)
        guard kind == "AIFF" || kind == "AIFC" else { throw AudioFileError.notPCM(Said("error.file.form_file_isn_t", "FORM file that isn't AIFF.")) }
        var chunks: [AudioFileInfo.Chunk] = []
        var pos: Int64 = 12
        while pos + 8 <= r.size {
            let id = try r.fourCC(at: pos)
            let size = Int64(try r.u32be(at: pos + 4))
            chunks.append(.init(id: id, offset: pos + 8, size: min(size, r.size - pos - 8)))
            guard chunks.count <= 100_000 else { throw AudioFileError.unreadable(Said("error.file.file_has_too_many", "The file has too many chunks to be a recording.")) }
            pos += 8 + size + (size & 1)
        }
        guard let comm = chunks.first(where: { $0.id == "COMM" }), comm.size >= 18 else {
            throw AudioFileError.unreadable(Said("error.file.file_cut_off_damaged", "The file is cut off or damaged: the part that says what kind of audio it holds is missing."))
        }
        guard let ssnd = chunks.first(where: { $0.id == "SSND" }), ssnd.size >= 8 else {
            throw AudioFileError.unreadable(Said("error.file.file_cut_off_damaged2", "The file is cut off or damaged: it has no audio in it."))
        }
        let channels = Int(try r.u16be(at: comm.offset))
        let frames = Int64(try r.u32be(at: comm.offset + 2))
        let bits = Int(try r.u16be(at: comm.offset + 6))
        let rate = extended80(try r.bytes(at: comm.offset + 8, count: 10))
        var compression = "NONE"
        if kind == "AIFC", comm.size >= 22 { compression = try r.fourCC(at: comm.offset + 18) }
        let format: AudioFileInfo.SampleFormat
        var bigEndian = true
        switch (compression, bits) {
        case ("NONE", 8), ("twos", 8): format = .int8
        case ("NONE", 16), ("twos", 16): format = .int16
        case ("NONE", 24), ("in24", 24): format = .int24
        case ("NONE", 32), ("in32", 32): format = .int32
        case ("sowt", 16): format = .int16; bigEndian = false
        case ("sowt", 24): format = .int24; bigEndian = false
        case ("sowt", 32): format = .int32; bigEndian = false
        case ("fl32", _), ("FL32", _): format = .float32
        case ("fl64", _), ("FL64", _): format = .float64
        default: throw AudioFileError.notPCM(Said("error.file.aiff_c_compression_isn", "AIFF-C compression %@ isn't plain PCM.", "\(compression)"))
        }
        if let no = AudioFileInfo.refusal(channels: channels, sampleRate: rate) { throw AudioFileError.unreadable(no) }
        let ssndOffset = Int64(try r.u32be(at: ssnd.offset))
        // An offset that points past the sound leaves nothing to play, not a position outside the file.
        let dataOffset = min(ssnd.offset + 8 + ssndOffset, ssnd.offset + ssnd.size)
        let frameBytes = Int64(format.bitsPerSample / 8 * channels)
        let available = max(0, (ssnd.offset + ssnd.size - dataOffset) / frameBytes)
        var info = AudioFileInfo(container: kind == "AIFF" ? .aiff : .aifc, sampleFormat: format, bigEndian: bigEndian,
                                 channels: channels, sampleRate: rate, channelMask: nil, dataOffset: dataOffset,
                                 frames: min(frames, available), chunks: chunks, bext: nil, ixml: nil, markers: [])
        if frames > available { info.claimedFrames = frames }
        if let mark = chunks.first(where: { $0.id == "MARK" }), mark.size >= 2 {
            let count = Int(try r.u16be(at: mark.offset))
            var p = mark.offset + 2
            for _ in 0..<count where p + 7 <= mark.offset + mark.size {
                let position = Int64(try r.u32be(at: p + 2))
                let len = Int(try r.bytes(at: p + 6, count: 1)[0])
                let name = String(decoding: try r.bytes(at: p + 7, count: len), as: UTF8.self)
                info.markers.append(FileMarker(position: position, name: name))
                p += 7 + Int64(len) + Int64((len + 1) & 1) // pstring padded to even total
            }
        }
        return info
    }

    /// IEEE 754 80-bit extended (AIFF sample rate) to Double.
    static func extended80(_ b: Data) -> Double {
        let bytes = [UInt8](b)
        guard bytes.count == 10 else { return 0 }
        let sign = (bytes[0] & 0x80) != 0
        let exponent = (Int(bytes[0] & 0x7F) << 8) | Int(bytes[1])
        var mantissa: UInt64 = 0
        for i in 2..<10 { mantissa = (mantissa << 8) | UInt64(bytes[i]) }
        if exponent == 0 && mantissa == 0 { return 0 }
        // The format's infinity and not-a-number: no sample rate.
        if exponent == 0x7FFF { return .nan }
        let value = Double(mantissa) * pow(2.0, Double(exponent - 16383 - 63))
        return sign ? -value : value
    }
}

// MARK: Byte access

struct ByteReader {
    let handle: FileHandle
    let size: Int64

    func bytes(at offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset + Int64(count) <= size else {
            throw AudioFileError.unreadable(Said("error.file.file_ends_early_offset", "The file ends early (offset %@).", "\(offset)"))
        }
        try handle.seek(toOffset: UInt64(offset))
        let d = try handle.read(upToCount: count) ?? Data()
        guard d.count == count else { throw AudioFileError.unreadable(Said("error.file.file_ends_early", "The file ends early.")) }
        return d
    }

    func fourCC(at o: Int64) throws -> String { String(decoding: try bytes(at: o, count: 4), as: UTF8.self) }
    func u16le(at o: Int64) throws -> UInt16 { let d = [UInt8](try bytes(at: o, count: 2)); return UInt16(d[0]) | UInt16(d[1]) << 8 }
    func u32le(at o: Int64) throws -> UInt32 {
        let d = [UInt8](try bytes(at: o, count: 4))
        return UInt32(d[0]) | UInt32(d[1]) << 8 | UInt32(d[2]) << 16 | UInt32(d[3]) << 24
    }
    func u64le(at o: Int64) throws -> UInt64 { UInt64(try u32le(at: o)) | UInt64(try u32le(at: o + 4)) << 32 }
    func u16be(at o: Int64) throws -> UInt16 { let d = [UInt8](try bytes(at: o, count: 2)); return UInt16(d[0]) << 8 | UInt16(d[1]) }
    func u32be(at o: Int64) throws -> UInt32 {
        let d = [UInt8](try bytes(at: o, count: 4))
        return UInt32(d[0]) << 24 | UInt32(d[1]) << 16 | UInt32(d[2]) << 8 | UInt32(d[3])
    }
}
