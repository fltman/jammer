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
    /// The repairs this audio has been through ("dehum", "denoise"…), when Jämmer made the file
    /// from another: some measurements can't be trusted on repaired sound, and say so.
    public var repairs: [String]?
    /// The file is a sound field (AmbiX) of this order: set when its document was made Ambisonics of that order,
    /// or by `set_track` `field`. Nothing in a WAV says so. Into loudspeakers a field is decoded (AllRAD).
    public var fieldOrder: Int?
    /// How a file of 8 or 12 channels with no channel mask and no ADM names is heard: in BS.2051's order (sides
    /// before rears; Anders, 2026-11-17, and what a user's file opened from now gets, `opened()`) or in the WAV
    /// mask's (rears before sides). nil is the WAV mask's, as every project saved before had it, and as every
    /// file Jämmer writes itself is.
    public var unmaskedOrder: ChannelOrder?
    /// Speech a voice service made in a cloned voice (Overdub): the mark it carries in the project and into an
    /// export's metadata. Never removed by an edit.
    public var synthetic: SyntheticSpeech?

    /// Whether nothing in the file says its loudspeakers' order: 7.1 or 7.1.4 without a mask or ADM's chna.
    /// (5.1 is the same in both orders.)
    public var needsOrder: Bool {
        (info.channelMask ?? 0) == 0 && info.channelOrder == nil && fieldOrder == nil && (info.channels == 8 || info.channels == 12)
    }
    /// The order the file is heard in when it isn't the document layout's own: from ADM, or by the choice above.
    public var speakerOrder: [Speaker]? {
        if let named = info.channelOrder { return named }
        guard needsOrder, unmaskedOrder == .bs2051 else { return nil }
        return ChannelOrder.bs2051(channels: info.channels)
    }

    public func withRepairs(_ r: [String]?) -> SourceRef {
        var s = self
        s.repairs = r.flatMap { $0.isEmpty ? nil : Array($0.prefix(64)) }
        return s
    }

    public init(id: UUID = UUID(), name: String, path: String, bookmark: Data? = nil, info: AudioFileInfo, originalPath: String? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.bookmark = bookmark
        self.info = info
        self.originalPath = originalPath
        // A file that says it contains speech made with a cloned voice is marked so from the start.
        if let c = info.comment, let s = SyntheticSpeech.fromComment(c) { synthetic = s }
    }

    /// A user's own file, opened as it is: when it doesn't say its loudspeakers' order, heard in BS.2051's
    /// (Anders, 2026-11-17). Files Jämmer writes itself (frozen tracks, repairs, a decoded MP3 or FLAC) are in
    /// the document's own order, the WAV mask's, and keep nil.
    public func opened() -> SourceRef {
        var s = self
        if s.needsOrder { s.unmaskedOrder = .bs2051 }
        return s
    }

    /// The same file, heard the same way: a change of how it is heard (a field's order, the order of a file without
    /// a mask) is a change of the project, which the window keeps and undoes. (Until 2026-11-17 only the id and
    /// the path were compared, so a step that changed nothing else, set_track `field` alone, was dropped.)
    public static func == (a: SourceRef, b: SourceRef) -> Bool {
        a.id == b.id && a.path == b.path && a.fieldOrder == b.fieldOrder && a.unmaskedOrder == b.unmaskedOrder && a.synthetic == b.synthetic
    }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

/// The order of a 7.1 or 7.1.4 file's channels when the file doesn't say it.
public enum ChannelOrder: String, Codable, Sendable, CaseIterable {
    /// The WAV mask's bits in rising order: L R C LFE Lrs Rrs Lss Rss (Ltf Rtf Ltr Rtr), as ffmpeg reads it.
    case wav
    /// ITU-R BS.2051's: L R C LFE Lss Rss Lrs Rrs (Ltf Rtf Ltr Rtr), the sides first, as the ITU's own files.
    case bs2051

    static func bs2051(channels: Int) -> [Speaker]? {
        let ear: [Speaker] = [.frontLeft, .frontRight, .frontCenter, .lowFrequency, .sideLeft, .sideRight, .backLeft, .backRight]
        switch channels {
        case 8: return ear
        case 12: return ear + [.topFrontLeft, .topFrontRight, .topBackLeft, .topBackRight]
        default: return nil
        }
    }
}

