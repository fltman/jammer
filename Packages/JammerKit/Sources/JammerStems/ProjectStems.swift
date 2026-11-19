import CryptoKit
import Foundation
import JammerCore

public enum StemError: Error, LocalizedError, Equatable {
    case modelMissing
    case hasInserts(String)
    case nothing

    public var reason: String {
        switch self {
        case .modelMissing: "model_missing"
        case .hasInserts: "has_inserts"
        case .nothing: "nothing_to_separate"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .modelMissing: "The stem model isn't installed. Install it under Jämmer › Settings › Models."
        case .hasInserts(let n): "\(n) has plugins; they can't be split across stems. Remove them first, and put them on the stems afterwards."
        case .nothing: "There's no audio on those tracks."
        }
    }
    /// The same message by its key in the app's string catalogue (see `KeyedMessage`).
    public var keyed: KeyedMessage? {
        switch self {
        case .modelMissing: KeyedMessage("error.stem.modelMissing")
        case .hasInserts(let n): KeyedMessage("error.stem.hasInserts", ["\(n)"])
        case .nothing: KeyedMessage("error.stem.nothing")
        }
    }
}

/// Deezer's Spleeter 4stems weights as they publish them (MIT), fetched from their GitHub
/// release, checked against a pinned SHA-256 and unpacked into the models folder.
public struct StemModel: Sendable {
    public static let title = "Stem separation (Spleeter 4stems)"
    public static let licence = "MIT (Deezer)"
    public static let downloadBytes: Int64 = 146_308_147
    public static let sha256 = "3adb4a50ad4eb18c7c4d65fcf4cf2367a07d48408a5eb7d03cd20067429dfaa8"
    public static let defaultURL = URL(string: "https://github.com/deezer/spleeter/releases/download/v1.4.0/4stems.tar.gz")!

    public var folder: URL
    public var url: URL

    public init(modelsFolder: URL, url: URL = StemModel.defaultURL) {
        folder = modelsFolder.appending(path: "spleeter-4stems")
        self.url = url
    }

    var index: URL { folder.appending(path: "model.index") }
    var data: URL { folder.appending(path: "model.data-00000-of-00001") }
    public var isInstalled: Bool { FileManager.default.fileExists(atPath: index.path) && FileManager.default.fileExists(atPath: data.path) }

    public func remove() throws { try? FileManager.default.removeItem(at: folder) }

    public func install(session: URLSession = .shared, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        if isInstalled { return }
        let (tmp, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (response as? HTTPURLResponse)?.statusCode ?? 200 == 200 else { throw URLError(.badServerResponse) }
        progress(0.9)
        try Self.unpack(tmp, into: folder)
        progress(1)
    }

    /// Checks the archive's SHA-256, then unpacks it with the system's tar.
    static func unpack(_ archive: URL, into folder: URL, expecting sha: String = StemModel.sha256) throws {
        var hasher = SHA256()
        let h = try FileHandle(forReadingFrom: archive)
        defer { try? h.close() }
        while let chunk = try h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == sha else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "The stem model download doesn't match its checksum; nothing was installed."]) }
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", folder.path]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
    }

    /// MERL's MRX checkpoint as published in their repository (git LFS), MIT.
    public struct Soundtrack: Sendable {
        public static let title = "Soundtrack separation (MRX)"
        public static let licence = "MIT (MERL)"
        public static let downloadBytes: Int64 = 122_317_463
        public static let sha256 = "9cecc071c9e58afda34d1a98609a1540f61320e718bafecc4c9c1c5e3ed20a0c"
        public static let defaultURL = URL(string: "https://media.githubusercontent.com/media/merlresearch/cocktail-fork-separation/19b3de827ebc4bfb014570cf92dd32b4ee3b6921/checkpoints/default_mrx_pre_trained_weights.pth")!
        public var file: URL
        public var url: URL
        public init(modelsFolder: URL, url: URL = Soundtrack.defaultURL) {
            file = modelsFolder.appending(path: "mrx/default_mrx_pre_trained_weights.pth")
            self.url = url
        }
        public var isInstalled: Bool {
            ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0) == Self.downloadBytes
        }
        public func remove() throws { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        public func install(session: URLSession = .shared, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
            if isInstalled { return }
            let (tmp, response) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard (response as? HTTPURLResponse)?.statusCode ?? 200 == 200 else { throw URLError(.badServerResponse) }
            try Self.place(tmp, at: file)
            progress(1)
        }
        /// Checks the SHA-256, then moves the file into place.
        static func place(_ downloaded: URL, at file: URL, expecting sha: String = Soundtrack.sha256) throws {
            var hasher = SHA256()
            let h = try FileHandle(forReadingFrom: downloaded)
            defer { try? h.close() }
            while let chunk = try h.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
            guard hasher.finalize().map({ String(format: "%02x", $0) }).joined() == sha else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "The soundtrack model download doesn't match its checksum; nothing was installed."])
            }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.copyItem(at: downloaded, to: file)
        }
        public func loadNet() throws -> MRXNet {
            guard isInstalled else { throw StemError.modelMissing }
            return try MRXNet(checkpoint: TorchCheckpoint(url: file))
        }
    }

    public func loadNet() throws -> SpleeterNet {
        guard isInstalled else { throw StemError.modelMissing }
        return try SpleeterNet(checkpoint: TFCheckpoint(index: index, data: data))
    }
}

