import Foundation
import Synchronization

// Rotation of a sound field and decoding it to loudspeakers (docs/IMMERSIVE.md, block I). Both rest on one
// exact quadrature of the sphere instead of a table of points: Gauss–Legendre nodes in the sine of the
// elevation times equally spaced azimuths, with their weights. A product of spherical harmonics up to the
// grid's degree integrates exactly on it, which is all either needs.

extension Ambisonics {
    /// A grid on the sphere and its weights (summing to 1): `zNodes` Gauss–Legendre nodes in sin(elevation)
    /// times `azimuths` equal steps. Exact for polynomials up to degree min(2·zNodes − 1, azimuths − 1).
    public struct Grid: Sendable {
        public var azimuth: [Double], elevation: [Double], weight: [Double]
        public var count: Int { weight.count }

        public init(zNodes: Int, azimuths: Int) {
            let (x, w) = Ambisonics.gaussLegendre(zNodes)
            azimuth = []; elevation = []; weight = []
            for i in 0..<zNodes {
                for k in 0..<azimuths {
                    azimuth.append(360 * Double(k) / Double(azimuths))
                    elevation.append(asin(x[i]) * 180 / .pi)
                    weight.append(w[i] / 2 / Double(azimuths))
                }
            }
        }
    }

    /// The nodes and weights of Gauss–Legendre quadrature on [−1, 1], by Newton's method on P_n.
    static func gaussLegendre(_ n: Int) -> (nodes: [Double], weights: [Double]) {
        var x = [Double](repeating: 0, count: n), w = x
        for i in 0..<n {
            var z = cos(.pi * (Double(i) + 0.75) / (Double(n) + 0.5)), dp = 0.0
            for _ in 0..<100 {
                var p0 = 1.0, p1 = z
                for k in 2...max(2, n) where n >= 2 { let p2 = ((2 * Double(k) - 1) * z * p1 - (Double(k) - 1) * p0) / Double(k); p0 = p1; p1 = p2 }
                let pn = n == 1 ? z : p1, pm = n == 1 ? 1 : p0
                dp = Double(n) * (z * pn - pm) / (z * z - 1)
                let step = pn / dp
                z -= step
                if abs(step) < 1e-15 { break }
            }
            x[i] = z; w[i] = 2 / ((1 - z * z) * dp * dp)
        }
        return (x, w)
    }

    /// The order of the band a component (ACN) belongs to.
    public static func order(ofComponent acn: Int) -> Int { Int(Double(acn).squareRoot()) }

    /// A direction as a unit vector: x to the front, y to the left, z up.
    static func vector(_ azimuth: Double, _ elevation: Double) -> (Double, Double, Double) {
        let a = azimuth * .pi / 180, e = elevation * .pi / 180
        return (cos(a) * cos(e), sin(a) * cos(e), sin(e))
    }
    static func angles(_ v: (Double, Double, Double)) -> (azimuth: Double, elevation: Double) {
        (atan2(v.1, v.0) * 180 / .pi, asin(max(-1, min(1, v.2))) * 180 / .pi)
    }

    /// The field's rotation as a turn of directions: roll about the front axis (positive lifts the left side),
    /// then pitch about the left axis (positive lifts the front), then yaw about the vertical (positive turns
    /// the front to the left, as an azimuth does). Degrees.
    public static func rotate(_ v: (Double, Double, Double), yaw: Double, pitch: Double, roll: Double) -> (Double, Double, Double) {
        let r = roll * .pi / 180, p = pitch * .pi / 180, y = yaw * .pi / 180
        let a = (v.0, v.1 * cos(r) - v.2 * sin(r), v.1 * sin(r) + v.2 * cos(r))
        let b = (a.0 * cos(p) - a.2 * sin(p), a.1, a.0 * sin(p) + a.2 * cos(p))
        return (b.0 * cos(y) - b.1 * sin(y), b.0 * sin(y) + b.1 * cos(y), b.2)
    }

    /// The rotation of an AmbiX field of `order` (1–3) as a matrix [in component][out component] (row by the
    /// component it takes, as a source matrix is laid out): the field of a source from a direction becomes the
    /// field of the source from the turned direction. Each order's band rotates into itself; worked out by the
    /// quadrature R_n = (2n+1) Σ w Y_n(turned point) Y_n(point)ᵀ, exact for SN3D up to third order.
    public static func rotation(yaw: Double, pitch: Double, roll: Double, order: Int) -> [Float] {
        let n = (order + 1) * (order + 1)
        var m = [Double](repeating: 0, count: n * n)
        let grid = Grid(zNodes: 4, azimuths: 8)
        for p in 0..<grid.count {
            let y0 = encode(azimuth: grid.azimuth[p], elevation: grid.elevation[p], order: order)
            let t = angles(rotate(vector(grid.azimuth[p], grid.elevation[p]), yaw: yaw, pitch: pitch, roll: roll))
            let y1 = encode(azimuth: t.azimuth, elevation: t.elevation, order: order)
            for i in 0..<n {
                let band = Ambisonics.order(ofComponent: i)
                for j in (band * band)..<((band + 1) * (band + 1)) {
                    m[j * n + i] += Double(2 * band + 1) * grid.weight[p] * Double(y1[i]) * Double(y0[j])
                }
            }
        }
        return m.map { Float($0) }
    }
}

