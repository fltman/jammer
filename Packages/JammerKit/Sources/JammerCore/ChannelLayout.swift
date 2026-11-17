import Foundation

/// A loudspeaker of a channel-based layout. The raw value is the bit WAVE_FORMAT_EXTENSIBLE gives it in
/// `dwChannelMask` (Microsoft's ksmedia.h), which also fixes the order: in a WAV file the channels that are
/// present come in the order of their bits.
public enum Speaker: UInt32, Sendable, CaseIterable, Codable {
    case frontLeft = 0x1, frontRight = 0x2, frontCenter = 0x4, lowFrequency = 0x8
    case backLeft = 0x10, backRight = 0x20, frontLeftOfCenter = 0x40, frontRightOfCenter = 0x80
    case backCenter = 0x100, sideLeft = 0x200, sideRight = 0x400, topCenter = 0x800
    case topFrontLeft = 0x1000, topFrontCenter = 0x2000, topFrontRight = 0x4000
    case topBackLeft = 0x8000, topBackCenter = 0x10000, topBackRight = 0x20000

    /// The short name used in the window and the API (L, R, C, LFE, Ls, Rs, Lss, Rss, Lrs, Rrs, Ltf, Rtf, Ltr, Rtr…).
    public var short: String {
        switch self {
        case .frontLeft: "L"
        case .frontRight: "R"
        case .frontCenter: "C"
        case .lowFrequency: "LFE"
        case .backLeft: "Lrs"
        case .backRight: "Rrs"
        case .frontLeftOfCenter: "Lc"
        case .frontRightOfCenter: "Rc"
        case .backCenter: "Cs"
        case .sideLeft: "Lss"
        case .sideRight: "Rss"
        case .topCenter: "Tc"
        case .topFrontLeft: "Ltf"
        case .topFrontCenter: "Ctf"
        case .topFrontRight: "Rtf"
        case .topBackLeft: "Ltr"
        case .topBackCenter: "Ctr"
        case .topBackRight: "Rtr"
        }
    }
    public var isHeight: Bool { rawValue >= Speaker.topCenter.rawValue }
    /// Its weight in a loudness measurement (ITU-R BS.1770-5, Annex 3, Table 4): 1.41 in the ear layer from
    /// 60° to 120° off the front, 1.00 elsewhere, the LFE not included. The side pair is at ±90° (7.1) or
    /// ±110° (5.1's surrounds), the back pair at ±135°.
    public var loudnessWeight: Double {
        switch self {
        case .lowFrequency: 0
        case .sideLeft, .sideRight: 1.41
        default: 1
        }
    }
}

/// The channels of a document: which loudspeaker each channel feeds, in file order. Channel-based only
/// (Ambisonics is a sound field, not loudspeakers, and is its own kind; see docs/IMMERSIVE.md).
public enum ChannelLayout: String, Sendable, CaseIterable, Codable {
    case mono, stereo
    case surround51 = "5.1", surround71 = "7.1", immersive714 = "7.1.4"

    /// The loudspeakers, in the order the channels come in a file and in the document.
    /// 5.1's surrounds are the side pair (mask 0x60F, ITU-R BS.775's placement at about ±110°); a 5.1 file
    /// whose mask names the back pair (0x3F) is the same layout and is read as this one.
    public var speakers: [Speaker] {
        switch self {
        case .mono: [.frontCenter]
        case .stereo: [.frontLeft, .frontRight]
        case .surround51: [.frontLeft, .frontRight, .frontCenter, .lowFrequency, .sideLeft, .sideRight]
        case .surround71: [.frontLeft, .frontRight, .frontCenter, .lowFrequency, .backLeft, .backRight, .sideLeft, .sideRight]
        case .immersive714: [.frontLeft, .frontRight, .frontCenter, .lowFrequency, .backLeft, .backRight, .sideLeft, .sideRight,
                             .topFrontLeft, .topFrontRight, .topBackLeft, .topBackRight]
        }
    }
    public var channels: Int { speakers.count }
    /// The WAV channel mask. Mono and stereo files are written without one, as they always were.
    public var mask: UInt32? { channels <= 2 ? nil : speakers.reduce(0) { $0 | $1.rawValue } }
    public var title: String { self == .mono ? "Mono" : self == .stereo ? "Stereo" : rawValue }

    /// The layout a document has by default for a channel count (what a file without a mask means).
    public static func standard(channels: Int) -> ChannelLayout? {
        switch channels {
        case 1: .mono
        case 2: .stereo
        case 6: .surround51
        case 8: .surround71
        case 12: .immersive714
        default: nil
        }
    }

    /// The layout of a file: by its mask when it has one that names a known layout (5.1 with the back pair
    /// counts as 5.1), else by its channel count. nil: a layout this app doesn't know.
    public static func of(channels: Int, mask: UInt32?) -> ChannelLayout? {
        if let mask, mask != 0 {
            if mask == 0x3F { return channels == 6 ? .surround51 : nil }
            return allCases.first { $0.mask == mask && $0.channels == channels } ?? (channels <= 2 ? standard(channels: channels) : nil)
        }
        return standard(channels: channels)
    }
}