extension SpleeterNet: @unchecked Sendable {}

/// Something that splits 44.1 kHz stereo into stems, streaming each stem's blocks out.
/// `voiceStem` is the stem a transcript belongs with.
public protocol StemEngine {
    var stemNames: [String] { get }
    var voiceStem: Int { get }
    func separate(_ stereo: [Float], progress: (Double) -> Bool, write: (Int, [Float]) throws -> Void) throws
}

/// Spleeter-style masking with any estimator.
public struct MaskingEngine: StemEngine {
    public var net: StemEstimator
    public init(_ net: StemEstimator) { self.net = net }
    public var stemNames: [String] { net.stemNames }
    public var voiceStem: Int { 0 }
    public func separate(_ stereo: [Float], progress: (Double) -> Bool, write: (Int, [Float]) throws -> Void) throws {
        try StemSeparator.separate(stereo, with: net, progress: progress, write: write)
    }
}

/// MRX for soundtracks: speech, music and effects. As MERL's separate.py does it: the mix
/// is brought to -27 LUFS for the model and back afterwards, and the part the three
/// estimates leave is shared between music and effects ("music_sfx" consistency), so the
/// stems add up to the mix and the speech stays as the model gave it. Long audio runs in
/// overlapping chunks, crossfaded, since the model reads its input in both directions.
public struct SoundtrackEngine: StemEngine {
    public var net: MRXNet
    /// Chunk and overlap in seconds.
    public var chunk = 24.0, overlap = 4.0
    public init(_ net: MRXNet) { self.net = net }
    public var stemNames: [String] { ["speech", "music", "effects"] }
    public var voiceStem: Int { 0 }

    public func separate(_ stereo: [Float], progress: (Double) -> Bool, write: (Int, [Float]) throws -> Void) throws {
        let n = stereo.count / 2
        guard n > 0 else { return }
        var meter = LoudnessMeter(sampleRate: MRXNet.sampleRate, channels: 2)
        stereo.withUnsafeBufferPointer { meter.process($0) }
        let gain = meter.result.integrated.map { Float(pow(10, (-27 - $0) / 20)) } ?? 1
        let size = Int(chunk * MRXNet.sampleRate), lap = Int(overlap * MRXNet.sampleRate), step = size - lap
        // Per stem, the tail of the previous chunk still to be crossfaded (interleaved stereo).
        var tails = [[Float]](repeating: [], count: 3)
        var start = 0
        while start < n {
            let end = min(n, start + size)
            let last = end == n
            var est = [[Float]](repeating: [Float](repeating: 0, count: (end - start) * 2), count: 3)
            for c in 0..<2 {
                let x = (start..<end).map { stereo[$0 * 2 + c] * gain }
                let out = net.separate(channel: x)   // music, speech, effects
                for i in 0..<(end - start) {
                    let speech = out[1][i], music = out[0][i], fx = out[2][i]
                    let rest = (x[i] - speech - music - fx) / 2
                    est[0][i * 2 + c] = speech / gain
                    est[1][i * 2 + c] = (music + rest) / gain
                    est[2][i * 2 + c] = (fx + rest) / gain
                }
            }
            for s in 0..<3 {
                // Crossfade the first `lap` frames with the previous chunk's tail (the weights add to one).
                let fade = min(tails[s].count / 2, end - start)
                for i in 0..<fade {
                    let w = Float(i + 1) / Float(fade + 1)
                    for c in 0..<2 { est[s][i * 2 + c] = est[s][i * 2 + c] * w + tails[s][i * 2 + c] * (1 - w) }
                }
                let keep = last ? end - start : step
                try write(s, Array(est[s][0..<(keep * 2)]))
                tails[s] = last ? [] : Array(est[s][(keep * 2)...])
            }
            start += last ? end - start : step
            if !progress(Double(start) / Double(n)) { throw CancellationError() }
        }
    }
}

public struct StemReport: Sendable, Equatable {
    public var stems: [String]
    public var tracks: [UUID]
}

extension Project {
    /// Replaces each given track (nil: all with audio) by one track per stem, playing from
    /// new files over the track's extent. The stems share a group and keep the track's gain
    /// and mute; they add up to the track as it was. Words and speaker turns go to the first stem (vocals).
    public func separatingStems(tracks wanted: [UUID]? = nil, with net: StemEstimator, pool: SourcePool, media: URL,
                                progress: @escaping (Double) -> Bool = { _ in true }) throws -> (Project, StemReport) {
        try separatingStems(tracks: wanted, engine: MaskingEngine(net), pool: pool, media: media, progress: progress)
    }

