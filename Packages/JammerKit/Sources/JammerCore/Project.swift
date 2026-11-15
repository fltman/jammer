import Foundation

/// Timeline positions and lengths are whole frames at the project's sample rate.
public typealias Frame = Int64

/// A source file the project plays from. Edits never touch it.
public struct SourceRef: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Absolute path when the project was saved; the bookmark wins when it resolves.
    public var path: String
    public var bookmark: Data?
    public var info: AudioFileInfo
    /// The file Jammer decoded this source from (MP3, FLAC…), when it isn't the file itself.
    public var originalPath: String?
    /// Set when the file lives inside the project package ("Media/…"); `path` is then rebuilt on open.
    public var packagePath: String?

    public init(id: UUID = UUID(), name: String, path: String, bookmark: Data? = nil, info: AudioFileInfo, originalPath: String? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.bookmark = bookmark
        self.info = info
        self.originalPath = originalPath
    }

    public static func == (a: SourceRef, b: SourceRef) -> Bool { a.id == b.id && a.path == b.path }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

public enum FadeShape: String, Codable, Sendable, CaseIterable { case linear, equalPower }

/// A stretch of a source placed on a track.
public struct Clip: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var sourceID: UUID
    public var sourceStart: Frame
    public var start: Frame
    public var length: Frame
    public var gainDB: Double
    public var fadeIn: Frame
    public var fadeOut: Frame
    public var fadeShape: FadeShape

    public init(id: UUID = UUID(), sourceID: UUID, sourceStart: Frame = 0, start: Frame, length: Frame,
                gainDB: Double = 0, fadeIn: Frame = 0, fadeOut: Frame = 0, fadeShape: FadeShape = .equalPower) {
        self.id = id
        self.sourceID = sourceID
        self.sourceStart = sourceStart
        self.start = start
        self.length = length
        self.gainDB = gainDB
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.fadeShape = fadeShape
    }

    public var end: Frame { start + length }
    public var range: Range<Frame> { start..<end }

    /// The parts of this clip before and after `t` (nil where empty).
    func split(at t: Frame) -> (Clip?, Clip?) {
        guard t > start else { return (nil, self) }
        guard t < end else { return (self, nil) }
        var left = self
        left.length = t - start
        left.fadeOut = 0
        left.fadeIn = min(fadeIn, left.length)
        var right = self
        right.id = UUID()
        right.sourceStart += t - start
        right.start = t
        right.length = end - t
        right.fadeIn = 0
        right.fadeOut = min(fadeOut, right.length)
        return (left, right)
    }
}

public struct Track: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var clips: [Clip]
    public var gainDB: Double
    public var isMuted: Bool

    public init(id: UUID = UUID(), name: String, clips: [Clip] = [], gainDB: Double = 0, isMuted: Bool = false) {
        self.id = id
        self.name = name
        self.clips = clips
        self.gainDB = gainDB
        self.isMuted = isMuted
    }

    public var end: Frame { clips.map(\.end).max() ?? 0 }
}

public struct Marker: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var position: Frame
    /// 0 for a point; otherwise a region.
    public var length: Frame
    public var name: String

    public init(id: UUID = UUID(), position: Frame, length: Frame = 0, name: String) {
        self.id = id
        self.position = position
        self.length = length
        self.name = name
    }
}

/// What a copy or cut holds: clips per track, relative to the start of the range.
public struct ClipboardContent: Codable, Sendable, Equatable {
    public var length: Frame
    public var tracks: [[Clip]]
    public var sources: [SourceRef]
}

public enum EditError: Error, LocalizedError, Equatable {
    case emptyRange
    case outOfRange
    case noTrack
    case spansClips
    case unknownSource

    public var errorDescription: String? {
        switch self {
        case .emptyRange: "Select a range first."
        case .outOfRange: "The range is outside the audio."
        case .noTrack: "There's no such track."
        case .spansClips: "The range covers more than one clip. Fade one clip at a time."
        case .unknownSource: "The pasted audio refers to a file this project doesn't have."
        }
    }
}

