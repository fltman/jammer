import Foundation
import Testing
@testable import JammerCore

/// Audio files come from the net, from siblings and from agents: opening one is untrusted
/// input. Every file here is made by the test (nothing is downloaded): cut short, corrupted,
/// or with a header that claims an absurd length, channel count or sample rate. None may
/// crash, hang or make Jämmer write or allocate without bound; each must either open as
/// sound that really is in the file, or be refused in words.
enum Hostile {
    static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    static func be32(_ v: UInt32) -> [UInt8] { le32(v).reversed() }
    static func be16(_ v: UInt16) -> [UInt8] { le16(v).reversed() }
    static func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }

    /// A plain WAV: `frames` of a quiet tone, 16-bit.
    static func wav(frames: Int = 4_800, channels: UInt16 = 2, rate: UInt32 = 48_000, bits: UInt16 = 16, tag: UInt16 = 1,
                    dataSize: UInt32? = nil, extra: [UInt8] = []) -> Data {
        var samples: [UInt8] = []
        for i in 0..<frames {
            let v = Int16(3_000 * sin(Double(i) * 0.05))
            for _ in 0..<max(1, Int(channels)) { samples += le16(UInt16(bitPattern: v)) }
        }
        let fmt = le16(tag) + le16(channels) + le32(rate) + le32(rate &* UInt32(channels) &* UInt32(bits / 8)) + le16(channels &* (bits / 8)) + le16(bits)
        var body: [UInt8] = Array("WAVE".utf8) + Array("fmt ".utf8) + le32(16) + fmt + extra
        body += Array("data".utf8) + le32(dataSize ?? UInt32(samples.count)) + samples
        return Data(Array("RIFF".utf8) + le32(UInt32(truncatingIfNeeded: body.count)) + body)
    }

    static func chunk(_ id: String, _ payload: [UInt8], size: UInt32? = nil) -> [UInt8] {
        Array(id.utf8) + le32(size ?? UInt32(payload.count)) + payload + (payload.count % 2 == 1 ? [0] : [])
    }

    /// A plain AIFF, 16-bit big-endian. `rate` is the ten bytes of the 80-bit sample rate.
    static func aiff(frames: UInt32 = 4_800, claimed: UInt32? = nil, channels: UInt16 = 2, bits: UInt16 = 16,
                     rate: [UInt8] = [0x40, 0x0E, 0xBB, 0x80, 0, 0, 0, 0, 0, 0], ssndOffset: UInt32 = 0) -> Data {
        var samples: [UInt8] = []
        for i in 0..<Int(frames) { for _ in 0..<max(1, Int(channels)) { samples += be16(UInt16(bitPattern: Int16(3_000 * sin(Double(i) * 0.05)))) } }
        let comm = be16(channels) + be32(claimed ?? frames) + be16(bits) + rate
        var body: [UInt8] = Array("AIFF".utf8) + Array("COMM".utf8) + be32(18) + comm
        body += Array("SSND".utf8) + be32(UInt32(samples.count + 8)) + be32(ssndOffset) + be32(0) + samples
        return Data(Array("FORM".utf8) + be32(UInt32(body.count)) + body)
    }

    /// Makes a compressed file from a short tone with macOS's own converter.
    static func converted(_ ext: String, format: String, data: String, in dir: URL, seconds: Double = 1) throws -> Data {
        let source = dir.appending(path: "tone-\(ext).wav"), out = dir.appending(path: "tone.\(ext)")
        try wav(frames: Int(seconds * 48_000)).write(to: source)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", format, "-d", data, source.path, out.path]
        p.standardError = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return try Data(contentsOf: out)
    }

    /// Deterministic bytes.
    struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
    }
}

