import CryptoKit
import Foundation
import Testing
@testable import JammerCore

/// Golden renders: each repair is checked against the clean signal it should get
/// back to (quality numbers), and its exact output against a stored checksum so an
/// unintended change shows. `JAMMER_UPDATE_GOLDEN=1` prints new checksums.
@Suite("Restoration")
struct RestorationTests {
    let sr = 48_000.0

    /// Speech-like test signal: a few partials with a slow envelope, deterministic.
    func voice(seconds: Double, seed: UInt64 = 3) -> [Float] {
        let n = Int(sr * seconds)
        var x = seed
        return (0..<n).map { i in
            let t = Double(i) / sr
            let env = 0.5 + 0.5 * sin(2 * .pi * 2.3 * t)
            x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Double(Int32(truncatingIfNeeded: x >> 32)) / 2_147_483_648 * 0.01
            let s = 0.3 * sin(2 * .pi * 220 * t) + 0.15 * sin(2 * .pi * 445 * t) + 0.08 * sin(2 * .pi * 1_310 * t)
            return Float(env * s + noise)
        }
    }

    /// A voice as a voice is made: pitch pulses (110 Hz, a little unsteady) through two resonances,
    /// in words with pauses. Its pulses are sharp, which is what a click detector must not count.
    func pulsedVoice(seconds: Double) -> [Float] {
        let n = Int(sr * seconds)
        var x = [Double](repeating: 0, count: n)
        var at = 0.0, seed: UInt64 = 5
        while Int(at) < n {
            let t = at / sr
            // A word swells and fades over 60 ms; it doesn't start at full strength.
            let w = t.truncatingRemainder(dividingBy: 1.3)
            if w < 0.9 { x[Int(at)] = min(1, min(w, 0.9 - w) / 0.06) }
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            at += sr / 110 * (1 + Double(Int32(truncatingIfNeeded: seed >> 32)) / 2_147_483_648 * 0.02)
        }
        for (f, r) in [(700.0, 0.985), (1_200.0, 0.98)] {
            let c = 2 * r * cos(2 * .pi * f / sr)
            var y1 = 0.0, y2 = 0.0
            for i in 0..<n { let y = x[i] + c * y1 - r * r * y2; y2 = y1; y1 = y; x[i] = y }
        }
        // And the breath every voice has: noise 65 dB under its peaks.
        let peak = x.map(abs).max() ?? 1
        return x.map { v in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(v / peak * 0.5 + Double(Int32(truncatingIfNeeded: seed >> 32)) / 2_147_483_648 * 0.0003)
        }
    }

    @Test("Clicks are counted, a voice's own pulses are not, wherever the stretch starts", arguments: [0, 1_000, 2_000, 3_000])
    func clicksNotPulses(offset: Int) {
        let clean = Array(pulsedVoice(seconds: 12)[offset...])
        // Without the comparison against the block's own peaks, the pulses read as clicks by the hundred.
        let old = Restoration.detectClicks(clean, peaks: 0).count
        #expect(old > 20, "\(old)")
        #expect(Restoration.detectClicks(clean).isEmpty)
        // Ten clicks of one to three samples, each the size of the voice's RMS: all found, nothing else.
        var x = clean
        let level = Float(rms(clean[...]))
        let at = (0..<10).map { 30_011 + $0 * 48_017 }
        for (k, p) in at.enumerated() { for j in 0...(k % 3) { x[p + j] += level * (j % 2 == 0 ? 1 : -1) } }
        let found = Restoration.detectClicks(x)
        #expect(at.allSatisfy { p in found.contains { $0.lowerBound <= p + 3 && $0.upperBound >= p } } && found.count == at.count, "\(found.count) found")
    }

    @Test("Click detection on the test recordings, as a table (calibration, not a check)", .enabled(if: ProcessInfo.processInfo.environment["JAMMER_CLICK_TABLE"] != nil))
    func clickTable() throws {
        for name in ["Kitchen take", "Episode 7", "Daniel", "Flo", "Church hall", "Booth", "Demo song", "interview"] {
            let url = URL(fileURLWithPath: "$JAMMER_TEST_MEDIA/site/\(name).wav")
            guard let info = try? AudioFileReader.info(at: url) else { continue }
            let raw = SourcePool().read(SourceRef(name: name, path: url.path, info: info), from: 0, count: Int(min(info.frames, Int64(info.sampleRate * 30))))
            let ch = info.channels
            let x = (0..<(raw.count / ch)).map { i in (0..<ch).reduce(Float(0)) { $0 + raw[i * ch + $1] } / Float(ch) }
            // Twenty clicks of one to three samples, a second apart, each `amp` times the recording's RMS.
            let rmsX = rms(x[...])
            var row = ""
            for peaks in [0.0, 3, 4, 5, 6] {
                let falseHits = [0, 1_000, 2_000, 3_000].map { Restoration.detectClicks(Array(x[$0...]), peaks: peaks).count }
                var cell = " peaks \(peaks): false \(falseHits)"
                for amp in [1.0, 3, 10] {
                    var y = x
                    let at = (0..<20).map { 30_011 + $0 * 48_017 }.filter { $0 + 3 < y.count }
                    for (k, p) in at.enumerated() { for j in 0...(k % 3) { y[p + j] += Float(amp * rmsX) * (j % 2 == 0 ? 1 : -1) } }
                    let found = Restoration.detectClicks(y, peaks: peaks)
                    let hit = at.filter { p in found.contains { $0.lowerBound <= p + 3 && $0.upperBound >= p } }.count
                    cell += " | ×\(Int(amp)) found \(hit)/\(at.count) of \(found.count)"
                }
                row += "\n   " + cell
            }
            print("CLICKTABLE", name, row)
        }
    }