/// The whole document. A value: an undo step is the previous value.
public struct Project: Codable, Equatable, Sendable {
    public static let formatVersion = 1

    public var formatVersion: Int
    public var sampleRate: Double
    public var channels: Int
    public var tracks: [Track]
    public var markers: [Marker]
    public var sources: [SourceRef]

    public init(sampleRate: Double, channels: Int, tracks: [Track] = [], markers: [Marker] = [], sources: [SourceRef] = []) {
        formatVersion = Self.formatVersion
        self.sampleRate = sampleRate
        self.channels = channels
        self.tracks = tracks
        self.markers = markers
        self.sources = sources
    }

    /// A project with one track playing the whole file.
    public init(source: SourceRef) {
        self.init(sampleRate: source.info.sampleRate, channels: max(1, min(2, source.info.channels)))
        sources = [source]
        tracks = [Track(name: source.name, clips: [Clip(sourceID: source.id, start: 0, length: source.info.frames)])]
        markers = source.info.markers.map { Marker(position: $0.position, length: $0.length, name: $0.name) }
    }

    public var length: Frame { tracks.map(\.end).max() ?? 0 }
    public var duration: Double { Double(length) / sampleRate }

    public func source(_ id: UUID) -> SourceRef? { sources.first { $0.id == id } }

    public func frames(_ seconds: Double) -> Frame { Frame((seconds * sampleRate).rounded()) }
    public func seconds(_ frames: Frame) -> Double { Double(frames) / sampleRate }

    // MARK: Edits (every track, like a waveform editor)

    /// Splits every clip that crosses `t`.
    public mutating func split(at t: Frame) {
        for i in tracks.indices {
            tracks[i].clips = tracks[i].clips.flatMap { c -> [Clip] in
                guard c.start < t, t < c.end else { return [c] }
                let (l, r) = c.split(at: t)
                return [l, r].compactMap { $0 }
            }
        }
    }

    /// Removes `range`; with `ripple`, everything after it moves left to close the gap.
    public mutating func delete(_ range: Range<Frame>, ripple: Bool = true) throws {
        guard !range.isEmpty else { throw EditError.emptyRange }
        split(at: range.lowerBound)
        split(at: range.upperBound)
        let n = range.count
        for i in tracks.indices {
            tracks[i].clips.removeAll { range.contains($0.start) }
            if ripple {
                for j in tracks[i].clips.indices where tracks[i].clips[j].start >= range.upperBound {
                    tracks[i].clips[j].start -= Frame(n)
                }
            }
        }
        if ripple {
            markers = markers.compactMap { m in
                if range.contains(m.position) { return nil }
                var m = m
                if m.position >= range.upperBound { m.position -= Frame(n) }
                return m
            }
        }
    }

    public func copy(_ range: Range<Frame>) throws -> ClipboardContent {
        guard !range.isEmpty else { throw EditError.emptyRange }
        var p = self
        p.split(at: range.lowerBound)
        p.split(at: range.upperBound)
        let tracks = p.tracks.map { t in
            t.clips.filter { range.contains($0.start) }.map { c -> Clip in
                var c = c
                c.id = UUID()
                c.start -= range.lowerBound
                return c
            }
        }
        let used = Set(tracks.flatMap { $0.map(\.sourceID) })
        return ClipboardContent(length: Frame(range.count), tracks: tracks, sources: sources.filter { used.contains($0.id) })
    }

    public mutating func cut(_ range: Range<Frame>) throws -> ClipboardContent {
        let content = try copy(range)
        try delete(range)
        return content
    }

    /// Opens a gap of `length` at `t` on every track.
    public mutating func insertGap(at t: Frame, length: Frame) {
        guard length > 0 else { return }
        split(at: t)
        for i in tracks.indices {
            for j in tracks[i].clips.indices where tracks[i].clips[j].start >= t { tracks[i].clips[j].start += length }
        }
        for j in markers.indices where markers[j].position >= t { markers[j].position += length }
    }

