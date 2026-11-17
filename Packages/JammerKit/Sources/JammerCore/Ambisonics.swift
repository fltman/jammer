import Foundation

/// Ambisonics in the AmbiX convention (C. Nachbar, F. Zotter, E. Deleflie, A. Sontacchi, "ambiX – A
/// Suggested Ambisonics Format", Ambisonics Symposium 2011): channels in ACN order (ACN = n² + n + m),
/// SN3D normalisation, no Condon-Shortley phase. Azimuth positive to the left, elevation positive up, in
/// degrees, as the rest of Jämmer (ITU-R BS.2051's convention, which is also AmbiX's).
public enum Ambisonics {
    /// The real spherical harmonics up to `order` (at most 3) for a plane wave from a direction: the gains
    /// that encode a mono source there. W (ACN 0) is 1.
    public static func encode(azimuth: Double, elevation: Double, order: Int) -> [Float] {
        let p = azimuth * .pi / 180, t = elevation * .pi / 180
        let cp = cos(p), sp = sin(p), ct = cos(t), st = sin(t)
        var y: [Double] = [1]
        if order >= 1 { y += [sp * ct, st, cp * ct] }
        if order >= 2 {
            let r3 = 3.0.squareRoot()
            y += [r3 / 2 * sin(2 * p) * ct * ct, r3 / 2 * sp * sin(2 * t), 0.5 * (3 * st * st - 1), r3 / 2 * cp * sin(2 * t), r3 / 2 * cos(2 * p) * ct * ct]
        }
        if order >= 3 {
            let a = (5.0 / 8).squareRoot(), b = 15.0.squareRoot() / 2, c = (3.0 / 8).squareRoot()
            y += [a * sin(3 * p) * ct * ct * ct, b * sin(2 * p) * st * ct * ct, c * sp * ct * (5 * st * st - 1), 0.5 * st * (5 * st * st - 3),
                  c * cp * ct * (5 * st * st - 1), b * cos(2 * p) * st * ct * ct, a * cos(3 * p) * ct * ct * ct]
        }
        return y.map(Float.init)
    }
}
