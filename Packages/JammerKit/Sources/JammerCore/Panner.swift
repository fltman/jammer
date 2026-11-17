import Foundation

/// Where a track's sound is placed in a layout wider than stereo: the direction it comes from and, for a
/// stereo source, how far apart its two sides are. Angles as ITU-R BS.2051-3 gives them: azimuth in
/// degrees, positive to the left (0 is the centre, +90 the left side, ±180 behind); elevation positive up.
public struct SurroundPosition: Codable, Equatable, Hashable, Sendable {
    public var azimuth: Double
    public var elevation: Double
    /// For a stereo source: the angle between its left and right channel, centred on `azimuth`.
    /// The default 60° puts a stereo pair at the centre exactly on L and R (±30°).
    public var width: Double
    public init(azimuth: Double = 0, elevation: Double = 0, width: Double = 60) {
        self.azimuth = azimuth; self.elevation = elevation; self.width = width
    }
    public static let azimuthRange: ClosedRange<Double> = -180...180
    public static let elevationRange: ClosedRange<Double> = 0...90
    public static let widthRange: ClosedRange<Double> = 0...180
    public var isValid: Bool {
        Self.azimuthRange.contains(azimuth) && Self.elevationRange.contains(elevation) && Self.widthRange.contains(width)
    }
}

extension Speaker {
    /// The loudspeaker's nominal direction in a layout (ITU-R BS.2051-3, Tables 1 and 2: M+030, M+000,
    /// M+110 for System B's surrounds, M+090 and M+135 for Systems I and J, U+045 and U+135 at +30° up).
    /// nil for the LFE, which has no direction.
    func direction(in layout: ChannelLayout) -> (azimuth: Double, elevation: Double)? {
        switch self {
        case .frontLeft: (30, 0)
        case .frontRight: (-30, 0)
        case .frontCenter: (0, 0)
        case .lowFrequency: nil
        case .sideLeft: (layout == .surround51 ? 110 : 90, 0)
        case .sideRight: (layout == .surround51 ? -110 : -90, 0)
        case .backLeft: (135, 0)
        case .backRight: (-135, 0)
        case .topFrontLeft: (45, 30)
        case .topFrontRight: (-45, 30)
        case .topBackLeft: (135, 30)
        case .topBackRight: (-135, 30)
        default: nil
        }
    }
}

/// Amplitude panning for layouts wider than stereo: vector base amplitude panning (V. Pulkki, "Virtual sound
/// source positioning using vector base amplitude panning", J. Audio Eng. Soc. 45(6), 1997) between the two
/// loudspeakers of a layer that enclose the direction, the gains scaled to constant power. Where the layout
/// has a height layer, the ear layer and the height layer are each panned so and crossfaded by elevation at
/// constant power, from 0° (ear layer only) to the height layer's 30° (height layer only); above 30° the
/// sound stays in the height layer, which has no loudspeaker overhead. On a loudspeaker's own direction the
/// gain is 1 on that loudspeaker and 0 elsewhere, so the default position plays a mono source in C and a
/// stereo source in L and R exactly.
public enum Panner {
    /// Gains per channel of `layout` for a mono sound from `azimuth`/`elevation`.
    public static func gains(azimuth: Double, elevation: Double, in layout: ChannelLayout) -> [Float] {
        var out = [Float](repeating: 0, count: layout.channels)
        let speakers = layout.speakers
        let ear = speakers.indices.filter { speakers[$0].direction(in: layout).map { $0.elevation == 0 } ?? false }
        let top = speakers.indices.filter { speakers[$0].direction(in: layout).map { $0.elevation > 0 } ?? false }
        let a = azimuth.truncatingRemainder(dividingBy: 360)
        let w = top.isEmpty ? 0 : min(1, max(0, elevation / 30))
        let earShare = cos(w * .pi / 2), topShare = sin(w * .pi / 2)
        if earShare > 1e-9 { for (i, g) in ring(ear, azimuth: a, layout: layout) { out[i] += Float(g * earShare) } }
        if topShare > 1e-9 { for (i, g) in ring(top, azimuth: a, layout: layout) { out[i] += Float(g * topShare) } }
        return out
    }

    /// Pairwise panning on one ring of loudspeakers (indices into the layout), at constant power.
    static func ring(_ indices: [Int], azimuth: Double, layout: ChannelLayout) -> [(Int, Double)] {
        let speakers = layout.speakers
        let ring = indices.map { ($0, speakers[$0].direction(in: layout)!.azimuth) }.sorted { $0.1 < $1.1 }
        guard ring.count > 1 else { return ring.map { ($0.0, 1) } }
        func norm(_ x: Double) -> Double { var y = x.truncatingRemainder(dividingBy: 360); if y < 0 { y += 360 }; return y }
        // The pair whose arc (going left, counter-clockwise) holds the direction.
        for k in 0..<ring.count {
            let (i1, a1) = ring[k], (i2, a2) = ring[(k + 1) % ring.count]
            let span = norm(a2 - a1), off = norm(azimuth - a1)
            guard span > 0, off <= span else { continue }
            if off == 0 { return [(i1, 1)] }
            if off == span { return [(i2, 1)] }
            // VBAP in two dimensions: p = g1·l1 + g2·l2, solved for g, then scaled to g1² + g2² = 1.
            let t = azimuth * .pi / 180, t1 = a1 * .pi / 180, t2 = a2 * .pi / 180
            let det = cos(t1) * sin(t2) - sin(t1) * cos(t2)
            var g1 = (cos(t) * sin(t2) - sin(t) * cos(t2)) / det
            var g2 = (cos(t1) * sin(t) - sin(t1) * cos(t)) / det
            g1 = max(0, g1); g2 = max(0, g2)
            let p = (g1 * g1 + g2 * g2).squareRoot()
            return p > 0 ? [(i1, g1 / p), (i2, g2 / p)] : [(i1, 1)]
        }
        return [(ring[0].0, 1)]
    }

    /// The matrix [source channel][document channel] for a mono or stereo source at a position.
    public static func matrix(_ position: SurroundPosition, sourceChannels: Int, in layout: ChannelLayout) -> [Float] {
        if sourceChannels == 1 { return gains(azimuth: position.azimuth, elevation: position.elevation, in: layout) }
        return gains(azimuth: position.azimuth + position.width / 2, elevation: position.elevation, in: layout)
            + gains(azimuth: position.azimuth - position.width / 2, elevation: position.elevation, in: layout)
    }
}