    public func separatingStems(tracks wanted: [UUID]? = nil, engine: StemEngine, pool: SourcePool, media: URL,
                                progress: @escaping (Double) -> Bool = { _ in true }) throws -> (Project, StemReport) {
        let targets = tracks.indices.filter { !tracks[$0].clips.isEmpty && (wanted?.contains(tracks[$0].id) ?? true) }
        guard !targets.isEmpty else { throw StemError.nothing }
        if let t = targets.first(where: { !tracks[$0].inserts.isEmpty }) { throw StemError.hasInserts(tracks[t].name) }
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        var replacement: [Int: [Track]] = [:]
        var p = self
        let words = placedWords()
        let names = engine.stemNames
        for (k, t) in targets.enumerated() {
            let first = tracks[t].clips.map(\.start).min()!, end = tracks[t].end
            var solo = self
            solo.tracks = [tracks[t]]
            solo.withoutMixer()
            solo.tracks[0].gainDB = 0
            solo.tracks[0].isMuted = false
            let raw = PlanCompiler.compile(solo, pool: pool).render(from: first, frames: Int(end - first))
            var stereo = channels == 2 ? raw : raw.flatMap { [$0, $0] }
            let native = sampleRate == StemSeparator.sampleRate
            if !native { stereo = try Alignment.resample(stereo, channels: 2, from: sampleRate, to: StemSeparator.sampleRate) }
            // Stems are streamed to files at 44.1 kHz stereo; converted afterwards when the project differs.
            let stamp = UUID().uuidString.prefix(8)
            let urls = names.map { media.appending(path: "\(stamp) \($0).wav") }
            for u in urls { MediaRegister.made(u, kind: "stem", in: media) }
            let direct = native && channels == 2
            let writers = try urls.map { try WAVWriter(url: direct ? $0 : $0.appendingPathExtension("tmp"), options: .init(encoding: .float32, channels: 2, sampleRate: StemSeparator.sampleRate)) }
            try engine.separate(stereo, progress: { progress((Double(k) + $0) / Double(targets.count)) }) { s, block in try writers[s].write(block) }
            for w in writers { try w.finish() }
            let group = UUID()
            var made: [Track] = []
            // When the project isn't 44.1 kHz stereo the stems are converted back, which loses
            // what 44.1 kHz can't carry; the last stem is then the track minus the others, so
            // the stems still add up to it exactly.
            var others = [Float](repeating: 0, count: direct ? 0 : raw.count)
            for (s, name) in names.enumerated() {
                if !direct {
                    let tmp = urls[s].appendingPathExtension("tmp")
                    let info = try AudioFileReader.info(at: tmp)
                    var x = SourcePool().read(SourceRef(name: name, path: tmp.path, info: info), from: 0, count: Int(info.frames))
                    if !native { x = try Alignment.resample(x, channels: 2, from: StemSeparator.sampleRate, to: sampleRate) }
                    if channels == 1 { x = stride(from: 0, to: x.count, by: 2).map { (x[$0] + x[$0 + 1]) / 2 } }
                    let want = Int(end - first) * channels
                    if x.count > want { x.removeLast(x.count - want) } else if x.count < want { x += [Float](repeating: 0, count: want - x.count) }
                    if s < names.count - 1 {
                        for i in 0..<want { others[i] += x[i] }
                    } else {
                        for i in 0..<want { x[i] = raw[i] - others[i] }
                    }
                    let w = try WAVWriter(url: urls[s], options: .init(encoding: .float32, channels: channels, sampleRate: sampleRate))
                    try w.write(x); try w.finish()
                    try? FileManager.default.removeItem(at: tmp)
                }
                let src = SourceRef(name: "\(tracks[t].name) (\(name))", path: urls[s].path, info: try AudioFileReader.info(at: urls[s])).withRepairs(repairsCarried(by: tracks[t]))
                p.sources.append(src)
                var track = Track(name: "\(tracks[t].name) – \(name.prefix(1).uppercased() + name.dropFirst())",
                                  clips: [Clip(sourceID: src.id, start: first, length: min(end - first, src.info.frames))], gainDB: tracks[t].gainDB, isMuted: tracks[t].isMuted)
                track.group = group
                made.append(track)
                if s == engine.voiceStem {
                    let mine = words.filter { $0.track == t }.map { w -> Word in var w2 = w.word; w2.start = w.start - first; w2.end = w.end - first; return w2 }
                    if !mine.isEmpty { p.setTranscript(SourceTranscript(sourceID: src.id, language: transcripts.first?.language ?? "und", engine: "carried", words: mine)) }
                    p.addCarriedTurns(turnsForBounce(track: t, range: first..<end), to: src.id)
                }
            }
            replacement[t] = made
        }
        p.tracks = tracks.indices.flatMap { replacement[$0] ?? [tracks[$0]] }
        p.pruneSources()
        return (p, StemReport(stems: names, tracks: replacement.keys.sorted().flatMap { replacement[$0]!.map(\.id) }))
    }
}

extension StemError: KeyedFailure {}