extension ChannelLayout {
    /// How a source's channels go into a document of this layout, as gains [source channel][document channel];
    /// nil when the old way holds (a document of mono or stereo with a source of one or two channels, or a
    /// source in exactly this layout), so that those render sample for sample as they always did.
    ///
    /// Into a wider layout each source loudspeaker goes to the same loudspeaker; a mono source (a voice) goes
    /// to the centre. A source wider than the document is folded down a layout at a time (`foldStep`).
    public func matrix(sourceChannels: Int, sourceMask: UInt32?) -> [Float]? {
        let source = ChannelLayout.of(channels: sourceChannels, mask: sourceMask)
        if source == self { return nil }
        if channels <= 2, sourceChannels <= 2 { return nil }
        guard let source else {
            // A source in a layout this app doesn't know: its first channels into the first channels, as before.
            return channels <= 2 ? nil : (0..<sourceChannels).flatMap { k in (0..<channels).map { Float(k == $0 ? 1 : 0) } }
        }
        return ChannelLayout.gains(from: source, to: self)
    }

    /// The gains from one layout to another, [from channel][to channel].
    public static func gains(from s: ChannelLayout, to d: ChannelLayout) -> [Float] {
        let into = d.speakers
        if s == .mono {
            // A voice to the centre; where there is none (stereo), to both sides, as a mono source always went.
            guard let c = into.firstIndex(of: .frontCenter) else { return [Float](repeating: 1, count: d.channels) }
            return (0..<d.channels).map { Float($0 == c ? 1 : 0) }
        }
        if Set(s.speakers).isSubset(of: into) {
            var m = [Float](repeating: 0, count: s.channels * d.channels)
            for (k, speaker) in s.speakers.enumerated() { m[k * d.channels + into.firstIndex(of: speaker)!] = 1 }
            return m
        }
        // Wider than the document: one layout down, then on from there.
        let (next, step) = foldStep(s, toward: d)
        let rest = gains(from: next, to: d)
        var m = [Float](repeating: 0, count: s.channels * d.channels)
        for k in 0..<s.channels { for j in 0..<next.channels where step[k * next.channels + j] != 0 {
            for c in 0..<d.channels { m[k * d.channels + c] += step[k * next.channels + j] * rest[j * d.channels + c] }
        } }
        return m
    }

    /// One step of a fold-down, from a layout to the next smaller one on the way to `target`:
    /// - 5.1 to stereo and to mono: ITU-R BS.775-4, Annex 4, Table 2 (L′ = L + 0.7071 C + 0.7071 Ls; mono
    ///   C′ = 0.7071 L + 0.7071 R + C + 0.5 Ls + 0.5 Rs); the LFE has no column there and is left out.
    /// - 7.1 to 5.1: the sides and the rears into 5.1's surrounds at 0.707 each (AOMedia IAMF 2.0, Annex A2.2,
    ///   Ls5 = α·Lss7 + β·Lrs7, mode 2: α = β = 0.707).
    /// - 7.1.4 to 7.1: each height into the loudspeaker under it at 0.707 (−3 dB): the top fronts into L and
    ///   R, the top rears into the rears. No standard read gives a height fold into the ear layer; this is
    ///   Jämmer's own choice, at the −3 dB the others use (docs/IMMERSIVE.md).
    /// - Stereo to mono (only on the way from a wider layout): BS.775's L and R terms, 0.7071 each.
    static func foldStep(_ s: ChannelLayout, toward target: ChannelLayout) -> (ChannelLayout, [Float]) {
        let k: Float = 0.7071
        func step(_ to: ChannelLayout, _ rules: [(Speaker, Speaker, Float)]) -> (ChannelLayout, [Float]) {
            var m = [Float](repeating: 0, count: s.channels * to.channels)
            for (a, b, g) in rules { m[s.speakers.firstIndex(of: a)! * to.channels + to.speakers.firstIndex(of: b)!] += g }
            return (to, m)
        }
        switch s {
        case .immersive714:
            return step(.surround71, [(.frontLeft, .frontLeft, 1), (.frontRight, .frontRight, 1), (.frontCenter, .frontCenter, 1),
                                      (.lowFrequency, .lowFrequency, 1), (.backLeft, .backLeft, 1), (.backRight, .backRight, 1),
                                      (.sideLeft, .sideLeft, 1), (.sideRight, .sideRight, 1),
                                      (.topFrontLeft, .frontLeft, k), (.topFrontRight, .frontRight, k),
                                      (.topBackLeft, .backLeft, k), (.topBackRight, .backRight, k)])
        case .surround71:
            return step(.surround51, [(.frontLeft, .frontLeft, 1), (.frontRight, .frontRight, 1), (.frontCenter, .frontCenter, 1),
                                      (.lowFrequency, .lowFrequency, 1), (.sideLeft, .sideLeft, k), (.backLeft, .sideLeft, k),
                                      (.sideRight, .sideRight, k), (.backRight, .sideRight, k)])
        case .surround51 where target == .mono:
            return step(.mono, [(.frontLeft, .frontCenter, k), (.frontRight, .frontCenter, k), (.frontCenter, .frontCenter, 1),
                                (.sideLeft, .frontCenter, 0.5), (.sideRight, .frontCenter, 0.5)])
        case .surround51:
            return step(.stereo, [(.frontLeft, .frontLeft, 1), (.frontRight, .frontRight, 1), (.frontCenter, .frontLeft, k),
                                  (.frontCenter, .frontRight, k), (.sideLeft, .frontLeft, k), (.sideRight, .frontRight, k)])
        case .stereo:
            return step(.mono, [(.frontLeft, .frontCenter, k), (.frontRight, .frontCenter, k)])
        case .mono:
            return (.mono, [1])
        }
    }
}
