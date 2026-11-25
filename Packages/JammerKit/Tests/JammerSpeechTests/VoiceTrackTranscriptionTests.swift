import Foundation
import JammerCore
import Testing
@testable import JammerSpeech

@Suite("Voice track transcription")
struct VoiceTrackTranscriptionTests {
    func result(_ text: String, language: String, at seconds: Double) -> VoiceTrackTranscription.Result {
        let rate = 48_000.0
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 1, sampleRate: rate, dataOffset: 0, frames: 480_000)
        let source = SourceRef(name: "Input", path: "", info: info)
        let track = Track(name: "Voice", clips: [Clip(sourceID: source.id, start: Frame(seconds * rate), length: 480_000)])
        let project = Project(sampleRate: rate, channels: 1, tracks: [track], sources: [source])
        let words = text.split(separator: " ").enumerated().map { index, text in
            Word(text: String(text), start: Frame(index * 4_800), end: Frame((index + 1) * 4_800))
        }
        return .init(track: TrackSpeech(project: project, index: 0, turns: []),
                     transcript: SourceTranscript(sourceID: source.id, language: language, engine: "test", words: words))
    }

    @Test func namedFromIntroductionsAndHandoffs() {
        let chair = result("Hej! Jag heter Anders. Jag jobbar som mötesordförande.", language: "sv", at: 0)
        let safety = result("Hej. Jeg hedder Anders. Jeg arbejder som sikkerhedschef.", language: "da", at: 2)
        let english = result("My name is Beth. Our next speaker is Anders. He works as a biscuit inspector.", language: "en", at: 4)
        let guest = result("Tusen takk. Det er veldig hyggelig å være her sammen med dere.", language: "nb", at: 6)
        let names = VoiceTrackTranscription.names(for: [guest, safety, chair, english], sampleRate: 48_000)
        #expect(names[chair.track.track.id] == "Anders (mötesordförande)")
        #expect(names[safety.track.track.id] == "Anders (sikkerhedschef)")
        #expect(names[guest.track.track.id] == "Anders (biscuit inspector)")
        #expect(names[english.track.track.id] == "Beth")
    }

    func named(_ text: String, _ language: String) -> String? {
        let words = text.split(separator: " ").enumerated().map { i, t in Word(text: String(t), start: Frame(i * 4_800), end: Frame((i + 1) * 4_800)) }
        return VoiceTrackTranscription.introducedName(words, language: language)
    }

    @Test("Introductions as people say them: I'm, I am, my name's, this is after a greeting, jag är, after a greeting and a comma")
    func everydayIntroductions() {
        #expect(named("Hi, I'm Sarah.", "en") == "Sarah")
        #expect(named("I am Thomas.", "en") == "Thomas")
        #expect(named("Hello there, my name's Lucy.", "en") == "Lucy")
        #expect(named("Good morning, I'm Olivia from the newsroom.", "en") == "Olivia")
        #expect(named("Hi everyone. This is Lucy.", "en") == "Lucy")
        #expect(named("- Hello, I am Olivia and I work as a teacher.", "en") == "Olivia")
        #expect(named("Hej, jag är Karin.", "sv") == "Karin")
        #expect(named("Jag är Lars och jobbar som lärare.", "sv") == "Lars")
        #expect(named("Hej allihop, det här är Johan.", "sv") == "Johan")
        #expect(named("God morgon, jag heter Maria och kommer från Göteborg.", "sv") == "Maria")
        #expect(named("Hej och välkommen, jag är Henrik!", "sv") == "Henrik")
        // A track whose language wasn't made out is read in every language that has phrases.
        #expect(named("Hello there, my name is Emma.", "und") == "Emma")
    }

    @Test("No name from what only sounds like one: a nationality, a place after this is, a name inside a sentence")
    func notIntroductions() {
        for line in ["I'm happy to be here today.", "I'm British and I live in London.", "This is London calling.",
                     "I am sure that Daniel will join us later.", "He said that my name is Bond.", "I'm Swedish."] {
            #expect(named(line, "en") == nil, "\(line)")
        }
        for line in ["Jag är glad att vara här.", "Jag är från Stockholm.", "Det här är Sverige.", "Jag tror att Erik kommer senare."] {
            #expect(named(line, "sv") == nil, "\(line)")
        }
        #expect(named("Hi, I'm Anna. I'm Swedish.", "en") == "Anna")
    }

    @Test("Export of the selection: only its words, their times from its start")
    func exportSelection() throws {
        let rate = 48_000.0
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 1, sampleRate: rate, dataOffset: 0, frames: 480_000)
        let source = SourceRef(name: "Input", path: "", info: info)
        let track = Track(name: "Voice", clips: [Clip(sourceID: source.id, start: 0, length: 480_000)])
        var project = Project(sampleRate: rate, channels: 1, tracks: [track], sources: [source])
        // One word a second: w0 at 0–0.5 s, w1 at 1–1.5 s …
        let words = (0..<8).map { i in Word(text: "w\(i)", start: Frame(Double(i) * rate), end: Frame((Double(i) + 0.5) * rate)) }
        project.transcripts = [SourceTranscript(sourceID: source.id, language: "en", engine: "test", words: words)]
        let range = Frame(2 * rate)..<Frame(4.2 * rate)
        let txt = String(decoding: try TranscriptExport.txt.data(project: project, range: range), as: UTF8.self)
        #expect(txt == "w2 w3 w4\n")
        let srt = String(decoding: try TranscriptExport.srt.data(project: project, range: range), as: UTF8.self)
        #expect(srt.hasPrefix("1\n00:00:00,000 --> "))
        let all = String(decoding: try TranscriptExport.txt.data(project: project), as: UTF8.self)
        // TXT breaks a line where a subtitle cue would end (at most 5 s).
        #expect(all == "w0 w1 w2 w3 w4\nw5 w6 w7\n")
        #expect(throws: TranscriptExport.Failure.noWords) { try TranscriptExport.txt.data(project: project, range: Frame(9 * rate)..<Frame(9.5 * rate)) }
    }

    @Test func noGuessFromConflictingNamesOrDistantHandoff() {
        let host = result("Please welcome Sofia.", language: "en", at: 0)
        let conflicting = result("My name is Beth. My name is Anne.", language: "en", at: 1)
        let distant = result("Thank you very much for letting me speak with you all.", language: "en", at: 100)
        #expect(VoiceTrackTranscription.names(for: [host, conflicting, distant], sampleRate: 48_000).isEmpty)
    }

    @Test func languageAndTranscriptExportKeepTrackBoundaries() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WAVWriter(url: url, options: .init(encoding: .float32, channels: 1, sampleRate: 48_000))
        try writer.write((0..<4_800).map { Float($0 % 48) / 48 })
        try writer.finish()
        let source = SourceRef(name: "Recording", path: url.path, info: try AudioFileReader.info(at: url))
        let a = Track(name: "Voice 1", clips: [Clip(sourceID: source.id, start: 0, length: 2_400)])
        let b = Track(name: "Voice 2", clips: [Clip(sourceID: source.id, sourceStart: 2_400, start: 2_400, length: 2_400)])
        var project = Project(sampleRate: 48_000, channels: 1, tracks: [a, b], sources: [source])
        let initial = project
        let pool = SourcePool()
        let before = PlanCompiler.compile(initial, pool: pool).render(from: 0, frames: 4_800)
        for (i, token, language) in [(0, "Hej", "sv"), (1, "Hello", "en")] {
            let voice = TrackSpeech(project: initial, index: i, turns: [])
            let word = Word(text: token, start: 480, end: 1_200)
            #expect(voice.apply(SourceTranscript(sourceID: UUID(), language: language, engine: "test", words: [word]),
                                name: nil, to: &project) == 1)
        }
        #expect(project.tracks[0].clips[0].sourceID != project.tracks[1].clips[0].sourceID)
        #expect(project.placedWords().map(\.start) == [480, 2_880])
        #expect(PlanCompiler.compile(project, pool: pool).render(from: 0, frames: 4_800) == before)
        let data = try TranscriptExport.json.data(project: project)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tracks = try #require(root["tracks"] as? [[String: Any]])
        #expect(tracks.compactMap { $0["text"] as? String } == ["Hej", "Hello"])
        #expect(String(decoding: try TranscriptExport.srt.data(project: project, tracks: [b.id]), as: UTF8.self)
            .contains("00:00:00,060 --> 00:00:00,075\nHello"))
        #expect(String(decoding: try TranscriptExport.vtt.data(project: project), as: UTF8.self).hasPrefix("WEBVTT\n\n"))
        project.transcripts[1].textOnly = true
        #expect(throws: TranscriptExport.Failure.needsTimes) { try TranscriptExport.vtt.data(project: project) }
        #expect(try String(decoding: TranscriptExport.txt.data(project: project), as: UTF8.self).contains("Voice 2: Hello"))
    }
}
