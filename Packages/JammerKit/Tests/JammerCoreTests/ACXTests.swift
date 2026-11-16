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
                     encoded: encoded, encodedBitRate: encoded == nil ? nil : 192_000, encodedSampleRate: encoded == nil ? nil : 44_100, encodedReason: encoded == nil ? "the MP3 couldn't be made (no encoder in this build)" : nil)
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