public enum FadeShape: String, Codable, Sendable, CaseIterable { case linear, equalPower }

/// Where a clip or track came from when it was imported from another program's timeline
/// (Flimmer through FCPXML). Carried through every edit and saved, so the way back can be
/// built; nothing reads it yet.
public struct Origin: Codable, Hashable, Sendable {
    public var app: String
    public var clipId: String?
    public var trackId: String?
    public var linkedShotId: String?
    public var exportVersion: String?
    /// The sound of a video clip itself (Flimmer has no audio clip for it): `clipId` is the shot clip's.
    public var videoAudio: Bool?
    /// A clip linked to a shot: seconds from the shot's start, as it came in.
    public var clipRelativeOffset: Double?
    /// How the clip or track was when it came in, to tell later what has changed.
    public var snapshot: Snapshot?
    /// The clip's name as it came in, for its take's title after a change has rendered it into a file of another
    /// name ("Atmosfär (attenuated)"; round D, 2026-11-19). Older documents have none.
    public var name: String?

    public struct Snapshot: Codable, Hashable, Sendable {
        public var start: Frame = 0
        public var sourceStart: Frame = 0
        public var length: Frame = 0
        public var gainDB: Double = 0
        public var fadeIn: Frame = 0
        public var fadeOut: Frame = 0
        public var sourceID: UUID?
        /// Tracks only.
        public var muted: Bool?
        public init() {}
    }