    /// Inserts copied audio at `t`, pushing what follows to the right.
    public mutating func paste(_ content: ClipboardContent, at t: Frame) throws {
        guard content.length > 0 else { throw EditError.emptyRange }
        for s in content.sources where source(s.id) == nil { sources.append(s) }
        guard content.tracks.allSatisfy({ $0.allSatisfy { c in source(c.sourceID) != nil } }) else { throw EditError.unknownSource }
        insertGap(at: t, length: content.length)
        while tracks.count < content.tracks.count { tracks.append(Track(name: "Track \(tracks.count + 1)")) }
        for (i, clips) in content.tracks.enumerated() {
            tracks[i].clips += clips.map { c in
                var c = c
                c.id = UUID()
                c.start += t
                return c
            }
            tracks[i].clips.sort { $0.start < $1.start }
        }
    }

    /// Keeps only `range`, moved to the start.
    public mutating func crop(to range: Range<Frame>) throws {
        guard !range.isEmpty else { throw EditError.emptyRange }
        let end = length
        if range.upperBound < end { try delete(range.upperBound..<end) }
        if range.lowerBound > 0 { try delete(0..<range.lowerBound) }
    }

    /// Changes the gain of everything inside `range` by `dB`.
    public mutating func changeGain(_ range: Range<Frame>, by dB: Double) throws {
        guard !range.isEmpty else { throw EditError.emptyRange }
        split(at: range.lowerBound)
        split(at: range.upperBound)
        for i in tracks.indices {
            for j in tracks[i].clips.indices where range.contains(tracks[i].clips[j].start) {
                tracks[i].clips[j].gainDB += dB
            }
        }
    }

    public enum FadeKind: String, Sendable, Codable { case fadeIn, fadeOut }

    /// Fades in or out over `range`, which must lie inside one clip per track.
    /// The clip is split at the outer edge so the fade lands exactly on the range.
    public mutating func fade(_ kind: FadeKind, _ range: Range<Frame>, shape: FadeShape = .equalPower) throws {
        guard !range.isEmpty else { throw EditError.emptyRange }
        var touched = false
        for i in tracks.indices {
            let covering = tracks[i].clips.filter { $0.start < range.upperBound && $0.end > range.lowerBound }
            if covering.isEmpty { continue }
            guard covering.count == 1, covering[0].start <= range.lowerBound, covering[0].end >= range.upperBound else {
                throw EditError.spansClips
            }
            touched = true
        }
        guard touched else { throw EditError.outOfRange }
        // Fade in: the clip starts at the range; fade out: it ends there.
        split(at: kind == .fadeIn ? range.lowerBound : range.upperBound)
        for i in tracks.indices {
            for j in tracks[i].clips.indices {
                var c = tracks[i].clips[j]
                switch kind {
                case .fadeIn where c.start == range.lowerBound && c.end >= range.upperBound:
                    c.fadeIn = Frame(range.count)
                    c.fadeOut = min(c.fadeOut, c.length - c.fadeIn)
                case .fadeOut where c.end == range.upperBound && c.start <= range.lowerBound:
                    c.fadeOut = Frame(range.count)
                    c.fadeIn = min(c.fadeIn, c.length - c.fadeOut)
                default:
                    continue
                }
                c.fadeShape = shape
                tracks[i].clips[j] = c
            }
        }
    }

    /// Silences `range` without moving anything.
    public mutating func silence(_ range: Range<Frame>) throws {
        try delete(range, ripple: false)
    }

    @discardableResult
    public mutating func addMarker(at t: Frame, length: Frame = 0, name: String) -> Marker {
        let m = Marker(position: t, length: length, name: name)
        markers.append(m)
        markers.sort { $0.position < $1.position }
        return m
    }

    /// Removes sources no clip uses.
    public mutating func pruneSources() {
        let used = Set(tracks.flatMap { $0.clips.map(\.sourceID) })
        sources.removeAll { !used.contains($0.id) }
    }
}
