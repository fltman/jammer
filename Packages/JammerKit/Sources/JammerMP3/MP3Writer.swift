import Foundation
import JammerCore
import LAME

/// MP3 through LAME 3.100 (LGPL, a separate dynamic framework). Constant bit rate,
/// high quality; the LAME/Xing tag at the start lets players trim the encoder's delay
/// and padding (gapless).
public final class MP3Writer: StreamingAudioWriter {
    private let lame: lame_t
    private let handle: FileHandle
    private let channels: Int
    private var buffer = [UInt8](repeating: 0, count: 1 << 18)
    /// Where the audio starts (after an ID3 tag); the LAME tag frame goes there.
    private var audioStart: UInt64 = 0

    public init(url: URL, channels: Int, sampleRate: Double, bitRate: Int = 128_000, id3: Data? = nil) throws {
        guard (1...2).contains(channels) else { throw ExportError.unsupported("MP3 takes mono or stereo.") }
        guard let l = lame_init() else { throw ExportError.unsupported("LAME couldn't start.") }
        lame = l
        self.channels = channels
        lame_set_num_channels(l, Int32(channels))
        lame_set_in_samplerate(l, Int32(sampleRate))
        lame_set_mode(l, channels == 1 ? MONO : JOINT_STEREO)
        lame_set_brate(l, Int32(bitRate / 1_000))
        lame_set_quality(l, 2)
        lame_set_bWriteVbrTag(l, 1)
        guard lame_init_params(l) >= 0 else { lame_close(l); throw ExportError.unsupported("LAME doesn't accept \(Int(sampleRate)) Hz at \(bitRate / 1_000) kbit/s.") }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forUpdating: url) else { lame_close(l); throw ExportError.unsupported("Can't write \(url.lastPathComponent).") }
        handle = h
        if let id3 {
            try h.write(contentsOf: id3)
            audioStart = UInt64(id3.count)
        }
    }

    deinit {
        lame_close(lame)
        try? handle.close()
    }

    public func write(_ samples: UnsafeBufferPointer<Float>) throws {
        guard let base = samples.baseAddress else { return }
        let frames = samples.count / channels
        let need = Int(1.25 * Double(frames)) + 7_200
        if buffer.count < need { buffer = [UInt8](repeating: 0, count: need) }
        let n: Int32 = buffer.withUnsafeMutableBufferPointer { out in
            channels == 1
                ? lame_encode_buffer_ieee_float(lame, base, base, Int32(frames), out.baseAddress, Int32(out.count))
                : lame_encode_buffer_interleaved_ieee_float(lame, base, Int32(frames), out.baseAddress, Int32(out.count))
        }
        guard n >= 0 else { throw ExportError.encoder("encode MP3", OSStatus(n)) }
        try handle.write(contentsOf: buffer[0..<Int(n)])
    }

    public func finish() throws {
        let n = buffer.withUnsafeMutableBufferPointer { lame_encode_flush(lame, $0.baseAddress, Int32($0.count)) }
        if n > 0 { try handle.write(contentsOf: buffer[0..<Int(n)]) }
        // The LAME tag (frame count, delay, padding) goes in the first frame's place.
        var tag = [UInt8](repeating: 0, count: 2_880)
        let size = tag.withUnsafeMutableBufferPointer { lame_get_lametag_frame(lame, $0.baseAddress, $0.count) }
        if size > 0, size <= tag.count {
            try handle.seek(toOffset: audioStart)
            try handle.write(contentsOf: tag[0..<size])
        }
        try handle.close()
    }

    /// Lets `EncodedWriter` (and so the app and the API) write MP3.
    public static func register() {
        EncodedWriter.mp3Factory = { url, ch, rate, br, id3 in try MP3Writer(url: url, channels: ch, sampleRate: rate, bitRate: br, id3: id3) }
    }
}
