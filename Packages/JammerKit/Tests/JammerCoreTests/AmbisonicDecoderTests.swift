import Foundation
import Testing
@testable import JammerCore

@Suite("Ambisonics: rotation and AllRAD decoding")
struct AmbisonicDecoderTests {
    @Test("Measure (printed): the decoders' energy and energy vector over the ear plane and the upper half")
    func measureAll() {
        for layout in [ChannelLayout.surround51, .surround71, .immersive714] {
            for order in 1...3 {
                let m = AmbisonicDecoder.matrix(order: order, to: layout)
                var ear: [(Double, Double, Double)] = [], upper: [(Double, Double, Double)] = []
                for az in stride(from: -180.0, to: 180, by: 5) {
                    let r = AmbisonicDecoder.measure(m, order: order, layout: layout, azimuth: az, elevation: 0)
                    ear.append(r)
                    for el in stride(from: 15.0, through: 60, by: 15) { upper.append(AmbisonicDecoder.measure(m, order: order, layout: layout, azimuth: az, elevation: el)) }
                }
                func db(_ e: Double) -> Double { 10 * log10(e) }
                func line(_ rs: [(Double, Double, Double)]) -> String {
                    String(format: "E %.2f…%.2f dB, rE error max %.1f° mean %.1f°, |rE| %.2f…%.2f",
                           db(rs.map(\.0).min()!), db(rs.map(\.0).max()!), rs.map(\.1).max()!, rs.map(\.1).reduce(0, +) / Double(rs.count), rs.map(\.2).min()!, rs.map(\.2).max()!)
                }
                print("DECODER \(layout.rawValue) order \(order): ear: \(line(ear)); upper: \(line(upper))")
            }
        }
    }

    @Test("Rotation: a rotated field is the field of the turned direction, at every order and in every direction tried; each band stays orthonormal")
    func rotation() {
        for order in 1...3 {
            let n = (order + 1) * (order + 1)
            for (yaw, pitch, roll) in [(30.0, 0.0, 0.0), (0, 25, 0), (0, 0, -40), (120, -35, 70), (-200, 80, 15)] {
                let r = Ambisonics.rotation(yaw: yaw, pitch: pitch, roll: roll, order: order)
                var worst = 0.0
                for az in stride(from: -180.0, to: 180, by: 37) {
                    for el in stride(from: -80.0, through: 80, by: 32) {
                        let y = Ambisonics.encode(azimuth: az, elevation: el, order: order)
                        let t = Ambisonics.angles(Ambisonics.rotate(Ambisonics.vector(az, el), yaw: yaw, pitch: pitch, roll: roll))
                        let want = Ambisonics.encode(azimuth: t.azimuth, elevation: t.elevation, order: order)
                        for o in 0..<n {
                            var got = 0.0
                            for i in 0..<n { got += Double(r[i * n + o]) * Double(y[i]) }
                            worst = max(worst, abs(got - Double(want[o])))
                        }
                    }
                }
                #expect(worst < 1e-5, "order \(order), \((yaw, pitch, roll)): \(worst)")
            }
            // Yaw alone turns each pair (m, −m) by m·yaw: the first order's Y and X components by the yaw itself.
            let r = Ambisonics.rotation(yaw: 90, pitch: 0, roll: 0, order: order)
            #expect(abs(r[3 * n + 1] - 1) < 1e-5 && abs(r[0] - 1) < 1e-5 && abs(r[2 * n + 2] - 1) < 1e-5, "X turns into Y by 90°, W and Z stay")
        }
    }
}