    public init(app: String, clipId: String? = nil, trackId: String? = nil, linkedShotId: String? = nil, exportVersion: String? = nil) {
        self.app = app
        self.clipId = clipId
        self.trackId = trackId
        self.linkedShotId = linkedShotId
        self.exportVersion = exportVersion
    }
}

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
    public var origin: Origin?

    public init(id: UUID = UUID(), sourceID: UUID, sourceStart: Frame = 0, start: Frame, length: Frame,
                gainDB: Double = 0, fadeIn: Frame = 0, fadeOut: Frame = 0, fadeShape: FadeShape = .equalPower, origin: Origin? = nil) {
        self.id = id
        self.sourceID = sourceID
        self.sourceStart = sourceStart
        self.start = start
        self.length = length
        self.gainDB = gainDB
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.fadeShape = fadeShape
        self.origin = origin
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
    /// Audio Units the track runs through, in order, before its gain.
    public var inserts: [Insert]
    /// Tracks that belong together (the stems of one separated track) share a group id.
    public var group: UUID?
    public var origin: Origin?
    /// Set by `duck`: what the track played before it was ducked, so ducking again starts from
    /// that and not from the ducked sound. Only meant while the track still plays the ducked file.
    public var ducked: DuckOrigin?
    /// −1 (left) … 0 (centre) … 1 (right); see `Mixer.panGains`. Stereo documents only.
    public var pan: Double = 0
    /// The bus the track goes to; nil: the output.
    public var output: UUID?
    /// Copies of the track sent to buses.
    public var sends: [Send] = []
    /// The VCA group whose level and mute are added to the track's own; nil: none.
    public var vca: UUID?
    /// Set while the track is frozen: played from a file made through its plugins (see `Frozen`).
    public var frozen: Frozen?
    /// Where the track's mono or stereo sound is placed in a layout wider than stereo (the surround panner).
    /// nil: each source on its own loudspeakers (a voice in C, a pair in L and R). Not used in mono or stereo.
    public var position: SurroundPosition?
    /// The track's sound fields turned round the listener (yaw, pitch, roll), fixed; lanes move it.
    public var rotation: FieldRotation?
    /// Locked: no step may change its clips (StepRunner refuses it, naming the track). Level, pan, mute and the
    /// mixer stay free: the lock keeps the audio where it is, not how it is heard.
    public var locked = false
    /// The stretches recorded more than once, every take kept and one chosen (Recording.swift). Empty: none.
    public var takes: [TakeGroup] = []

    public init(id: UUID = UUID(), name: String, clips: [Clip] = [], gainDB: Double = 0, isMuted: Bool = false, inserts: [Insert] = []) {
        self.id = id
        self.name = name
        self.clips = clips
        self.gainDB = gainDB
        self.isMuted = isMuted
        self.inserts = inserts
    }

    private enum CodingKeys: String, CodingKey { case locked, id, name, clips, gainDB, isMuted, inserts, group, origin, ducked, pan, output, sends, vca, frozen, position, rotation, takes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        clips = try c.decode([Clip].self, forKey: .clips)
        gainDB = try c.decode(Double.self, forKey: .gainDB)
        isMuted = try c.decode(Bool.self, forKey: .isMuted)
        inserts = try c.decodeIfPresent([Insert].self, forKey: .inserts) ?? []
        group = try c.decodeIfPresent(UUID.self, forKey: .group)
        origin = try c.decodeIfPresent(Origin.self, forKey: .origin)
        ducked = try c.decodeIfPresent(DuckOrigin.self, forKey: .ducked)
        pan = try c.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        output = try c.decodeIfPresent(UUID.self, forKey: .output)
        sends = try c.decodeIfPresent([Send].self, forKey: .sends) ?? []
        vca = try c.decodeIfPresent(UUID.self, forKey: .vca)
        frozen = try c.decodeIfPresent(Frozen.self, forKey: .frozen)
        // A position out of range (a hand-edited file) is left out rather than played somewhere no control can show.
        position = (try? c.decodeIfPresent(SurroundPosition.self, forKey: .position)).flatMap { $0 }.flatMap { $0.isValid ? $0 : nil }
        // The same for a field's turn out of range.
        rotation = (try? c.decodeIfPresent(FieldRotation.self, forKey: .rotation)).flatMap { $0 }.flatMap { $0.isValid && !$0.isNone ? $0 : nil }
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        takes = try c.decodeIfPresent([TakeGroup].self, forKey: .takes) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(clips, forKey: .clips)
        try c.encodeIfPresent(vca, forKey: .vca)
        try c.encodeIfPresent(frozen, forKey: .frozen)
        try c.encodeIfPresent(position, forKey: .position)
        try c.encodeIfPresent(rotation, forKey: .rotation)
        // Only when locked: a file without locks reads and writes as before.
        if locked { try c.encode(true, forKey: .locked) }
        try c.encode(gainDB, forKey: .gainDB)
        try c.encode(isMuted, forKey: .isMuted)
        if !inserts.isEmpty { try c.encode(inserts, forKey: .inserts) }
        try c.encodeIfPresent(group, forKey: .group)
        try c.encodeIfPresent(origin, forKey: .origin)
        try c.encodeIfPresent(ducked, forKey: .ducked)
        // Written only when used, so a project that doesn't use the mixer is the file it always was.
        if pan != 0 { try c.encode(pan, forKey: .pan) }
        try c.encodeIfPresent(output, forKey: .output)
        if !sends.isEmpty { try c.encode(sends, forKey: .sends) }
        if !takes.isEmpty { try c.encode(takes, forKey: .takes) }
    }

    public var end: Frame { clips.map(\.end).max() ?? 0 }
}

public struct Marker: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var position: Frame
    /// 0 for a point; otherwise a region.
    public var length: Frame
    public var name: String
    /// nil: an ordinary marker. A shot marks where a picture sat in an imported film timeline:
    /// shown on the timeline, but not a chapter.
    public var kind: Kind?
    public enum Kind: String, Codable, Sendable { case shot }
    /// The name written into a file (WAV cue points): shots say what they are, so another
    /// program can tell them from the user's own markers.
    public var cueLabel: String { kind == .shot ? "Shot: \(name)" : name }

    public init(id: UUID = UUID(), position: Frame, length: Frame = 0, name: String, kind: Kind? = nil) {
        self.id = id
        self.position = position
        self.length = length
        self.name = name
        self.kind = kind
    }
}

/// What a copy or cut holds: clips per track, relative to the start of the range.
public struct ClipboardContent: Codable, Sendable, Equatable {
    public var length: Frame
    public var tracks: [[Clip]]
    public var sources: [SourceRef]
    /// The words of those sources, so pasting into another project keeps them.
    public var transcripts: [SourceTranscript]?
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
    /// The same message by its key in the app's string catalogue (see `KeyedMessage`).
    public var keyed: KeyedMessage? {
        switch self {
        case .emptyRange: KeyedMessage("error.edit.emptyRange")
        case .outOfRange: KeyedMessage("error.edit.outOfRange")
        case .noTrack: KeyedMessage("error.edit.noTrack")
        case .spansClips: KeyedMessage("error.edit.spansClips")
        case .unknownSource: KeyedMessage("error.edit.unknownSource")
        }
    }
}

