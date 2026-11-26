import Foundation
import Testing
@testable import JammerCore

@Suite("Measured against ACX's published requirements")
struct ACXTests {
    func result(rms: Double?, sample: Double, truePeak: Double) -> LoudnessResult {
        LoudnessResult(integrated: -20, range: 5, maxMomentary: nil, maxShortTerm: nil, samplePeak: sample, truePeak: truePeak, duration: 600, rms: rms)
    }
    func measured(_ mix: LoudnessResult, encoded: LoudnessResult? = nil, rate: Double = 44_100, floor: Double? = -65, head: Double = 1.2, tail: Double = 3) -> ACX.Measured {
        ACX.Measured(mix: mix, noiseFloor: floor, noiseSeconds: 12, channels: 1, sampleRate: rate, seconds: 600, head: head, tail: tail,
                     encoded: encoded, encodedBitRate: encoded == nil ? nil : 192_000, encodedSampleRate: encoded == nil ? nil : 44_100, encodedReason: encoded == nil ? Said("acx.on.notMade", "the MP3 couldn't be made (%@)", inner: Said("error.said", "%@", "no encoder in this build")) : nil)
    }
    func row(_ rows: [DeliveryRequirement], _ name: String) -> DeliveryRequirement { rows.first { $0.name == name }! }

    @Test("A file that meets every measured requirement, judged on the MP3 as it decodes")
    func passes() {
        let rows = ACX.requirements(measured(result(rms: -20.4, sample: -3.6, truePeak: -3.4), encoded: result(rms: -20.5, sample: -3.5, truePeak: -3.1)))
        #expect(rows.map(\.name) == ["rms", "peak", "noiseFloor", "format", "channels", "length", "roomTone", "narration"])
        for n in ["rms", "peak", "noiseFloor", "format", "length", "roomTone"] { #expect(row(rows, n).pass == true, "\(n)") }
        #expect(row(rows, "channels").pass == nil && row(rows, "narration").pass == nil)
        #expect(row(rows, "rms").measured == "-20.5 dB" && row(rows, "rms").note?.contains("the MP3 as it decodes") == true)
        #expect(row(rows, "format").measured == "MP3, 192 kbps constant bit rate, 44.1 kHz")
        // ACX's own numbers, as read: nothing here came from memory.
        #expect(ACX.rmsRange == -23.0 ... -18.0 && ACX.peakMax == -3 && ACX.noiseFloorMax == -60 && ACX.minBitRate == 192_000 && ACX.sampleRate == 44_100
                && ACX.maxSeconds == 7_200 && ACX.roomToneMax == 5 && ACX.readOn == "2026-11-16" && ACX.source.hasPrefix("https://help.acx.com/"))
        #expect(ACX.wording.contains("Measured against ACX's published requirements") && !ACX.wording.lowercased().contains("approved by"))
    }

    @Test("The peak: the sample peak passing is not enough when the true peak is over, and the answer says which decided")
    func peak() {
        // The mix passes; encoding lifted the peaks between the samples over −3.
        let rows = ACX.requirements(measured(result(rms: -20, sample: -3.4, truePeak: -3.2), encoded: result(rms: -20, sample: -3.1, truePeak: -2.6)))
        let p = row(rows, "peak")
        #expect(p.pass == false && p.measured == "sample peak -3.1 dB, true peak -2.6 dB" && p.note?.contains("the true peak (between the samples) is over −3, and that decided it") == true)
        #expect(row(ACX.requirements(measured(result(rms: -20, sample: -2, truePeak: -1.9))), "peak").note?.contains("The sample peak is over −3") == true)
        // Exactly −3 is "no higher than −3".
        #expect(row(ACX.requirements(measured(result(rms: -20, sample: -3, truePeak: -3), encoded: result(rms: -20, sample: -3, truePeak: -3))), "peak").pass == true)
    }

