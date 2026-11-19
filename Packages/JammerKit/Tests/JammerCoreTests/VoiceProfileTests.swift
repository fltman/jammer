import Foundation
import Testing
@testable import JammerCore

@Suite("Voice profiles: matching and splitting speakers")
struct VoiceProfileTests {
    func v(_ xs: [Float]) -> [Float] { xs }

    @Test("Each profile names at most one speaker, by the best total likeness; a name the user set is never replaced; below the threshold nothing")
    func matching() {
        let anna = VoiceMatch.Profile(id: UUID(), name: "Anna", print: v([1, 0, 0]))
        let erik = VoiceMatch.Profile(id: UUID(), name: "Erik", print: v([0, 1, 0]))
        // Speaker 0 is most like Anna, speaker 1 a little like Anna too but more like Erik.
        var r = VoiceMatch.assign(prints: [0: v([1, 0.1, 0]), 1: v([0.7, 0.72, 0])], profiles: [anna, erik])
        #expect(r.matches[0]?.name == "Anna" && r.matches[1]?.name == "Erik")
        // Two speakers both like Anna: the better one gets her, the other keeps its name and has her as an alternative.
        r = VoiceMatch.assign(prints: [0: v([1, 0.05, 0]), 1: v([1, 0.3, 0])], profiles: [anna])
        #expect(r.matches[0]?.name == "Anna" && r.matches[1] == nil && r.alternatives[1]?.name == "Anna")
        // The best total, not the best first: 0 is a bit more like Anna than 1, but 1 has nobody else.
        r = VoiceMatch.assign(prints: [0: v([0.9, 0.85, 0]), 1: v([0.8, 0.1, 0])], profiles: [anna, erik])
        #expect(r.matches[0]?.name == "Erik" && r.matches[1]?.name == "Anna")
        // A name the user set is left alone; under the threshold, no name.
        #expect(VoiceMatch.assign(prints: [0: v([1, 0, 0])], profiles: [anna], protected: [0]).matches.isEmpty)
        #expect(VoiceMatch.assign(prints: [0: v([0.5, 0, 1])], profiles: [anna]).matches.isEmpty)
        #expect(VoiceMatch.isGiven("Speaker 3") && !VoiceMatch.isGiven("Anna") && !VoiceMatch.isGiven("Speaker 3 (guest)"))
    }

    /// One track, one 10 s source; Anna 0–3 s and 6–8 s, Erik 2.5–5 s (overlapping Anna by 0.5 s); pauses between.
    func twoSpeakers() -> (Project, SourcePool) {
        let sr = 48_000, n = sr * 10
        let x = (0..<(n * 2)).map { Float(sin(Double($0) * 0.001)) * 0.5 }
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: Double(sr),
                                 channelMask: nil, dataOffset: 0, frames: Int64(n), chunks: [], bext: nil, ixml: nil, markers: [])
        let ref = SourceRef(name: "talk", path: "/dev/null", info: info)
        let pool = SourcePool()
        pool.register(ref.id, memory: x, channels: 2)
        var p = Project(source: ref)
        p.tracks[0].gainDB = -2
        p.speakers = ["Anna", "Erik"]
        let f = { (s: Double) in Frame(s * Double(sr)) }
        p.speakerTurns = [SourceSpeakers(sourceID: ref.id, engine: "t", turns: [
            SpeakerTurn(speaker: 0, start: f(0), end: f(3)), SpeakerTurn(speaker: 1, start: f(2.5), end: f(5)), SpeakerTurn(speaker: 0, start: f(6), end: f(8))])]
        return (p, pool)
    }

    @Test("Split speakers: one track each, and together they play exactly the original (null); the original muted and kept")
    func split() throws {
        let (p, pool) = twoSpeakers()
        var q = p
        let ids = try q.splitSpeakers(track: p.tracks[0].id)
        #expect(ids.count == 2 && q.tracks.count == 3 && q.tracks[0].isMuted && q.tracks[1].name == "Anna" && q.tracks[2].name == "Erik")
        #expect(q.tracks[1].gainDB == -2 && q.tracks[2].gainDB == -2)
        let n = Int(p.length)
        let before = PlanCompiler.compile(p, pool: pool).render(from: 0, frames: n)
        let after = PlanCompiler.compile(q, pool: pool).render(from: 0, frames: n)
        #expect(before == after, "the split tracks together must null against the original")
        // Who got what: the overlap (2.5–3 s) to Anna, whose turn (3 s) is longer than Erik's (2.5 s); the pause
        // 5–6 s split at 5.5 s; after the last turn, to its speaker.
        let s = 48_000.0
        func has(_ t: Int, _ at: Double) -> Bool { q.tracks[t].clips.contains { $0.range.contains(Frame(at * s)) } }
        #expect(has(1, 2.75) && !has(2, 2.75) && has(2, 4) && has(2, 5.4) && has(1, 5.6) && has(1, 9.5))
        // Without keeping the original.
        var r = p
        try r.splitSpeakers(track: p.tracks[0].id, keepOriginal: false)
        #expect(r.tracks.count == 2 && PlanCompiler.compile(r, pool: pool).render(from: 0, frames: n) == before)
    }

    @Test("Split speakers refuses a track without speakers, or with only one, in words")
    func refusals() {
        var (p, _) = twoSpeakers()
        p.speakerTurns = []
        #expect(throws: SplitSpeakersError.noSpeakers("talk")) { try p.splitSpeakers(track: p.tracks[0].id) }
        var (q, _) = twoSpeakers()
        q.speakerTurns[0].turns = q.speakerTurns[0].turns.filter { $0.speaker == 0 }
        #expect(throws: SplitSpeakersError.oneSpeaker("talk")) { try q.splitSpeakers(track: q.tracks[0].id) }
    }

    @Test("A document keeps only that a name came from a profile, and how alike; it reads back, and an older file without it opens")
    func suggestionsInTheFile() throws {
        var (p, _) = twoSpeakers()
        p.speakerSuggestions = [SpeakerSuggestion(speaker: 0, score: 0.71)]
        let data = try JSONEncoder().encode(p)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("speakerSuggestions") && !text.lowercased().contains("print"))
        #expect(try JSONDecoder().decode(Project.self, from: data).speakerSuggestions == p.speakerSuggestions)
        p.speakerSuggestions = []
        #expect(!String(decoding: try JSONEncoder().encode(p), as: UTF8.self).contains("speakerSuggestions"))
    }
}
