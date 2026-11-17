import Foundation
import Testing
@testable import JammerCore

@Suite("Ambisonics: AmbiX encoding")
struct AmbisonicsTests {
    @Test("SN3D: in every direction W is 1 and the squares of each order's components sum to 1 (the normalisation's defining property); ACN order and signs by direction")
    func sn3d() {
        for az in stride(from: -180.0, through: 180, by: 15) {
            for el in stride(from: -90.0, through: 90, by: 15) {
                let y = Ambisonics.encode(azimuth: az, elevation: el, order: 3).map(Double.init)
                #expect(y.count == 16 && abs(y[0] - 1) < 1e-6)
                for n in 1...3 {
                    let sum = (n * n..<(n + 1) * (n + 1)).reduce(0.0) { $0 + y[$1] * y[$1] }
                    #expect(abs(sum - 1) < 1e-6, "order \(n) at \(az)°, \(el)°: \(sum)")
                }
            }
        }
        // First order by direction: ACN 1 is Y (left), 2 is Z (up), 3 is X (front).
        #expect(Ambisonics.encode(azimuth: 0, elevation: 0, order: 1).map { ($0 * 1e6).rounded() / 1e6 } == [1, 0, 0, 1])
        #expect(Ambisonics.encode(azimuth: 90, elevation: 0, order: 1).map { ($0 * 1e6).rounded() / 1e6 } == [1, 1, 0, 0])
        #expect(Ambisonics.encode(azimuth: 0, elevation: 90, order: 1).map { ($0 * 1e6).rounded() / 1e6 } == [1, 0, 1, 0])
        #expect(Ambisonics.encode(azimuth: 0, elevation: 0, order: 2).count == 9)
    }

    @Test("Ambisonics documents: a 4-channel file opens as stereo (nothing says it is a field); set to 1st order it passes through unchanged; a voice is encoded from the front, a placed voice from its place; loudspeakers are encoded by direction without the LFE; a field into loudspeakers is decoded (AllRAD)")
    func documents() throws {
        let dir = TempDir()
        let n = 9_600
        var x = [Float](repeating: 0, count: n * 4)
        for i in 0..<n { for c in 0..<4 { x[i * 4 + c] = Float(sin(Double(i) * 0.01 * Double(c + 1))) * 0.1 } }
        let url = dir.file("field.wav")
        try writeWAV(x, to: url, channels: 4)
        let field = SourceRef(name: "field", path: url.path, info: try AudioFileReader.info(at: url))
        var p = Project(source: field)
        #expect(p.layout == .stereo, "a 4-channel file isn't taken for a sound field")
        p.channels = ChannelLayout.ambix1.channels
        #expect(p.layout == .ambix1 && p.layout.title == "Ambisonics, 1st order")
        let out = PlanCompiler.compile(p, pool: SourcePool()).render(from: 0, frames: n)
        #expect(out == x, "an AmbiX file in a 1st-order document passes through as it is")
        // Encoding.
        let k: Float = 1e-6
        #expect(ChannelLayout.gains(from: .mono, to: .ambix1).enumerated().allSatisfy { abs($0.element - [1, 0, 0, 1][$0.offset]) < k })
        let placed = Panner.matrix(SurroundPosition(azimuth: 90), sourceChannels: 1, in: .ambix1)
        #expect(abs(placed[0] - 1) < k && abs(placed[1] - 1) < k && abs(placed[3]) < k)
        let five = ChannelLayout.gains(from: .surround51, to: .ambix1)
        #expect(five[3 * 4..<4 * 4].allSatisfy { $0 == 0 }, "the LFE isn't encoded")
        #expect(abs(five[2 * 4 + 3] - 1) < k && abs(five[2 * 4 + 1]) < k, "C from the front")
        #expect(ChannelLayout.gains(from: .ambix3, to: .ambix1) == (0..<16).flatMap { r in (0..<4).map { Float(r == $0 ? 1 : 0) } })
        #expect(ChannelLayout.gains(from: .ambix1, to: .surround51) == AmbisonicDecoder.cached(order: 1, to: .surround51), "decoded by AllRAD (block I)")
        // The meter takes only W, and a WAV export of the field is written without loudspeaker positions.
        #expect(LoudnessMeter.channelWeights(4) == [1, 0, 0, 0])
    }
}