/// All-Round Ambisonic Decoding (AllRAD; F. Zotter, M. Frank, "All-Round Ambisonic Panning and Decoding",
/// J. Audio Eng. Soc. 60(10), 2012; as described by E. M. Hoffbauer's thesis at KUG/IEM, 2021, §1.2.3, read at
/// the source): the field is sampled on a dense set of virtual loudspeakers (with max-rE weights), and each
/// virtual loudspeaker is panned onto the real ones by VBAP over the convex hull of the real loudspeakers and
/// imaginary ones that close it (below, and above a layout without heights), whose signals are dropped.
/// Here the virtual set is an exact quadrature grid with its weights rather than a t-design (no table of
/// points); the LFE gets nothing.
public enum AmbisonicDecoder {
    /// Each decoder made once (a few thousand grid points each), for the plan to use as often as it likes.
    private static let made = Mutex<[String: [Float]]>([:])
    public static func cached(order: Int, to layout: ChannelLayout) -> [Float] {
        let key = "\(order) \(layout.rawValue)"
        if let m = made.withLock({ $0[key] }) { return m }
        let m = matrix(order: order, to: layout)
        made.withLock { $0[key] = m }
        return m
    }

    /// max-rE weight of order n for a decoder of order N: P_n(cos(137.9° / (N + 1.51))) (Zotter and Frank's
    /// approximation, as given in the thesis, eq. 1.17).
    public static func maxRE(_ n: Int, order: Int) -> Double { legendre(n, cos(137.9 / (Double(order) + 1.51) * .pi / 180)) }

    static func legendre(_ n: Int, _ x: Double) -> Double {
        var p0 = 1.0, p1 = x
        if n == 0 { return 1 }
        for k in 2...max(2, n) where n >= 2 { let p2 = ((2 * Double(k) - 1) * x * p1 - (Double(k) - 1) * p0) / Double(k); p0 = p1; p1 = p2 }
        return p1
    }

    /// The decoder from an AmbiX field of `order` (1–3) to a loudspeaker `layout` (5.1, 7.1, 7.1.4, or any
    /// with directions), as gains [component][loudspeaker channel]. Its overall level: a source's energy over
    /// all the loudspeakers averages 1 over the sphere.
    public static func matrix(order: Int, to layout: ChannelLayout) -> [Float] {
        let components = (order + 1) * (order + 1), out = layout.channels
        let real: [(channel: Int, v: (Double, Double, Double))] = layout.speakers.enumerated().compactMap { k, s in
            s.direction(in: layout).map { (k, Ambisonics.vector($0.azimuth, $0.elevation)) }
        }
        guard real.count >= 2 else { return [Float](repeating: 0, count: components * out) }
        var points = real.map(\.v)
        // Imaginary loudspeakers close the hull where the layout has none: below always, above without heights.
        if !real.contains(where: { $0.v.2 < -0.05 }) { points.append((0, 0, -1)) }
        if !real.contains(where: { $0.v.2 > 0.05 }) { points.append((0, 0, 1)) }
        let faces = hull(points)
        let grid = Ambisonics.Grid(zNodes: 24, azimuths: 48)
        let weights = (0...order).map { maxRE($0, order: order) }
        var d = [Double](repeating: 0, count: components * out)
        for j in 0..<grid.count {
            let v = Ambisonics.vector(grid.azimuth[j], grid.elevation[j])
            guard let pan = vbap(v, points, faces) else { continue }
            let y = Ambisonics.encode(azimuth: grid.azimuth[j], elevation: grid.elevation[j], order: order)
            for (k, g) in pan where k < real.count && g != 0 {
                let ch = real[k].channel
                for c in 0..<components {
                    let n = Ambisonics.order(ofComponent: c)
                    d[c * out + ch] += grid.weight[j] * g * Double(2 * n + 1) * weights[n] * Double(y[c])
                }
            }
        }
        // Energy averaging 1 over the sphere.
        let check = Ambisonics.Grid(zNodes: 12, azimuths: 24)
        var energy = 0.0
        for j in 0..<check.count {
            let y = Ambisonics.encode(azimuth: check.azimuth[j], elevation: check.elevation[j], order: order)
            for ch in 0..<out {
                var s = 0.0
                for c in 0..<components { s += d[c * out + ch] * Double(y[c]) }
                energy += check.weight[j] * s * s
            }
        }
        let scale = energy > 0 ? 1 / energy.squareRoot() : 0
        return d.map { Float($0 * scale) }
    }