    @Test("Each requirement fails on its own figure; what can't be measured is said, not passed")
    func failures() {
        let ok = result(rms: -20, sample: -4, truePeak: -4)
        #expect(row(ACX.requirements(measured(result(rms: -17.4, sample: -4, truePeak: -4), encoded: result(rms: -17.4, sample: -4, truePeak: -4))), "rms").pass == false)
        #expect(row(ACX.requirements(measured(result(rms: -23.6, sample: -4, truePeak: -4))), "rms").pass == false)
        #expect(row(ACX.requirements(measured(result(rms: nil, sample: -200, truePeak: -200))), "rms").pass == false)
        #expect(row(ACX.requirements(measured(ok, encoded: ok, floor: -52)), "noiseFloor").pass == false)
        let noPause = row(ACX.requirements(measured(ok, encoded: ok, floor: nil)), "noiseFloor")
        #expect(noPause.pass == nil && noPause.measured == "no pause found to measure it in")
        // No MP3 could be made: the format fails and says why, and the rest is judged on the mix.
        let at48 = ACX.requirements(measured(ok, rate: 48_000))
        #expect(row(at48, "format").pass == false && row(at48, "format").note?.contains("couldn't be made") == true && row(at48, "rms").note?.contains("the mix before encoding") == true)
        // A 48 kHz document converted to 44.1 kHz for the MP3: the format is met, and the note says it is converted.
        let converted = row(ACX.requirements(measured(ok, encoded: ok, rate: 48_000)), "format")
        #expect(converted.pass == true && converted.measured == "MP3, 192 kbps constant bit rate, 44.1 kHz" && converted.note?.contains("the document is 48.0 kHz and is converted") == true)
        #expect(row(ACX.requirements(measured(ok, encoded: ok, head: 6.5)), "roomTone").pass == false)
        #expect(row(ACX.requirements(measured(ok, encoded: ok, head: 0.2)), "roomTone").note?.contains("Under the recommended 1 second at the start") == true)
        var long = measured(ok, encoded: ok)
        long.seconds = 7_260
        #expect(row(ACX.requirements(long), "length").pass == false)
        // The answer as JSON: pass is true, false or null.
        let json = row(at48, "channels").json
        #expect(json["pass"] is NSNull && json["required"] as? String == "All files must be in the same channel format (all mono or all stereo)")
    }
}

@Suite("Matching ACX's loudness and peaks")
struct ACXMatchTests {
    static let n = 48_000 * 6
    /// A mono tone of `amp` (its RMS is 20·log10(amp/√2)), and, with `bursts`, 5 ms at 0.79 (−2 dBFS) each second.
    static func document(amp: Double, bursts: Bool = false) -> (Project, SourcePool) {
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 1, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: Int64(n), chunks: [], bext: nil, ixml: nil, markers: [])
        let a = SourceRef(name: "narration", path: "/dev/null", info: info)
        let pool = SourcePool()
        pool.register(a.id, memory: (0..<n).map { i in
            let level = bursts && i % 48_000 < 240 ? 0.79 : amp
            return Float(level * sin(Double(i) * 0.13))
        }, channels: 1)
        return (Project(source: a), pool)
    }
    static func measure(_ pool: SourcePool) -> (Project, Range<Frame>) -> LoudnessResult {
        { p, r in LoudnessMeter.measure(PlanCompiler.compile(p, pool: pool), r) }
    }
    func folder() -> URL { FileManager.default.temporaryDirectory.appending(path: "jammer-acx-\(UUID().uuidString)") }

    @Test("A file already within ACX's loudness and peaks is left exactly as it is, and says so")
    func alreadyWithin() throws {
        let (p, pool) = Self.document(amp: 0.1414)   // RMS −20, peak −17
        let (q, m) = try #require(try p.matchingACX(range: 0..<p.length, noiseFloorBefore: -70, pool: pool, media: folder(), measure: Self.measure(pool)))
        #expect(m.unchanged && q == p && m.gainDB == 0 && m.noiseFloorAfter == -70 && !m.noiseFloorTooHigh)
    }

    @Test("Too quiet with room for it: one gain to −20 RMS, no limiter, the peaks under −3; the noise floor rises with it and is said when it passes −60")
    func gainAlone() throws {
        let (p, pool) = Self.document(amp: 0.0447)   // RMS −30, peak −27
        let (q, m) = try #require(try p.matchingACX(range: 0..<p.length, noiseFloorBefore: -65, pool: pool, media: folder(), measure: Self.measure(pool)))
        #expect(!m.unchanged && !m.limited && abs(m.gainDB - 10) < 0.05, "gain \(m.gainDB)")
        let after = Self.measure(pool)(q, 0..<q.length)
        #expect(ACX.within(after) && abs((after.rms ?? 0) - -20) < 0.1)
        #expect(abs((m.noiseFloorAfter ?? 0) - -55) < 0.05 && m.noiseFloorTooHigh, "the floor isn't touched, only said: −65 + 10")
    }

    @Test("Peaks in the way: the limiter holds them at −3.5 dBTP and the gain makes up what it takes; the RMS lands in −23…−18")
    func withTheLimiter() throws {
        let (p, pool) = Self.document(amp: 0.05, bursts: true)   // RMS about −29, peaks −2
        let media = folder()
        defer { try? FileManager.default.removeItem(at: media) }
        let (q, m) = try #require(try p.matchingACX(range: 0..<p.length, noiseFloorBefore: nil, pool: pool, media: media, measure: Self.measure(pool)))
        #expect(m.limited && m.reductionMaxDB > 0)
        let after = Self.measure(pool)(q, 0..<q.length)
        #expect(ACX.within(after), "RMS \(after.rms ?? 0), sample \(after.samplePeak), true \(after.truePeak)")
        #expect(after.truePeak <= -3.4 && m.noiseFloorAfter == nil)
        // Without the app's rendering it says so, instead of going over the peaks.
        #expect(throws: ACXMatchError.needsRender) { try p.matchingACX(range: 0..<p.length, noiseFloorBefore: nil, pool: nil, media: nil, measure: Self.measure(pool)) }
    }
}
