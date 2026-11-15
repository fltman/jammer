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

    public func loadNet() throws -> SpleeterNet {
        guard isInstalled else { throw StemError.modelMissing }
        return try SpleeterNet(checkpoint: TFCheckpoint(index: index, data: data))
    }
}

extension SpleeterNet: @unchecked Sendable {}

public struct StemReport: Sendable, Equatable {
    public var stems: [String]
    public var tracks: [UUID]
}

extension Project {
    /// Replaces each given track (nil: all with audio) by one track per stem, playing from
    /// new files over the track's extent. The stems share a group and keep the track's gain
    /// and mute; they add up to the track as it was (exactly at 44.1 kHz stereo, and to
    /// within resampling otherwise). Words and speaker turns go to the first stem (vocals).
    public func separatingStems(tracks wanted: [UUID]? = nil, with net: StemEstimator, pool: SourcePool, media: URL,
                                progress: @escaping (Double) -> Bool = { _ in true }) throws -> (Project, StemReport) {
        let targets = tracks.indices.filter { !tracks[$0].clips.isEmpty && (wanted?.contains(tracks[$0].id) ?? true) }
        guard !targets.isEmpty else { throw StemError.nothing }
        if let t = targets.first(where: { !tracks[$0].inserts.isEmpty }) { throw StemError.hasInserts(tracks[t].name) }
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        var replacement: [Int: [Track]] = [:]
        var p = self
        let words = placedWords()
        let names = net.stemNames
        for (k, t) in targets.enumerated() {
            let first = tracks[t].clips.map(\.start).min()!, end = tracks[t].end
            var solo = self
            solo.tracks = [tracks[t]]
            solo.tracks[0].gainDB = 0
            solo.tracks[0].isMuted = false
            let raw = PlanCompiler.compile(solo, pool: pool).render(from: first, frames: Int(end - first))
            var stereo = channels == 2 ? raw : raw.flatMap { [$0, $0] }
            let native = sampleRate == StemSeparator.sampleRate
            if !native { stereo = try Alignment.resample(stereo, channels: 2, from: sampleRate, to: StemSeparator.sampleRate) }
            // Stems are streamed to files at 44.1 kHz stereo; converted afterwards when the project differs.
            let stamp = UUID().uuidString.prefix(8)
            let urls = names.map { media.appending(path: "\(stamp) \($0).wav") }
            let direct = native && channels == 2
            let writers = try urls.map { try WAVWriter(url: direct ? $0 : $0.appendingPathExtension("tmp"), options: .init(encoding: .float32, channels: 2, sampleRate: StemSeparator.sampleRate)) }
            try StemSeparator.separate(stereo, with: net, progress: { progress((Double(k) + $0) / Double(targets.count)) }) { s, block in try writers[s].write(block) }
            for w in writers { try w.finish() }
            let group = UUID()
            var made: [Track] = []
            for (s, name) in names.enumerated() {
                if !direct {
                    let tmp = urls[s].appendingPathExtension("tmp")
                    let info = try AudioFileReader.info(at: tmp)
                    var x = SourcePool().read(SourceRef(name: name, path: tmp.path, info: info), from: 0, count: Int(info.frames))
                    if !native { x = try Alignment.resample(x, channels: 2, from: StemSeparator.sampleRate, to: sampleRate) }
                    if channels == 1 { x = stride(from: 0, to: x.count, by: 2).map { (x[$0] + x[$0 + 1]) / 2 } }
                    let want = Int(end - first) * channels
                    if x.count > want { x.removeLast(x.count - want) } else if x.count < want { x += [Float](repeating: 0, count: want - x.count) }
                    let w = try WAVWriter(url: urls[s], options: .init(encoding: .float32, channels: channels, sampleRate: sampleRate))
                    try w.write(x); try w.finish()
                    try? FileManager.default.removeItem(at: tmp)
                }
                let src = SourceRef(name: "\(tracks[t].name) (\(name))", path: urls[s].path, info: try AudioFileReader.info(at: urls[s]))
                p.sources.append(src)
                var track = Track(name: "\(tracks[t].name) – \(name.prefix(1).uppercased() + name.dropFirst())",
                                  clips: [Clip(sourceID: src.id, start: first, length: min(end - first, src.info.frames))], gainDB: tracks[t].gainDB, isMuted: tracks[t].isMuted)
                track.group = group
                made.append(track)
                if s == 0 {
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
