import AudioToolbox
import Foundation

/// Ogg Opus files (RFC 7845) from Apple's Opus encoder. Apple writes Opus only to CAF and
/// MP4, so the Ogg container (RFC 3533) is our own: OpusHead and OpusTags headers, pages
/// with lacing and CRC, and granule positions that trim the encoder's padding exactly.
public final class OggOpusWriter {
    public let channels: Int
    public let inputRate: Double
    private var converter: AudioConverterRef?
    private let handle: FileHandle
    private let serial: UInt32
    private var pageSequence: UInt32 = 0
    private var preSkip: UInt32 = 312
    private var fifo: [Float] = []
    private var fifoRead = 0
    private var finishing = false
    private var inputFrames: Int64 = 0
    /// Packets waiting for a page, and the 48 kHz samples encoded so far.
    private var pagePackets: [Data] = []
    private var granule: Int64 = 0
    private var maxPacketSize: UInt32 = 1_500

    static let needMore: OSStatus = 0x4D4F5245 // 'MORE'
    static let appleDelayCorrection: UInt32 = 3

    /// `comments`: Vorbis comments ("KEY=value") for OpusTags, e.g. chapters.
    public init(url: URL, channels: Int, sampleRate: Double, bitRate: Int = 64_000, vendor: String = "Jammer", comments: [String] = []) throws {
        guard (1...2).contains(channels) else { throw ExportError.unsupported(Said("error.export.opus_here_takes_mono", "Opus here takes mono or stereo.")) }
        self.channels = channels
        inputRate = sampleRate
        var input = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var output = AudioStreamBasicDescription()
        output.mFormatID = kAudioFormatOpus
        output.mSampleRate = 48_000
        output.mChannelsPerFrame = UInt32(channels)
        output.mFramesPerPacket = 960
        var conv: AudioConverterRef?
        var status = AudioConverterNew(&input, &output, &conv)
        guard status == noErr, let conv else { throw ExportError.encoder("start the Opus encoder", status) }
        converter = conv
        var rate = UInt32(bitRate)
        AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &rate)
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioConverterGetProperty(conv, kAudioConverterPropertyMaximumOutputPacketSize, &size, &maxPacketSize)
        var prime = AudioConverterPrimeInfo()
        size = UInt32(MemoryLayout<AudioConverterPrimeInfo>.size)
        if AudioConverterGetProperty(conv, kAudioConverterPrimeInfo, &size, &prime) == noErr, prime.leadingFrames > 0 {
            preSkip = prime.leadingFrames
        }
        // Measured against libopus (OpusDelayProbe): Apple's encoder reports 312 leading
        // frames, but its output sits 3 samples earlier than libopus's; 309 lines it up.
        preSkip = preSkip > Self.appleDelayCorrection ? preSkip - Self.appleDelayCorrection : preSkip
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { throw ExportError.unsupported(Said("error.export.can_t_write", "Can't write %@.", "\(url.lastPathComponent)")) }
        handle = h
        serial = UInt32.random(in: 1...UInt32.max)
        // OpusHead (RFC 7845 §5.1): version 1, channels, pre-skip, input rate, gain 0, mapping 0.
        var head = Data("OpusHead".utf8)
        head.append(1)
        head.append(UInt8(channels))
        head.le16(UInt16(preSkip))
        head.u32le(UInt32(sampleRate))
        head.le16(0)
        head.append(0)
        try writePage([head], granule: 0, flags: 0x02)
        // OpusTags (§5.2): vendor and comments. Large tags span pages (lacing continues).
        var tags = Data("OpusTags".utf8)
        tags.u32le(UInt32(vendor.utf8.count))
        tags.append(contentsOf: Array(vendor.utf8))
        tags.u32le(UInt32(comments.count))
        for c in comments {
            tags.u32le(UInt32(c.utf8.count))
            tags.append(contentsOf: Array(c.utf8))
        }
        try writeHeaderPacket(tags)
        status = noErr
        _ = status
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        try? handle.close()
    }

    /// Interleaved float frames at the input rate.
    public func write(_ samples: UnsafeBufferPointer<Float>) throws {
        fifo.append(contentsOf: samples)
        inputFrames += Int64(samples.count / channels)
        try drain()
    }

    public func finish() throws {
        finishing = true
        try drain()
        // The end: the last page's granule position trims the padding (RFC 7845 §4.4).
        let total = Int64(preSkip) + Int64((Double(inputFrames) * 48_000 / inputRate).rounded())
        try writePage(pagePackets, granule: min(granule, total), flags: 0x04)
        pagePackets = []
        try handle.close()
    }

    private func drain() throws {
        guard let converter else { return }
        let capacity: UInt32 = 8
        var buffer = [UInt8](repeating: 0, count: Int(maxPacketSize * capacity))
        var descriptions = [AudioStreamPacketDescription](repeating: AudioStreamPacketDescription(), count: Int(capacity))
        while true {
            var packets = capacity
            let status: OSStatus = buffer.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels),
                                                                                    mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                return descriptions.withUnsafeMutableBufferPointer { d in
                    AudioConverterFillComplexBuffer(converter, { _, ioPackets, ioData, _, user in
                        let me = Unmanaged<OggOpusWriter>.fromOpaque(user!).takeUnretainedValue()
                        return me.supply(ioPackets, ioData)
                    }, Unmanaged.passUnretained(self).toOpaque(), &packets, &list, d.baseAddress)
                }
            }
            for i in 0..<Int(packets) {
                let d = descriptions[i]
                pagePackets.append(Data(buffer[Int(d.mStartOffset)..<Int(d.mStartOffset) + Int(d.mDataByteSize)]))
                granule += 960
                // About one second per page.
                if pagePackets.count >= 50 {
                    try writePage(pagePackets, granule: granule, flags: 0)
                    pagePackets = []
                }
            }
            if status == Self.needMore || packets == 0 { break }
            guard status == noErr else { throw ExportError.encoder("encode Opus", status) }
        }
        if fifoRead > 0, fifoRead * 2 > fifo.count {
            fifo.removeFirst(fifoRead)
            fifoRead = 0
        }
    }

    /// Hands the encoder what's waiting; asks for more (or ends) when the queue is empty.
    private var lending: [Float] = []
    private func supply(_ ioPackets: UnsafeMutablePointer<UInt32>, _ ioData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let available = (fifo.count - fifoRead) / channels
        if available == 0 {
            ioPackets.pointee = 0
            ioData.pointee.mBuffers.mDataByteSize = 0
            return finishing ? noErr : Self.needMore
        }
        let n = min(Int(ioPackets.pointee), available, 4_096)
        lending = Array(fifo[fifoRead..<(fifoRead + n * channels)])
        fifoRead += n * channels
        ioPackets.pointee = UInt32(n)
        lending.withUnsafeMutableBytes { raw in
            ioData.pointee.mBuffers.mData = raw.baseAddress
            ioData.pointee.mBuffers.mDataByteSize = UInt32(raw.count)
            ioData.pointee.mBuffers.mNumberChannels = UInt32(channels)
        }
        return noErr
    }

    /// A header packet that may be longer than one page holds (255 × 255 bytes): split
    /// across pages, each later page flagged as a continuation.
    private func writeHeaderPacket(_ packet: Data) throws {
        // One page holds up to 255 lacing values: 65 024 bytes of a packet that ends on it,
        // or 65 025 of one that continues on the next page.
        var rest = packet
        var first = true
        while rest.count >= 255 * 255 {
            try writeRawPage(Data(rest.prefix(255 * 255)), complete: false, granule: -1, flags: first ? 0 : 0x01)
            rest = Data(rest.dropFirst(255 * 255))
            first = false
        }
        try writeRawPage(rest, complete: true, granule: 0, flags: first ? 0 : 0x01)
    }

    /// A page holding part of a packet: full 255 lacing values, plus a final short one
    /// when `complete`.
    private func writeRawPage(_ body: Data, complete: Bool, granule: Int64, flags: UInt8) throws {
        var segments = [UInt8](repeating: 255, count: body.count / 255)
        if complete { segments.append(UInt8(body.count % 255)) }
        precondition(segments.count <= 255)
        var page = Data("OggS".utf8)
        page.append(0)
        page.append(flags)
        page.le64(UInt64(bitPattern: granule))
        page.u32le(serial)
        page.u32le(pageSequence)
        page.u32le(0)
        page.append(UInt8(segments.count))
        page.append(contentsOf: segments)
        page.append(body)
        let crc = Self.crc(page)
        page.replaceSubrange(22..<26, with: [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8((crc >> 16) & 0xFF), UInt8(crc >> 24)])
        try handle.write(contentsOf: page)
        pageSequence += 1
    }

    /// Vorbis chapter comments (the Ogg chapter extension, as ffmpeg writes them):
    /// CHAPTER000=00:00:00.000 and CHAPTER000NAME=Intro, numbered from 000.
    public static func chapterComments(_ chapters: [Chapter]) -> [String] {
        chapters.prefix(1_000).enumerated().flatMap { i, c -> [String] in
            let ms = Int((c.start * 1_000).rounded())
            let time = String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1_000 % 60, ms % 1_000)
            let n = String(format: "%03d", i)
            return ["CHAPTER\(n)=\(time)", "CHAPTER\(n)NAME=\(c.title)"]
        }
    }

    /// One Ogg page (RFC 3533) holding whole packets.
    private func writePage(_ packets: [Data], granule: Int64, flags: UInt8) throws {
        var segments: [UInt8] = []
        var body = Data()
        for p in packets {
            var left = p.count
            while left >= 255 { segments.append(255); left -= 255 }
            segments.append(UInt8(left))
            body.append(p)
        }
        precondition(segments.count <= 255)
        var page = Data("OggS".utf8)
        page.append(0)
        page.append(flags)
        page.le64(UInt64(bitPattern: granule))
        page.u32le(serial)
        page.u32le(pageSequence)
        page.u32le(0) // CRC, filled in below
        page.append(UInt8(segments.count))
        page.append(contentsOf: segments)
        page.append(body)
        let crc = Self.crc(page)
        page.replaceSubrange(22..<26, with: [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8((crc >> 16) & 0xFF), UInt8(crc >> 24)])
        try handle.write(contentsOf: page)
        pageSequence += 1
    }

    /// Ogg's CRC-32: polynomial 0x04C11DB7, initial 0, no reflection, no final xor.
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var r = UInt32(i) << 24
        for _ in 0..<8 { r = r & 0x8000_0000 != 0 ? (r << 1) ^ 0x04C1_1DB7 : r << 1 }
        return r
    }

    static func crc(_ data: Data) -> UInt32 {
        var c: UInt32 = 0
        for b in data { c = (c << 8) ^ table[Int(((c >> 24) ^ UInt32(b)) & 0xFF)] }
        return c
    }

    /// Renders `range` of a plan into an .opus file.
    public static func export(_ plan: RenderPlan, range: Range<Frame>, to url: URL, bitRate: Int = 64_000, chapters: [Chapter] = [],
                              progress: (Double) -> Bool = { _ in true }) throws {
        let w = try OggOpusWriter(url: url, channels: plan.channels, sampleRate: plan.sampleRate, bitRate: bitRate,
                                  comments: chapterComments(chapters))
        var done: Frame = 0
        try plan.render(range) { block in
            try w.write(block)
            done += Frame(block.count / plan.channels)
            if !progress(Double(done) / Double(max(1, range.count))) { throw CancellationError() }
        }
        try w.finish()
    }
}

extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le64(_ v: UInt64) { for i in 0..<8 { append(UInt8((v >> (8 * UInt64(i))) & 0xFF)) } }
}