/// The whole document. A value: an undo step is the previous value.
public struct Project: Codable, Equatable, Sendable {
    public static let formatVersion = 1
    /// What a project that uses the mixer is saved as. An app that only knows format 1 refuses it and
    /// says a newer Jämmer is needed, instead of playing every track straight to the output.
    public static let mixerFormatVersion = 2
    /// What a project with automation is saved as: an app that doesn't know automation refuses it,
    /// instead of opening it without its lanes and playing other levels than were saved.
    public static let automationFormatVersion = 3
    /// What a project wider than stereo (5.1, 7.1, 7.1.4) is saved as: an app that only knows mono and stereo
    /// would put a mono source in every channel, the LFE too, so it refuses the file instead.
    public static let immersiveFormatVersion = 4
    /// What a project with a sound field marked as such, or turned, is saved as: an app before it would play a
    /// field's components straight into loudspeakers, so it refuses the file instead.
    public static let fieldFormatVersion = 5
    /// What a project with a file heard in BS.2051's order is saved as: an app before it would hear the file's
    /// sides and rears the other way round, so it refuses the file instead.
    public static let orderFormatVersion = 6
    /// What a project with a cloned voice or speech made with one is saved as: an app before it would drop the
    /// record of consent and the mark on the made speech, so it refuses the file instead.
    public static let voiceFormatVersion = 7
    /// What a project with recorded takes is saved as: an app before it would play the chosen take and drop the
    /// others when it saved, so it refuses the file instead.
    public static let takeFormatVersion = 8
    public static let newestFormatVersion = 8

    /// A cloned voice, or speech made with one.
    public var usesVoices: Bool { !voices.isEmpty || sources.contains { $0.synthetic != nil } }
    /// Takes kept on some track (format 8).
    public var usesTakes: Bool { tracks.contains { !$0.takes.isEmpty } }

    /// A file without a mask heard in BS.2051's order.
    public var usesOrder: Bool { sources.contains { $0.needsOrder && $0.unmaskedOrder == .bs2051 } }
    /// The files whose order is a choice (7.1 or 7.1.4 without a mask or ADM), and the choice of the first.
    public var unmaskedOrder: ChannelOrder? { sources.first { $0.needsOrder }.map { $0.unmaskedOrder ?? .wav } }
    /// Hears every file that doesn't say its order in this one.
    public mutating func setUnmaskedOrder(_ o: ChannelOrder) {
        for i in sources.indices where sources[i].needsOrder { sources[i].unmaskedOrder = o }
    }

    /// A source marked as a sound field, a track turned, or a lane that turns one.
    public var usesFields: Bool {
        sources.contains { $0.fieldOrder != nil } || tracks.contains { $0.rotation != nil }
            || automation.contains { [.yaw, .pitch, .roll].contains($0.param) }
    }
    /// Marks the files of a sound field's size as fields of `order` (a document made Ambisonics says what its
    /// files are; a file with loudspeakers named in it is never taken for one).
    public mutating func markFields(order: Int) {
        let n = (order + 1) * (order + 1)
        for i in sources.indices where sources[i].info.channels == n && (sources[i].info.channelMask ?? 0) == 0 { sources[i].fieldOrder = order }
    }
    /// Whether the track plays a sound field.
    public func playsField(_ track: Track) -> Bool { track.clips.contains { source($0.sourceID)?.fieldOrder != nil } }

    /// The document's loudspeakers. Every layout has its own channel count, so the count says which.
    public var layout: ChannelLayout { ChannelLayout.standard(channels: channels) ?? .stereo }

    public struct NeedsNewer: Error, LocalizedError, Equatable, KeyedFailure {
        public var version: Int
        var said: Said { Said("error.project.newer", "This project was saved by a newer Jämmer (format %@) and uses things this version doesn't have. Open it in a newer Jämmer.", "\(version)") }
        public var errorDescription: String? { said.text }
        public var keyed: KeyedMessage? { said.keyed }
    }

