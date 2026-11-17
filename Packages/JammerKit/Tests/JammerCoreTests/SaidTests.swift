import Foundation
import Testing
@testable import JammerCore

@Suite("Sentences said by key (Said)")
struct SaidTests {
    @Test("The English is filled in one pass: plain and numbered places, and a value that looks like a place stays as it is")
    func fill() {
        #expect(Said("k", "Level %@", "3").text == "Level 3")
        #expect(Said("k", "%2$@ of %1$@", "a", "b").text == "b of a")
        #expect(Said("k", "%1$@ and %2$@", "%2$@", "x").text == "%2$@ and x")
        #expect(Said("k", "no values").keyed == KeyedMessage("k"))
    }

    @Test("A sentence inside a sentence: its English in the last place, its key kept for the window")
    func inner() {
        let why = Said("error.import.isn_t_json", "it isn't JSON.")
        let s = Said("error.import.unreadable", "The file can't be read as a timeline: %@", inner: why)
        #expect(s.text == "The file can't be read as a timeline: it isn't JSON.")
        #expect(s.keyed.inner == [why.keyed] && s.keyed.args.isEmpty)
        let two = Said("acx.peak.note", "%1$@ … On %2$@.", inner: [Said("a", "First."), Said("b", "the mix")])
        #expect(two.text == "First. … On the mix." && two.keyed.inner.map(\.key) == ["a", "b"])
    }

    @Test("One or more: the .one sentence for 1, the .other for any other count")
    func plural() {
        #expect(counted(1, Said("n.one", "1 clip"), Said("n.other", "%@ clips", "1")).keyed.key == "n.one")
        #expect(counted(3, Said("n.one", "1 clip"), Said("n.other", "%@ clips", "3")).text == "3 clips")
    }

    @Test("Typed errors carry their sentence's key: the limiter, a file, the import, the project check")
    func errors() throws {
        #expect((LimiterError.badValue(Said("limiter.channels_1_64", "channels must be 1 to 64.")) as KeyedFailure).keyed?.key == "limiter.channels_1_64")
        // A case and its sentence's helper once shared a name, and keyed called itself until the stack ran out.
        #expect(Mixer.Failure.inUse("Group", 2).keyed?.key == "error.mixer.inUse.other" && Mixer.Failure.inUse("Group", 1).keyed?.key == "error.mixer.inUse.one")
        #expect(SpectralEditError.tooLong(5).keyed?.key == "error.spectralEdit.tooLong" && SpectralEditError.tooLong(5).errorDescription?.hasPrefix("Heal is for short sounds") == true)
        do { _ = try AudioFileReader.info(at: URL(fileURLWithPath: "/nowhere/x.wav")); Issue.record("opened nothing") }
        catch let e as AudioFileError { #expect(e.keyed?.key == "error.file.can_t_open" && e.keyed?.args == ["x.wav"]) }
        do { _ = try OTIO.read(Data("not json".utf8), base: URL(fileURLWithPath: "/"), name: "x"); Issue.record("read nothing") }
        catch { #expect(error.keyed?.key == "error.import.unreadable" && error.keyed?.inner.first?.key == "error.import.isn_t_json") }
        var p = Project(sampleRate: 48_000, channels: 2)
        p.markers = [Marker(position: 100_000_000_000, length: 0, name: "far")]   // beyond the ten days a timeline may run
        let notes = try ProjectSafety.check(&p)
        #expect(notes.contains { $0.keyed.key == "project.repaired.markers.one" }, "\(notes)")
    }
}
