import Foundation
import Testing
@testable import JammerCore

@Suite("Words nobody knows the time of")
struct UntimedWordTests {
    @Test("The mark follows a word into a bounced file, and the bounce's words can't be cut by either")
    func carried() throws {
        let n = 48_000 * 4
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: Int64(n), chunks: [], bext: nil, ixml: nil, markers: [])
        let a = SourceRef(name: "talk", path: "/dev/null", info: info)
        let pool = SourcePool()
        pool.register(a.id, memory: (0..<n).flatMap { i -> [Float] in let v = Float(0.1 * sin(Double(i) * 0.05)); return [v, v] }, channels: 2)
        var p = Project(source: a)
        let words = ["ett", "två", "tre", "fyra"].enumerated().map { Word(text: $0.element, start: Frame($0.offset * 48_000), end: Frame($0.offset * 48_000 + 40_000), untimed: true) }
        p.setTranscript(SourceTranscript(sourceID: a.id, language: "sv-SE", engine: "openai x", words: words, textOnly: true))
        let media = FileManager.default.temporaryDirectory.appending(path: "jammer-untimed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: media) }
        let echoed = try p.applyingEcho(Echo(delay: 0.3, feedback: 0.3, mix: 0.3), range: 0..<Frame(n), tail: false, pool: pool, media: media)
        // The track now plays a new file; its words are the same four, still marked.
        let placed = echoed.placedWords()
        #expect(placed.map(\.word.text) == ["ett", "två", "tre", "fyra"] && placed.allSatisfy { $0.word.untimed == true })
        #expect(echoed.tracks[0].clips.allSatisfy { $0.sourceID != a.id })
        var cut = echoed
        #expect(throws: TranscriptError.textOnly) { try cut.deleteWords([placed[1].word.id]) }
        #expect(cut == echoed)
        // And through a file: the mark is in the project as saved.
        let again = try JSONDecoder().decode(Project.self, from: try JSONEncoder().encode(echoed))
        #expect(again.placedWords().allSatisfy { $0.word.untimed == true })
        // A word from before the mark existed reads as timed.
        let old = try JSONDecoder().decode(Word.self, from: Data(#"{"id":"\#(UUID().uuidString)","text":"hej","start":0,"end":10}"#.utf8))
        #expect(old.untimed == nil)
    }
}
