import Foundation
import Testing
@testable import JammerAgent
@testable import JammerCore

/// The mark of speech made with a cloned voice (SEND-TO-FLIMMER-API.md, "Cloned voice", 2026-11-19): read from a
/// file's LIST/INFO comment, kept through edits and renders, written into every WAV that contains that audio.
@Suite("Cloned-voice mark")
struct ClonedVoiceMarkTests {
    let line = "Contains speech made with a cloned voice: Anna (ElevenLabs, eleven_v4)."

    func wav(_ comment: String?, seconds: Double = 2) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "jammer-clone-\(UUID().uuidString).wav")
        let w = try WAVWriter(url: url, options: .init(encoding: .float32, channels: 1, sampleRate: 48_000,
                                                      foreignChunks: comment.map { [("LIST", WAVWriter.infoList(comment: $0))] } ?? []))
        try w.write((0..<Int(48_000 * seconds)).map { Float(sin(Double($0) * 0.01)) * 0.3 })
        try w.finish()
        return url
    }

    @Test("Imported with the mark: the source is marked with voice, provider and model; without it, or with another comment, not")
    func importing() throws {
        let marked = try wav(line), plain = try wav(nil), other = try wav("Recorded in the kitchen.")
        defer { for u in [marked, plain, other] { try? FileManager.default.removeItem(at: u) } }
        let s = SourceRef(name: "m", path: marked.path, info: try AudioFileReader.info(at: marked)).synthetic
        #expect(s?.voiceName == "Anna" && s?.provider == "ElevenLabs" && s?.model == "eleven_v4" && s?.label == "Anna (ElevenLabs, eleven_v4)")
        #expect(SourceRef(name: "p", path: plain.path, info: try AudioFileReader.info(at: plain)).synthetic == nil)
        #expect(SourceRef(name: "o", path: other.path, info: try AudioFileReader.info(at: other)).synthetic == nil)
        // Jämmer's own Overdub line counts too, and the Overdub sentence isn't part of the voices.
        #expect(SyntheticSpeech.fromComment("Contains speech made with a cloned voice: Bo (ElevenLabs, eleven_v3). Made by Jammer's Overdub with the voice owner's consent recorded in the project.")?.label == "Bo (ElevenLabs, eleven_v3)")
    }

    @Test("The mark stays after a cut and in a mix, said as the file said it (no Overdub sentence for another app's speech)")
    func throughEdits() throws {
        let marked = try wav(line), plain = try wav(nil)
        defer { for u in [marked, plain] { try? FileManager.default.removeItem(at: u) } }
        let a = SourceRef(name: "voice", path: marked.path, info: try AudioFileReader.info(at: marked))
        let b = SourceRef(name: "music", path: plain.path, info: try AudioFileReader.info(at: plain))
        var p = Project(source: a)
        _ = p.addTrack(source: b, name: "Music")
        #expect(p.syntheticNote(in: 0..<p.length) == line)
        p.split(at: 48_000)
        #expect(p.syntheticNote(in: 0..<p.length) == line && p.syntheticNote(in: 48_000..<96_000) == line)
        // Only the music's stretch of a mix without the voice: no mark.
        var q = p
        q.tracks[0].clips = []
        #expect(q.syntheticNote(in: 0..<q.length) == nil)
    }

    @Test("A file rendered from the track (a repair, a bounce) takes the mark of what the track played there before")
    func inheritance() throws {
        let marked = try wav(line), rendered = try wav(nil)
        defer { for u in [marked, rendered] { try? FileManager.default.removeItem(at: u) } }
        let a = SourceRef(name: "voice", path: marked.path, info: try AudioFileReader.info(at: marked))
        let before = Project(source: a)
        var after = before
        let r = SourceRef(name: "voice (denoise)", path: rendered.path, info: try AudioFileReader.info(at: rendered))
        after.sources.append(r)
        after.tracks[0].clips[0].sourceID = r.id
        #expect(after.syntheticNote(in: 0..<after.length) == nil)
        after.inheritSyntheticMarks(from: before)
        #expect(after.syntheticNote(in: 0..<after.length) == line)
    }

    @Test("What goes to Flimmer carries the line in LIST/INFO, and Jämmer reads it back the same (a round trip)")
    func toFlimmer() throws {
        let marked = try wav(line)
        defer { try? FileManager.default.removeItem(at: marked) }
        let a = SourceRef(name: "voice", path: marked.path, info: try AudioFileReader.info(at: marked))
        let p = Project(source: a)
        let pool = SourcePool()
        let scratch = FileManager.default.temporaryDirectory.appending(path: "jammer-clone-send-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let out = try FlimmerSend.wavFile(PlanCompiler.compile(p, pool: pool), range: 0..<p.length, bitDepth: 24, sampleRate: 48_000,
                                          comment: p.syntheticNote(in: 0..<p.length), scratch: scratch)
        let back = try AudioFileReader.info(at: out.file)
        #expect(back.comment == line)
        #expect(SourceRef(name: "back", path: out.file.path, info: back).synthetic?.label == "Anna (ElevenLabs, eleven_v4)")
    }
}
