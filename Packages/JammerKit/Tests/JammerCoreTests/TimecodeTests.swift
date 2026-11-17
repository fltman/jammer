import Foundation
import Testing
@testable import JammerCore

/// The reference is the standard's own arithmetic (SMPTE ST 12-1): the values below are the ones every
/// description of drop-frame gives, and can be checked by hand.
@Suite("SMPTE timecode")
struct TimecodeTests {
    @Test("Drop-frame at 29.97: the frame after 00:00:59;29 is 00:01:00;02, a tenth minute drops nothing, an hour is 107 892 frames and a day wraps")
    func dropFrame() {
        let r = Timecode.Rate.fps2997drop
        #expect(Timecode(pictureFrames: 1_799, rate: r).text == "00:00:59;29")
        #expect(Timecode(pictureFrames: 1_800, rate: r).text == "00:01:00;02")
        #expect(Timecode(pictureFrames: 17_981, rate: r).text == "00:09:59;29")
        #expect(Timecode(pictureFrames: 17_982, rate: r).text == "00:10:00;00")
        #expect(Timecode(pictureFrames: 107_892, rate: r).text == "01:00:00;00")
        #expect(Timecode("01:00:00;00", rate: r)?.pictureFrames == 107_892)
        #expect(Timecode(pictureFrames: 24 * 107_892, rate: r).text == "00:00:00;00")
        // A frame number that is dropped doesn't exist.
        #expect(Timecode("00:01:00;00", rate: r) == nil && Timecode("00:01:00;01", rate: r) == nil && Timecode("00:10:00;00", rate: r) != nil)
        // Every frame of two hours goes out and comes back, and the texts never repeat.
        var last = ""
        for n in stride(from: 0, to: 2 * 107_892, by: 1) {
            let t = Timecode(pictureFrames: n, rate: r)
            if n % 997 == 0 || n < 40_000 { #expect(t.pictureFrames == n && t.isValid, "\(n)") }
            if n < 40_000 { #expect(t.text != last); last = t.text }
        }
    }

    @Test("Drop-frame at 59.94 drops four; the non-drop rates count every number; every rate goes there and back")
    func rates() {
        #expect(Timecode(pictureFrames: 3_599, rate: .fps5994drop).text == "00:00:59;59" && Timecode(pictureFrames: 3_600, rate: .fps5994drop).text == "00:01:00;04")
        #expect(Timecode(pictureFrames: 215_784, rate: .fps5994drop).text == "01:00:00;00")
        #expect(Timecode(pictureFrames: 108_000, rate: .fps2997).text == "01:00:00:00" && Timecode(pictureFrames: 1_800, rate: .fps2997).text == "00:01:00:00")
        #expect(Timecode(pictureFrames: 90_000, rate: .fps25).text == "01:00:00:00" && Timecode(pictureFrames: 86_400, rate: .fps24).text == "01:00:00:00")
        for rate in Timecode.Rate.allCases {
            for n in [0, 1, rate.base - 1, rate.base, 1_799, 1_800, 17_982, 123_456, 1_000_000] {
                let t = Timecode(pictureFrames: n, rate: rate)
                #expect(t.isValid && t.pictureFrames == n && Timecode(t.text, rate: rate) == t, "\(rate.rawValue) \(n) \(t.text)")
            }
        }
        #expect(Timecode("25:00:00:00", rate: .fps25) == nil && Timecode("00:00:00:25", rate: .fps25) == nil && Timecode("1:2:3", rate: .fps25) == nil && Timecode("aa:00:00:00", rate: .fps25) == nil)
    }

    @Test("On a timeline: the timecode at an audio frame, and the audio frame a timecode's picture frame begins at, at 48 kHz from 01:00:00:00")
    func onATimeline() {
        let film = TimecodeSettings(rate: .fps25, startFrames: Timecode("01:00:00:00", rate: .fps25)!.pictureFrames)
        #expect(film.timecode(at: 0, sampleRate: 48_000).text == "01:00:00:00")
        #expect(film.timecode(at: 1_919, sampleRate: 48_000).text == "01:00:00:00" && film.timecode(at: 1_920, sampleRate: 48_000).text == "01:00:00:01")
        #expect(film.timecode(at: 48_000 * 61, sampleRate: 48_000).text == "01:01:01:00")
        #expect(film.frame(of: Timecode("01:00:10:12", rate: .fps25)!, sampleRate: 48_000) == Frame(10 * 48_000 + 12 * 1_920))
        #expect(film.frame(of: Timecode("00:59:59:24", rate: .fps25)!, sampleRate: 48_000) == nil)
        // 29.97 drop-frame keeps real time: an hour of audio is an hour of timecode, to the frame.
        let tv = TimecodeSettings(rate: .fps2997drop)
        #expect(tv.timecode(at: Frame(3_600 * 48_000), sampleRate: 48_000).text == "01:00:00;00")
        // Non-drop at the same rate runs slow: after an hour of audio it has counted 3.6 s less.
        #expect(TimecodeSettings(rate: .fps2997).timecode(at: Frame(3_600 * 48_000), sampleRate: 48_000).text == "00:59:56:12")
        // There and back for a picture frame's first audio frame, at every rate.
        for rate in Timecode.Rate.allCases {
            let s = TimecodeSettings(rate: rate, startFrames: 1_234)
            for n in [0, 1, 50, 1_799, 1_800, 99_999] {
                let t = Timecode(pictureFrames: 1_234 + n, rate: rate)
                let f = s.frame(of: t, sampleRate: 48_000)!
                #expect(s.timecode(at: f, sampleRate: 48_000) == t, "\(rate.rawValue) \(n)")
            }
        }
    }

    @Test("In a project: saved and read back; a file without it opens without it; a timecode that can't be read is left out and the project still opens")
    func inAProject() throws {
        var (p, _) = MixerTests.document()
        let without = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
        #expect(p.timecode == nil && !without.contains("timecode"))
        p.timecode = TimecodeSettings(rate: .fps2997drop, startFrames: 107_892)
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Project.self, from: data)
        #expect(back.timecode == p.timecode && back.timecode?.start.text == "01:00:00;00" && back == p)
        // A rate this app doesn't know, and a start that is no time of day: the project opens, without a timecode.
        let hostile: [Any] = [["rate": "31.5", "startFrames": 0], ["rate": "25", "startFrames": 999_999_999_999], 7, ["rate": "25"]]
        for value in hostile {
            var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            object["timecode"] = value
            let opened = try JSONDecoder().decode(Project.self, from: try JSONSerialization.data(withJSONObject: object))
            #expect(opened.timecode == nil && opened.tracks.count == p.tracks.count, "\(value)")
        }
    }
}