    /// Words with pauses between them: bursts of the test voice's tones, each 0.6 s with 0.5 s of nothing after.
    func words(seconds: Double) -> [Float] {
        (0..<Int(sr * seconds)).map { i in
            let t = Double(i) / sr, inWord = t.truncatingRemainder(dividingBy: 1.1)
            guard inWord < 0.6 else { return 0 }
            let edge = min(1, min(inWord, 0.6 - inWord) / 0.02)
            return Float(edge * (0.3 * sin(2 * .pi * 220 * t) + 0.15 * sin(2 * .pi * 445 * t) + 0.08 * sin(2 * .pi * 1_310 * t)))
        }
    }

    @Test("The noise floor is the level of the noise that was put there, and nothing is reported where there are no pauses", arguments: [-45.0, -55, -65, -75])
    func noiseFloor(level: Double) {
        let speech = words(seconds: 20)
        var x: UInt64 = 11
        // White noise at a known RMS: uniform in ±a has RMS a/√3.
        let a = pow(10, level / 20) * 3.0.squareRoot()
        let noise = (0..<speech.count).map { _ -> Float in
            x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Double(Int32(truncatingIfNeeded: x >> 32)) / 2_147_483_648 * a)
        }
        #expect(abs(db(rms(noise[...])) - level) < 0.05)
        let floor = Restoration.noiseFloor(zip(speech, noise).map { $0 + $1 }, sampleRate: sr)
        #expect(floor != nil && abs(floor!.level - level) < 1, "\(String(describing: floor)) for \(level)")
        #expect((floor?.seconds ?? 0) > 5)
        // Speech that is silent between its words was gated or edited: there is no room noise to report.
        #expect(Restoration.noiseFloor(speech, sampleRate: sr) == nil)
        // Noise alone, a steady tone, or half a second of anything: nothing to call a pause.
        #expect(Restoration.noiseFloor(noise, sampleRate: sr) == nil)
        #expect(Restoration.noiseFloor((0..<Int(sr * 5)).map { Float(0.3 * sin(2 * .pi * 220 * Double($0) / sr)) }, sampleRate: sr) == nil)
        #expect(Restoration.noiseFloor(Array(zip(speech, noise).map { $0 + $1 }.prefix(Int(sr * 0.5))), sampleRate: sr) == nil)
        // The swaying test voice dips towards its own noise 2.3 times a second, never for long enough
        // to be a pause: measured in those dips the floor would read several dB over.
        #expect(Restoration.noiseFloor(voice(seconds: 10), sampleRate: sr) == nil)
    }

    func rms(_ x: ArraySlice<Float>) -> Double { (x.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, x.count))).squareRoot() }
    func db(_ v: Double) -> Double { 20 * log10(max(v, 1e-12)) }
    func level(_ x: [Float], _ f: Double) -> Double { 10 * log10(max(Restoration.goertzel(x, f, sr), 1e-30)) }

    func checksum(_ x: [Float]) -> String {
        x.withUnsafeBytes { SHA256.hash(data: Data($0)).prefix(8).map { String(format: "%02x", $0) }.joined() }
    }

    func golden(_ name: String, _ x: [Float], _ expected: String) {
        let got = checksum(x)
        if ProcessInfo.processInfo.environment["JAMMER_UPDATE_GOLDEN"] != nil { print("GOLDEN \(name): \(got)") }
        else { #expect(got == expected, "golden render \(name) changed: \(got)") }
    }

    @Test("De-hum finds 50 Hz mains hum and its harmonics and takes them out; the voice stays")
    func dehum() {
        let clean = voice(seconds: 4)
        let hum = (0..<clean.count).map { i -> Float in
            let t = Double(i) / sr
            return Float(0.05 * sin(2 * .pi * 50.02 * t) + 0.03 * sin(2 * .pi * 100.04 * t) + 0.02 * sin(2 * .pi * 150.06 * t))
        }
        let x = zip(clean, hum).map(+)
        let est = Restoration.detectHum(x, sampleRate: sr)
        #expect(est.map { abs($0.frequency - 50) < 0.1 } == true, "\(String(describing: est))")
        #expect(Restoration.detectHum(clean, sampleRate: sr) == nil)
        var f = Restoration.Dehum(frequency: est?.frequency ?? 50, sampleRate: sr)
        let y = f.process(x)
        // After the filters settle (skip 1 s): hum down by at least 30 dB, voice partials within 0.5 dB.
        let tail = Array(y[48_000...]), tailIn = Array(x[48_000...])
        for h in [50.02, 100.04, 150.06] { #expect(level(tailIn, h) - level(tail, h) > 30, "\(h) Hz: \(level(tailIn, h) - level(tail, h)) dB, estimate \(String(describing: est))") }
        for p in [220.0, 445.0, 1_310.0] { #expect(abs(level(tailIn, p) - level(tail, p)) < 0.5, "\(p) Hz") }
        golden("dehum", y, "8810d6533070a7f9")
    }

    @Test("De-clip rebuilds a clipped wave close to the original; amount 0 is bit-exact")
    func declip() {
        let clean = voice(seconds: 1).map { $0 * 2.4 } // peaks around 1.2
        let ceiling: Float = 0.6
        let clipped = clean.map { max(-ceiling, min(ceiling, $0)) }
        let (y, report) = Restoration.declip(clipped)
        #expect(report.runs > 10)
        #expect(abs(report.level - ceiling) < 1e-6)
        // Inside the clipped runs, the error against the true wave drops a lot.
        let runs = Restoration.clippedRuns(clipped).runs
        var before = 0.0, after = 0.0
        for r in runs { for i in r { before += pow(Double(clipped[i] - clean[i]), 2); after += pow(Double(y[i] - clean[i]), 2) } }
        #expect(after < before / 4, "error \(after) vs \(before)")
        // Outside them nothing changes.
        let inside = Set(runs.flatMap { $0 })
        #expect((0..<y.count).allSatisfy { inside.contains($0) || y[$0] == clipped[$0] })
        #expect(Restoration.declip(clipped, amount: 0).output == clipped)
        // Unclipped audio passes untouched.
        #expect(Restoration.declip(voice(seconds: 0.5)).report.runs == 0)
        golden("declip", y, "a6f6d799905b96af")
    }

    @Test("De-click finds every injected click, repairs them, and leaves clean audio alone")
    func declick() {
        let clean = voice(seconds: 2)
        var x = clean
        let positions = [5_000, 21_377, 40_001, 63_210, 80_808]
        for (k, p) in positions.enumerated() {
            for j in 0..<(3 + k) { x[p + j] += (j % 2 == 0 ? 0.6 : -0.5) }
        }
        let (y, report) = Restoration.declick(x)
        for p in positions { #expect(report.clicks.contains { $0.contains(p) }, "missed click at \(p)") }
        #expect(report.clicks.count <= positions.count + 2, "\(report.clicks.count) detections")
        let errBefore = positions.map { rms(zip(x[($0 - 50)..<($0 + 60)], clean[($0 - 50)..<($0 + 60)]).map { $0 - $1 }[...]) }
        let errAfter = positions.map { rms(zip(y[($0 - 50)..<($0 + 60)], clean[($0 - 50)..<($0 + 60)]).map { $0 - $1 }[...]) }
        for (b, a) in zip(errBefore, errAfter) { #expect(db(a) < db(b) - 20, "click error \(db(b)) → \(db(a)) dB") }
        // No false alarms on the clean signal.
        #expect(Restoration.detectClicks(clean).isEmpty)
        #expect(Restoration.declick(x, amount: 0).output == x)
        golden("declick", y, "03846fd38f842cb2")
    }

    @Test("Amount blends between the input and the full repair")
    func amount() {
        let x: [Float] = [0, 1, 2, 3]
        let y: [Float] = [1, 1, 0, 3]
        #expect(Restoration.blend(x, y, 0) == x)
        #expect(Restoration.blend(x, y, 1) == y)
        #expect(Restoration.blend(x, y, 0.5) == [0.5, 1, 1, 3])
    }

    @Test("The solvers: Cholesky and AR fit recover known values")
    func solvers() throws {
        let a: [Double] = [4, 2, 2, 3]
        let x = try #require(Restoration.solve(a, [8, 7], 2))
        #expect(abs(x[0] - 1.25) < 1e-12 && abs(x[1] - 1.5) < 1e-12)
        // A pure AR(2) process: coefficients come back.
        var s: [Float] = [0.1, 0.2]
        for _ in 0..<2_000 { s.append(1.6 * s[s.count - 1] - 0.8 * s[s.count - 2] + Float.random(in: -0.01...0.01)) }
        let c = try #require(Restoration.arCoefficients(s, order: 2, exclude: []))
        #expect(abs(c[0] - 1.6) < 0.05 && abs(c[1] + 0.8) < 0.05)
    }
}