    /// The triangles of the convex hull of unit vectors (each a triple of indices, its normal outward):
    /// every triple whose plane has no point outside it. Coplanar rings (a layout's ear level) are left out as
    /// faces, so the poles' triangles join them.
    static func hull(_ p: [(Double, Double, Double)]) -> [(Int, Int, Int)] {
        func sub(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> (Double, Double, Double) { (a.0 - b.0, a.1 - b.1, a.2 - b.2) }
        func cross(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> (Double, Double, Double) { (a.1 * b.2 - a.2 * b.1, a.2 * b.0 - a.0 * b.2, a.0 * b.1 - a.1 * b.0) }
        func dot(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double { a.0 * b.0 + a.1 * b.1 + a.2 * b.2 }
        var faces: [(Int, Int, Int)] = []
        let n = p.count
        for i in 0..<n { for j in (i + 1)..<n { for k in (j + 1)..<n {
            var normal = cross(sub(p[j], p[i]), sub(p[k], p[i]))
            let len = dot(normal, normal).squareRoot()
            guard len > 1e-9 else { continue }
            normal = (normal.0 / len, normal.1 / len, normal.2 / len)
            let offset = dot(normal, p[i])
            var above = 0, below = 0
            for m in 0..<n where m != i && m != j && m != k {
                let s = dot(normal, p[m]) - offset
                if s > 1e-9 { above += 1 } else if s < -1e-9 { below += 1 }
            }
            if above == 0 && below > 0 { faces.append(offset >= 0 ? (i, j, k) : (i, k, j)) }
            else if below == 0 && above > 0 { faces.append(offset <= 0 ? (i, j, k) : (i, k, j)) }
        } } }
        return faces
    }

    /// VBAP (V. Pulkki, 1997): the triangle the direction falls in and its three gains, normalised to unit
    /// energy. nil if no triangle holds it (it can't happen on a closed hull).
    static func vbap(_ v: (Double, Double, Double), _ p: [(Double, Double, Double)], _ faces: [(Int, Int, Int)]) -> [(Int, Double)]? {
        for (a, b, c) in faces {
            let A = p[a], B = p[b], C = p[c]
            let det = A.0 * (B.1 * C.2 - B.2 * C.1) - A.1 * (B.0 * C.2 - B.2 * C.0) + A.2 * (B.0 * C.1 - B.1 * C.0)
            guard abs(det) > 1e-12 else { continue }
            // Cramer's rule for g in v = gA·A + gB·B + gC·C.
            func det3(_ x: (Double, Double, Double), _ y: (Double, Double, Double), _ z: (Double, Double, Double)) -> Double {
                x.0 * (y.1 * z.2 - y.2 * z.1) - x.1 * (y.0 * z.2 - y.2 * z.0) + x.2 * (y.0 * z.1 - y.1 * z.0)
            }
            let ga = det3(v, B, C) / det, gb = det3(A, v, C) / det, gc = det3(A, B, v) / det
            guard ga >= -1e-9, gb >= -1e-9, gc >= -1e-9 else { continue }
            let norm = (ga * ga + gb * gb + gc * gc).squareRoot()
            guard norm > 0 else { continue }
            return [(a, max(0, ga) / norm), (b, max(0, gb) / norm), (c, max(0, gc) / norm)]
        }
        return nil
    }

    /// The decoder's quality for a source from a direction (Gerzon's energy vector): the energy E over the
    /// loudspeakers, and the energy vector rE's direction and length. A good decoder keeps E nearly level,
    /// points rE at the source and keeps |rE| near the order's best (max-rE's value).
    public static func measure(_ matrix: [Float], order: Int, layout: ChannelLayout, azimuth: Double, elevation: Double)
        -> (energy: Double, errorDegrees: Double, length: Double) {
        let components = (order + 1) * (order + 1), out = layout.channels
        let y = Ambisonics.encode(azimuth: azimuth, elevation: elevation, order: order)
        var e = 0.0, r = (0.0, 0.0, 0.0)
        for (ch, s) in layout.speakers.enumerated() {
            guard let dir = s.direction(in: layout) else { continue }
            var g = 0.0
            for c in 0..<components { g += Double(matrix[c * out + ch]) * Double(y[c]) }
            let u = Ambisonics.vector(dir.azimuth, dir.elevation)
            e += g * g; r = (r.0 + g * g * u.0, r.1 + g * g * u.1, r.2 + g * g * u.2)
        }
        guard e > 0 else { return (0, 180, 0) }
        r = (r.0 / e, r.1 / e, r.2 / e)
        let length = (r.0 * r.0 + r.1 * r.1 + r.2 * r.2).squareRoot()
        let s = Ambisonics.vector(azimuth, elevation)
        let cosine = (r.0 * s.0 + r.1 * s.1 + r.2 * s.2) / max(length, 1e-12)
        return (e, acos(max(-1, min(1, cosine))) * 180 / .pi, length)
    }
}