    public var formatVersion: Int
    /// The mixer's buses. None: every track goes to the output, as before there was a mixer.
    public var buses: [Bus] = []
    /// The master strip. As made it does nothing.
    public var master = Master()
    /// VCA groups: one level and one mute for the strips that belong to each.
    public var vcas: [VCA] = []
    /// Automation lanes (see `AutomationLane`). None: every level is its fader, as before.
    public var automation: [AutomationLane] = []
    /// Voices cloned for this project (Overdub), each with the record of its consent; kept after a voice is
    /// deleted at the provider.
    public var voices: [ClonedVoice] = []
    public var sampleRate: Double
    public var channels: Int
    public var tracks: [Track]
    public var markers: [Marker]
    public var sources: [SourceRef]
    /// Tempo and time signature. Projects saved before it existed open at 120 BPM in 4/4.
    public var tempo: TempoMap
    /// Recognised words per source, anchored in source frames (see `placedWords`).
    public var transcripts: [SourceTranscript]
    /// Speaker names; `SpeakerTurn.speaker` and `Word.speaker` index into this.
    public var speakers: [String] = []
    /// Speakers whose name came from a voice profile on this Mac: only that it did, and how alike the voices were.
    /// Never the voiceprint itself (SIBLINGS, "Röstprofiler").
    public var speakerSuggestions: [SpeakerSuggestion] = []
    /// Who speaks when, per source, anchored in source frames like the words.
    public var speakerTurns: [SourceSpeakers] = []
    /// Set when the document was imported from another program's timeline: what came in,
    /// so the way back can say what is missing and whether the timing still holds.
    public var imported: ImportRecord?
    /// The picture's timecode, when the document is sound for a picture: its frame rate and the timecode
    /// the timeline starts at. nil: none (a file without it is read by an older Jämmer as it always was).
    public var timecode: TimecodeSettings?
    /// A film shown beside the sound, following the playhead. nil: none.
    public var video: VideoReference?
    /// The document's own id, the same wherever its file is moved or copied to: set the first time it records, and
    /// what an unfinished recording's journal is kept under (Recording.swift). nil: never recorded.
    public var documentID: UUID?

    public struct ImportRecord: Codable, Equatable, Sendable {
        public var app: String
        public var exportVersion: String?
        public var clipIds: [String]
        public var length: Frame
        /// Flimmer, exportVersion 2 and later: the project and story the export was made from.
        public var projectId: String?
        public var storyId: String?
        /// What each clip became in Flimmer at the last Send to Flimmer: by the Flimmer clip it was a take of (or
        /// "clip:<Jämmer clip id>" for a clip that was new), the new clip's id there; and the project they are in.
        /// Content of the document, saved with it and sent nowhere; used to send transcripts again to those clips.
        public var sentClips: [String: String]?
        public var sentProjectId: String?
        public init(app: String, exportVersion: String?, clipIds: [String], length: Frame, projectId: String? = nil, storyId: String? = nil) {
            self.app = app
            self.exportVersion = exportVersion
            self.clipIds = clipIds
            self.length = length
            self.projectId = projectId
            self.storyId = storyId
        }
    }

    public init(sampleRate: Double, channels: Int, tracks: [Track] = [], markers: [Marker] = [], sources: [SourceRef] = [],
                tempo: TempoMap = TempoMap(), transcripts: [SourceTranscript] = []) {
        formatVersion = Self.formatVersion
        self.sampleRate = sampleRate
        self.channels = channels
        self.tracks = tracks
        self.markers = markers
        self.sources = sources
        self.tempo = tempo
        self.transcripts = transcripts
    }