@Suite("Hostile and broken audio files")
struct HostileFileTests {
    /// Opens `data` as a file called `name` the way every route in does (File › Open, POST
    /// /documents, uploads, linked files, batch, the media of an imported timeline) and, when it
    /// opens, renders all of it. Returns what happened; the limits are checked here.
    @discardableResult
    func open(_ data: Data, as name: String, in dir: URL, sourceLocation: SourceLocation = #_sourceLocation) -> String {
        let file = dir.appending(path: name), media = dir.appending(path: "media-\(UUID().uuidString.prefix(6))")
        try? data.write(to: file)
        defer { try? FileManager.default.removeItem(at: media); try? FileManager.default.removeItem(at: file) }
        let t0 = Date()
        let outcome: String
        do {
            let r = try AudioImporter.importFile(file, mediaFolder: media)
            let info = r.source.info
            // What opened must be sane and really there.
            #expect((1...AudioFileInfo.maxChannels).contains(info.channels) && (AudioFileInfo.sampleRates).contains(info.sampleRate), "\(name): \(info.channels) ch at \(info.sampleRate) Hz", sourceLocation: sourceLocation)
            let onDisk = (try? FileManager.default.attributesOfItem(atPath: r.source.path)[.size] as? NSNumber)?.int64Value ?? 0
            #expect(info.frames >= 0 && info.dataOffset >= 0 && info.dataOffset + info.frames * Int64(info.channels * info.sampleFormat.bitsPerSample / 8) <= onDisk,
                    "\(name): claims \(info.frames) frames, the file has \(onDisk) bytes", sourceLocation: sourceLocation)
            // A one-second input never becomes more than a few megabytes of decoded audio.
            #expect(onDisk < 64 << 20, "\(name): decoded to \(onDisk) bytes", sourceLocation: sourceLocation)
            let p = Project(source: r.source)
            if p.length > 0 {
                let frames = Int(min(p.length, 96_000))
                #expect(PlanCompiler.compile(p, pool: SourcePool()).render(from: 0, frames: frames).count == frames * p.channels, sourceLocation: sourceLocation)
            }
            outcome = "opened \(info.frames)"
        } catch let e as AudioFileError {
            #expect(!(e.errorDescription ?? "").isEmpty, sourceLocation: sourceLocation)
            // A refusal leaves nothing half-written behind.
            let left = (try? FileManager.default.contentsOfDirectory(atPath: media.path)) ?? []
            #expect(left.isEmpty, "\(name): refused but left \(left)", sourceLocation: sourceLocation)
            outcome = "refused"
        } catch {
            Issue.record("\(name): an error that isn't Jämmer's own: \(error)", sourceLocation: sourceLocation)
            outcome = "error"
        }
        #expect(Date().timeIntervalSince(t0) < 20, "\(name) took \(Date().timeIntervalSince(t0)) s", sourceLocation: sourceLocation)
        return outcome
    }

    func folder() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "jammer-hostile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test("WAV: cut short anywhere, and headers that lie about length, channels, rate and chunk sizes")
    func wav() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = Hostile.wav()
        #expect(open(good, as: "good.wav", in: dir) == "opened 4800")
        for cut in [0, 1, 3, 4, 8, 11, 12, 16, 20, 35, 36, 40, 43, 44, 45, 47, good.count / 2, good.count - 1] {
            let o = open(good.prefix(cut), as: "cut-\(cut).wav", in: dir)
            if cut <= 44 { #expect(o == "refused", "cut at \(cut): \(o)") }
        }
        // A recording that was cut off keeps what is there, and no more.
        #expect(open(good.prefix(44 + 400), as: "cut-audio.wav", in: dir) == "opened 100")
        #expect(open(Hostile.wav(dataSize: 0xFFFF_FFFF), as: "huge-data.wav", in: dir) == "opened 4800")
        #expect(open(Hostile.wav(dataSize: 0x7FFF_FFF0), as: "big-data.wav", in: dir) == "opened 4800")
        #expect(open(Hostile.wav(frames: 0), as: "no-audio.wav", in: dir) == "refused", "a file with no sound in it isn't opened as an empty document")
        for (what, data) in [("channels 0", Hostile.wav(channels: 0)), ("channels 65535", Hostile.wav(frames: 4, channels: 65_535)), ("channels 1000", Hostile.wav(frames: 40, channels: 1_000)),
                             ("rate 0", Hostile.wav(rate: 0)), ("rate max", Hostile.wav(rate: 0xFFFF_FFFF)), ("rate 1", Hostile.wav(rate: 1)), ("rate 3 MHz", Hostile.wav(rate: 3_000_000)),
                             ("bits 0", Hostile.wav(bits: 0)), ("bits 65535", Hostile.wav(bits: 65_535)),
                             ("float 16", Hostile.wav(tag: 3))] {
            #expect(open(data, as: "lie.wav", in: dir) == "refused", "\(what)")
        }
        // Odd but legal sample sizes (12 bits in 16, 7 in 8) and compressed audio in a WAV wrapper go to
        // the system's decoder, which takes them or doesn't; what opens is checked like everything else.
        for bits: UInt16 in [7, 12, 20] { #expect(open(Hostile.wav(bits: bits), as: "bits.wav", in: dir) != "error", "\(bits) bits") }
        for tag: UInt16 in [2, 0x11, 0x55, 0xFFFF] { #expect(open(Hostile.wav(tag: tag), as: "tagged.wav", in: dir) != "error", "tag \(tag)") }
        // Chunks whose sizes point past the end, a cue list that claims four billion points, labels longer than the file.
        let cue = Hostile.chunk("cue ", Hostile.le32(0xFFFF_FFFF) + [UInt8](repeating: 1, count: 48))
        let list = Hostile.chunk("LIST", Array("adtl".utf8) + Array("labl".utf8) + Hostile.le32(0xFFFF_FF00) + [1, 0, 0, 0, 65, 0])
        let bext = Hostile.chunk("bext", [UInt8](repeating: 65, count: 100), size: 0x7FFF_FFFF)
        for (what, extra) in [("cue", cue), ("label", list), ("cue+label", cue + list), ("iXML", Hostile.chunk("iXML", [60, 62], size: 0xFFFF_FFF0)),
                              ("junk", Hostile.chunk("JUNK", [], size: 0xFFFF_FFFF)), ("many", (0..<5_000).flatMap { _ in Hostile.chunk("junk", [1, 2]) })] {
            #expect(open(Hostile.wav(extra: extra), as: "chunks.wav", in: dir) != "error", "\(what)")
        }
        // bext that claims two gigabytes swallows the data chunk: nothing to play, refused, not a crash.
        #expect(open(Hostile.wav(extra: bext), as: "bext.wav", in: dir) != "error")
        // RF64 whose 64-bit sizes are absurd.
        func rf64(dataSize: UInt64, tableCount: UInt32) -> Data {
            var d = [UInt8](Hostile.wav())
            d.replaceSubrange(0..<4, with: Array("RF64".utf8))
            let ds64 = Hostile.chunk("ds64", Hostile.le64(UInt64.max) + Hostile.le64(dataSize) + Hostile.le64(UInt64.max) + Hostile.le32(tableCount))
            d.insert(contentsOf: ds64, at: 12)
            let at = d.count - 4_800 * 4 - 4
            d.replaceSubrange(at..<(at + 4), with: Hostile.le32(0xFFFF_FFFF))
            return Data(d)
        }
        for (size, count) in [(UInt64.max, UInt32(0)), (UInt64(1) << 62, 0), (UInt64(Int64.max) + 1, 0xFFFF_FFFF), (19_200, 0xFFFF_FFFF), (0, 0)] {
            #expect(open(rf64(dataSize: size, tableCount: count), as: "rf64.wav", in: dir) != "error", "ds64 data \(size), table \(count)")
        }
        // Nothing at all, one byte, zeros, noise, text.
        var random = Hostile.Random(state: 7)
        for (what, data) in [("empty", Data()), ("one byte", Data([82])), ("zeros", Data(count: 4_096)), ("text", Data("RIFF is not what this is".utf8)),
                             ("noise", Data((0..<4_096).map { _ in UInt8(truncatingIfNeeded: random.next()) }))] {
            #expect(open(data, as: "junk.wav", in: dir) == "refused", "\(what)")
        }
        // Three hundred headers with a few bytes changed at random: whatever comes out is refused or really there.
        for i in 0..<300 {
            var d = [UInt8](good)
            for _ in 0..<(1 + Int(random.next() % 4)) { d[Int(random.next() % 60)] = UInt8(truncatingIfNeeded: random.next()) }
            #expect(open(Data(d), as: "flip-\(i).wav", in: dir) != "error")
        }
    }

    @Test("AIFF: the same, with its 80-bit sample rate")
    func aiff() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = Hostile.aiff()
        #expect(open(good, as: "good.aiff", in: dir) == "opened 4800")
        for cut in [0, 4, 11, 12, 20, 30, 37, 38, 45, 53, 54, 60, good.count / 2, good.count - 1] { open(good.prefix(cut), as: "cut-\(cut).aiff", in: dir) }
        #expect(open(Hostile.aiff(claimed: 0xFFFF_FFFF), as: "claims.aiff", in: dir) == "opened 4800", "the header's count never beats what is in the file")
        // (13 bits is a legal AIFF, stored in 16; whoever decodes it may take it.)
        #expect(open(Hostile.aiff(bits: 13), as: "13.aiff", in: dir) != "error")
        for (what, data) in [("channels 0", Hostile.aiff(channels: 0)), ("channels 65535", Hostile.aiff(frames: 4, channels: 65_535)), ("bits 0", Hostile.aiff(bits: 0)),
                             ("rate 0", Hostile.aiff(rate: [UInt8](repeating: 0, count: 10))), ("rate inf", Hostile.aiff(rate: [0x7F, 0xFF, 0x80, 0, 0, 0, 0, 0, 0, 0])),
                             ("rate nan", Hostile.aiff(rate: [0x7F, 0xFF, 0xC0, 0, 0, 0, 0, 0, 0, 1])), ("rate negative", Hostile.aiff(rate: [0xC0, 0x0E, 0xBB, 0x80, 0, 0, 0, 0, 0, 0])),
                             ("rate 1e300", Hostile.aiff(rate: [0x43, 0xE4, 0x80, 0, 0, 0, 0, 0, 0, 0])), ("rate tiny", Hostile.aiff(rate: [0x00, 0x01, 0x80, 0, 0, 0, 0, 0, 0, 0])),
                             ("offset past the end", Hostile.aiff(ssndOffset: 0xFFFF_FFF0))] {
            #expect(open(data, as: "lie.aiff", in: dir) == "refused", "\(what)")
        }
        var random = Hostile.Random(state: 11)
        for i in 0..<300 {
            var d = [UInt8](good)
            for _ in 0..<(1 + Int(random.next() % 4)) { d[Int(random.next() % 62)] = UInt8(truncatingIfNeeded: random.next()) }
            #expect(open(Data(d), as: "flip-\(i).aiff", in: dir) != "error")
        }
    }

    @Test("FLAC, AAC in M4A, Apple Lossless and CAF: cut short and corrupted, they open as what is there or are refused; nothing half-decoded is left",
          arguments: [("flac", "flac", "flac"), ("m4a", "m4af", "aac"), ("m4a", "m4af", "alac"), ("caf", "caff", "LEI16"), ("caf", "caff", "alac")])
    func compressed(ext: String, format: String, data: String) throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = try Hostile.converted(ext, format: format, data: data, in: dir)
        #expect(good.count > 500)
        #expect(open(good, as: "good.\(ext)", in: dir).hasPrefix("opened"))
        for cut in [0, 1, 4, 8, 16, 33, 64, 127, 200, good.count / 4, good.count / 2, good.count * 3 / 4, good.count - 1] {
            #expect(open(good.prefix(cut), as: "cut-\(cut).\(ext)", in: dir) != "error", "cut at \(cut)")
        }
        // Headers with bytes changed: lengths, rates and channel counts that lie in whatever way the format allows.
        var random = Hostile.Random(state: UInt64(good.count))
        for i in 0..<150 {
            var d = [UInt8](good)
            let span = min(d.count, i < 100 ? 256 : d.count)
            for _ in 0..<(1 + Int(random.next() % 3)) { d[Int(random.next() % UInt64(span))] = [0, 0xFF, 0x7F, 0x80, UInt8(truncatingIfNeeded: random.next())][Int(random.next() % 5)] }
            #expect(open(Data(d), as: "flip-\(i).\(ext)", in: dir) != "error")
        }
        // The same bytes under a name that says something else.
        #expect(open(good, as: "really-\(ext).wav", in: dir) != "error")
        #expect(open(good, as: "really-\(ext).mp3", in: dir) != "error")
    }

    @Test("MP3-shaped garbage: an ID3 tag that claims 256 MB, frame headers over noise, a name that lies")
    func mp3() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        var random = Hostile.Random(state: 3)
        let noise = (0..<8_000).map { _ in UInt8(truncatingIfNeeded: random.next()) }
        let id3: [UInt8] = Array("ID3".utf8) + [3, 0, 0, 0x7F, 0x7F, 0x7F, 0x7F]
        let frames: [UInt8] = (0..<20).flatMap { _ in [0xFF, 0xFB, 0x90, 0x64] + noise.prefix(413) }
        for (what, data) in [("tag only", Data(id3)), ("tag + noise", Data(id3 + noise)), ("frames over noise", Data(frames)), ("tag + frames", Data(id3 + frames)),
                             ("noise", Data(noise)), ("empty", Data()), ("a wav called mp3", Hostile.wav())] {
            #expect(open(data, as: "x.mp3", in: dir) != "error", "\(what)")
        }
    }

    @Test("Decoding stops at a size limit instead of filling the disk, and says so")
    func bomb() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Ten seconds of FLAC is small on disk and 3.8 MB decoded; with the limit at 1 MB it must be refused, with nothing left behind.
        let flac = try Hostile.converted("flac", format: "flac", data: "flac", in: dir, seconds: 10)
        let file = dir.appending(path: "long.flac"), media = dir.appending(path: "media")
        try flac.write(to: file)
        #expect(throws: AudioFileError.self) { _ = try AudioImporter.importFile(file, mediaFolder: media, maxDecodedBytes: 1 << 20) }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: media.path)) ?? []).isEmpty)
        do { _ = try AudioImporter.importFile(file, mediaFolder: media, maxDecodedBytes: 1 << 20) } catch {
            #expect(error.localizedDescription.contains("too large") || error.localizedDescription.contains("larger than"), "\(error.localizedDescription)")
        }
        // With room, it opens whole.
        let r = try AudioImporter.importFile(file, mediaFolder: media)
        #expect(abs(r.source.info.frames - 480_000) < 4_096)
    }

    @Test("A file that is cut short says so when it opens; a whole one doesn't")
    func warnsWhenShort() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        func warning(_ data: Data, _ name: String) throws -> String? {
            let file = dir.appending(path: name)
            try data.write(to: file)
            return try AudioImporter.importFile(file, mediaFolder: dir.appending(path: "media")).warning
        }
        let wav = Hostile.wav(frames: 48_000)
        #expect(try warning(wav, "whole.wav") == nil)
        #expect(try warning(wav.prefix(44 + 96_000), "half.wav") == "half.wav is cut short or damaged: 0.5 s of the 1.0 s it says it has could be read.")
        // A recorder that didn't know the length wrote the largest number: not a claim, no warning.
        #expect(try warning(Hostile.wav(frames: 48_000, dataSize: 0xFFFF_FFFF), "streamed.wav") == nil)
        #expect(try warning(Hostile.aiff(frames: 24_000, claimed: 48_000), "half.aiff") == "half.aiff is cut short or damaged: 0.5 s of the 1.0 s it says it has could be read.")
        let flac = try Hostile.converted("flac", format: "flac", data: "flac", in: dir, seconds: 4)
        #expect(try warning(flac, "whole.flac") == nil)
        // A compressed file that ends in the middle isn't opened as half of itself: it is refused, and says why.
        #expect(throws: AudioFileError.unsupported("half.flac is cut short: it ends before the sound it says it has, so it can't be opened.")) {
            _ = try warning(flac.prefix(flac.count / 2), "half.flac")
        }
    }
}
