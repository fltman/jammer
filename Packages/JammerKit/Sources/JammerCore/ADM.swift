import Foundation

/// ADM BWF for a bed of loudspeaker channels (ITU-R BS.2076 metadata in BS.2088's `chna` and `axml` chunks).
///
/// A file written here names, in `chna`, each of its tracks by the common definitions' track format and the
/// layout's pack format (ITU-R BS.2094), and in `axml` one programme, one content and one object holding those
/// tracks. The pack and channel formats themselves are the common definitions', referred to and not repeated.
/// The identifiers were read in the common definitions as the EBU's ADM renderer (`ear`) ships them; nothing of
/// its code is used. Checked by rendering the files with that renderer (docs/IMMERSIVE.md, block J).
///
/// Read back: a file's `chna` says which loudspeaker each track is, which is what tells a file with no channel
/// mask whose sides come before its rears (BS.2051's order) from one in the WAV mask's order.
public enum ADM {
    /// The common definitions' channel format of a loudspeaker in a layout (the number after AC_0001).
    /// 5.1's surrounds are the ±110° pair (AC_00010005/6); 7.1's sides the ±90° pair (0a/0b), its rears ±135°
    /// (1c/1d); 7.1.4's heights ±45° and ±135° at 30° up (22/23, 1e/1f).
    static func channelFormat(_ s: Speaker, in layout: ChannelLayout) -> UInt8? {
        switch s {
        case .frontLeft: 0x01
        case .frontRight: 0x02
        case .frontCenter: 0x03
        case .lowFrequency: 0x04
        case .sideLeft: layout == .surround51 ? 0x05 : 0x0a
        case .sideRight: layout == .surround51 ? 0x06 : 0x0b
        case .backLeft: 0x1c
        case .backRight: 0x1d
        case .topFrontLeft: 0x22
        case .topFrontRight: 0x23
        case .topBackLeft: 0x1e
        case .topBackRight: 0x1f
        default: nil
        }
    }

    /// The common definitions' pack format of a layout: 5.1 (0+5+0), 7.1 with its rears at ±135° ("7.1back",
    /// 0+7+0), 7.1.4 (4+7+0).
    static func packFormat(_ layout: ChannelLayout) -> String? {
        switch layout {
        case .surround51: "AP_00010003"
        case .surround71: "AP_0001000f"
        case .immersive714: "AP_00010017"
        default: nil
        }
    }

    /// The `chna` and `axml` chunks for a file in a loudspeaker layout wider than stereo, its channels in the
    /// layout's order; nil for mono, stereo and Ambisonics (no bed to describe).
    public static func chunks(for layout: ChannelLayout, title: String) -> [(id: String, payload: Data)]? {
        guard let pack = packFormat(layout) else { return nil }
        let formats = layout.speakers.map { channelFormat($0, in: layout) }
        guard formats.allSatisfy({ $0 != nil }) else { return nil }
        let tracks = formats.map { String(format: "AT_000100%02x_01", $0!) }
        let uids = (1...tracks.count).map { String(format: "ATU_%08x", $0) }

        // chna (BS.2088): track count, UID count, then per track its index (from 1), UID (12), track format (14),
        // pack format (11) and a byte of padding.
        var chna = Data()
        chna.u16le(UInt16(tracks.count)); chna.u16le(UInt16(tracks.count))
        for (k, track) in tracks.enumerated() {
            chna.u16le(UInt16(k + 1))
            chna.append(Data(uids[k].utf8)); chna.append(Data(track.utf8)); chna.append(Data(pack.utf8)); chna.append(0)
        }

        func escaped(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let name = escaped(title.isEmpty ? "Jammer" : String(title.prefix(200)))
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ebuCoreMain xmlns="urn:ebu:metadata-schema:ebuCore_2016" xmlns:dc="http://purl.org/dc/elements/1.1/" schema="EBU_CORE_20161025.xsd" xml:lang="en">
          <coreMetadata>
            <format>
              <audioFormatExtended>
                <audioProgramme audioProgrammeID="APR_1001" audioProgrammeName="\(name)">
                  <audioContentIDRef>ACO_1001</audioContentIDRef>
                </audioProgramme>
                <audioContent audioContentID="ACO_1001" audioContentName="\(name)">
                  <audioObjectIDRef>AO_1001</audioObjectIDRef>
                </audioContent>
                <audioObject audioObjectID="AO_1001" audioObjectName="Bed \(layout.rawValue)">
                  <audioPackFormatIDRef>\(pack)</audioPackFormatIDRef>

        """
        for uid in uids { xml += "              <audioTrackUIDRef>\(uid)</audioTrackUIDRef>\n" }
        xml += "            </audioObject>\n"
        for (k, uid) in uids.enumerated() {
            xml += "            <audioTrackUID UID=\"\(uid)\">\n"
            xml += "              <audioTrackFormatIDRef>\(tracks[k])</audioTrackFormatIDRef>\n"
            xml += "              <audioPackFormatIDRef>\(pack)</audioPackFormatIDRef>\n"
            xml += "            </audioTrackUID>\n"
        }
        xml += "          </audioFormatExtended>\n        </format>\n      </coreMetadata>\n    </ebuCoreMain>\n"
        return [("chna", chna), ("axml", Data(xml.utf8))]
    }

    /// The loudspeaker of each channel, from a `chna` chunk's payload, when every channel is named once by a
    /// common-definitions loudspeaker of one of the layouts Jämmer knows; nil otherwise (the file is read as
    /// before, by its mask or its channel count).
    public static func speakers(chna payload: Data, channels: Int) -> [Speaker]? {
        guard payload.count >= 4, channels > 2 else { return nil }
        let b = [UInt8](payload)
        let count = Int(b[0]) | Int(b[1]) << 8
        guard count == channels, b.count >= 4 + 40 * count else { return nil }
        var formats = [UInt8?](repeating: nil, count: channels)
        for e in 0..<count {
            let at = 4 + 40 * e
            let index = Int(b[at]) | Int(b[at + 1]) << 8
            let track = String(decoding: b[at + 14..<at + 28], as: UTF8.self)
            // AT_000100xx_01: a common definitions' loudspeaker (PCM).
            guard (1...channels).contains(index), formats[index - 1] == nil, track.hasPrefix("AT_000100"), track.hasSuffix("_01"),
                  let n = UInt8(track.dropFirst(9).prefix(2), radix: 16) else { return nil }
            formats[index - 1] = n
        }
        // The layout whose loudspeakers these are, each named once.
        for layout in [ChannelLayout.surround51, .surround71, .immersive714] where layout.channels == channels {
            var order: [Speaker] = []
            for f in formats {
                guard let f, let s = layout.speakers.first(where: { channelFormat($0, in: layout) == f }), !order.contains(s) else { break }
                order.append(s)
            }
            if order.count == channels { return order }
        }
        return nil
    }
}