    private enum CodingKeys: String, CodingKey { case formatVersion, sampleRate, channels, tracks, markers, sources, tempo, transcripts, speakers, speakerTurns, imported, timecode, video, buses, master, vcas, automation, voices, speakerSuggestions, documentID }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(usesTakes ? Self.takeFormatVersion : usesVoices ? Self.voiceFormatVersion : usesOrder ? Self.orderFormatVersion : usesFields ? Self.fieldFormatVersion : channels > 2 ? Self.immersiveFormatVersion : usesAutomation ? Self.automationFormatVersion
                     : usesMixer ? Self.mixerFormatVersion : Self.formatVersion, forKey: .formatVersion)
        try c.encode(sampleRate, forKey: .sampleRate)
        try c.encode(channels, forKey: .channels)
        try c.encode(tracks, forKey: .tracks)
        try c.encode(markers, forKey: .markers)
        try c.encode(sources, forKey: .sources)
        try c.encode(tempo, forKey: .tempo)
        try c.encode(transcripts, forKey: .transcripts)
        try c.encode(speakers, forKey: .speakers)
        try c.encode(speakerTurns, forKey: .speakerTurns)
        try c.encodeIfPresent(imported, forKey: .imported)
        try c.encodeIfPresent(timecode, forKey: .timecode)
        try c.encodeIfPresent(video, forKey: .video)
        try c.encodeIfPresent(documentID, forKey: .documentID)
        if !buses.isEmpty { try c.encode(buses, forKey: .buses) }
        if !master.isDefault { try c.encode(master, forKey: .master) }
        if !vcas.isEmpty { try c.encode(vcas, forKey: .vcas) }
        if usesAutomation { try c.encode(liveLanes, forKey: .automation) }
        if !voices.isEmpty { try c.encode(voices, forKey: .voices) }
        if !speakerSuggestions.isEmpty { try c.encode(speakerSuggestions, forKey: .speakerSuggestions) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .formatVersion)
        // A format this app doesn't know is not opened as if it did.
        guard version <= Self.newestFormatVersion else { throw NeedsNewer(version: version) }
        // In memory the version is always the same: what the file is saved as is decided when it is saved.
        formatVersion = Self.formatVersion
        buses = try c.decodeIfPresent([Bus].self, forKey: .buses) ?? []
        master = try c.decodeIfPresent(Master.self, forKey: .master) ?? Master()
        vcas = try c.decodeIfPresent([VCA].self, forKey: .vcas) ?? []
        automation = try c.decodeIfPresent([AutomationLane].self, forKey: .automation) ?? []
        sampleRate = try c.decode(Double.self, forKey: .sampleRate)
        channels = try c.decode(Int.self, forKey: .channels)
        // Only the layouts this app knows: a project with another channel count isn't opened as if it were one.
        guard ChannelLayout.standard(channels: channels) != nil else {
            throw DecodingError.dataCorruptedError(forKey: .channels, in: c, debugDescription: "A project has 1, 2, 6, 8 or 12 channels (mono, stereo, 5.1, 7.1, 7.1.4) or 4, 9 or 16 (Ambisonics), not \(channels).")
        }
        tracks = try c.decode([Track].self, forKey: .tracks)
        markers = try c.decode([Marker].self, forKey: .markers)
        sources = try c.decode([SourceRef].self, forKey: .sources)
        tempo = try c.decodeIfPresent(TempoMap.self, forKey: .tempo) ?? TempoMap()
        transcripts = try c.decodeIfPresent([SourceTranscript].self, forKey: .transcripts) ?? []
        speakers = try c.decodeIfPresent([String].self, forKey: .speakers) ?? []
        imported = try c.decodeIfPresent(ImportRecord.self, forKey: .imported)
        // A timecode that can't be read (a rate this app doesn't know, a start that is no time of day) is
        // left out, not a reason to refuse the project: the sound is the same without it.
        // The same for the film beside the sound: one that can't be read (no path, a start that is no place
        // on a timeline) is left out.
        video = (try? c.decodeIfPresent(VideoReference.self, forKey: .video)).flatMap { $0 }
            .flatMap { !$0.path.isEmpty && $0.path.utf8.count <= 4_096 && (0...Frame(86_400 * 768_000)).contains($0.start) ? $0 : nil }
        documentID = try c.decodeIfPresent(UUID.self, forKey: .documentID)
        timecode = (try? c.decodeIfPresent(TimecodeSettings.self, forKey: .timecode)).flatMap { $0 }
            .flatMap { (0..<(24 * 3_600 * $0.rate.base)).contains($0.startFrames) ? $0 : nil }
        speakerTurns = try c.decodeIfPresent([SourceSpeakers].self, forKey: .speakerTurns) ?? []
        voices = try c.decodeIfPresent([ClonedVoice].self, forKey: .voices) ?? []
        speakerSuggestions = (try? c.decodeIfPresent([SpeakerSuggestion].self, forKey: .speakerSuggestions)).flatMap { $0 } ?? []
    }

    /// A project with one track playing the whole file.
    public init(source: SourceRef) {
        // A file in a layout this app knows keeps it (a 5.1 file is a 5.1 document); any other is heard as stereo, as before.
        let layout = ChannelLayout.of(channels: source.info.channels, mask: source.speakerOrder.map { $0.reduce(0) { $0 | $1.rawValue } } ?? source.info.channelMask)
        self.init(sampleRate: source.info.sampleRate, channels: layout?.channels ?? max(1, min(2, source.info.channels)))
        sources = [source]
        tracks = [Track(name: source.name, clips: [Clip(sourceID: source.id, start: 0, length: source.info.frames)])]
        markers = source.info.markers.map { Marker(position: $0.position, length: $0.length, name: $0.name) }
    }

    public var length: Frame { tracks.map(\.end).max() ?? 0 }
    public var duration: Double { Double(length) / sampleRate }

    public func source(_ id: UUID) -> SourceRef? { sources.first { $0.id == id } }

    public func frames(_ seconds: Double) -> Frame { Frame((seconds * sampleRate).rounded()) }
    public func seconds(_ frames: Frame) -> Double { Double(frames) / sampleRate }

    /// The repairs behind what `track` plays, for a file that is about to be made from it.
    public func repairsCarried(by track: Track) -> [String]? {
        var seen: [String] = []
        for clip in track.clips { for r in source(clip.sourceID)?.repairs ?? [] where !seen.contains(r) { seen.append(r) } }
        return seen.isEmpty ? nil : seen
    }

    /// Bar, beat and tick at `frame`.
    public func musicalPosition(at frame: Frame) -> MusicalPosition { tempo.position(at: frame, sampleRate: sampleRate) }
    /// The first frame at or after a bar, beat and tick.
    public func frame(at position: MusicalPosition) throws -> Frame { try tempo.frame(at: position, sampleRate: sampleRate) }

    // MARK: Edits (every track, like a waveform editor)

    /// Splits every clip that crosses `t`.
    /// Splits the clips under `t`, on every track or only on `onTracks` (the Split tool splits the track clicked).
    public mutating func split(at t: Frame, onTracks: Set<UUID>? = nil) {
        for i in tracks.indices where onTracks?.contains(tracks[i].id) ?? true {
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
            tempo.delete(range)
            // Automation belongs to the timeline: when every track closes up, every lane does too.
            automation = automation.map { $0.closing(range) }
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
        return ClipboardContent(length: Frame(range.count), tracks: tracks, sources: sources.filter { used.contains($0.id) },
                                transcripts: transcripts.filter { used.contains($0.sourceID) })
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
        tempo.insertGap(at: t, length: length)
        automation = automation.map { $0.opening(at: t, length: length) }
    }

    /// Inserts copied audio at `t`, pushing what follows to the right.
    public mutating func paste(_ content: ClipboardContent, at t: Frame) throws {
        guard content.length > 0 else { throw EditError.emptyRange }
        for s in content.sources where source(s.id) == nil { sources.append(s) }
        for t in content.transcripts ?? [] where !transcripts.contains(where: { $0.sourceID == t.sourceID }) { transcripts.append(t) }
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
        // What a track played before it was ducked is kept for as long as it plays the ducked file.
        for t in tracks.indices where tracks[t].ducked != nil && tracks[t].clips != [tracks[t].ducked!.bounce] { tracks[t].ducked = nil }
        // A frozen strip's file is kept for as long as the strip is frozen.
        let used = Set(tracks.flatMap { $0.clips.map(\.sourceID) + ($0.ducked?.clips.map(\.sourceID) ?? []) + [$0.frozen?.sourceID].compactMap { $0 } }
                       + buses.compactMap { $0.frozen?.sourceID })
        sources.removeAll { !used.contains($0.id) }
        transcripts.removeAll { !used.contains($0.sourceID) }
        speakerTurns.removeAll { !used.contains($0.sourceID) }
    }
}

extension EditError: KeyedFailure {}
