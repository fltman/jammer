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
