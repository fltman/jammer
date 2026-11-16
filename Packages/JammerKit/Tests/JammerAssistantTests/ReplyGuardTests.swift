import Foundation
import JammerAgent
import JammerCore
import Testing
@testable import JammerAssistant

/// A planner that says what it is told to, as a model might.
struct SayingPlanner: AssistantPlanner {
    var id = "saying"
    var paid = false
    var reply: String
    var steps: [PlannedStep] = []
    func plan(goal: String, context: AssistantContext, history: [(user: String, reply: String)], actions: [AssistantAction]) async throws -> AssistantPlan {
        AssistantPlan(reply: reply, steps: steps)
    }
}

@Suite("What a model wrote, before it is shown")
struct ReplyGuardTests {
    static var context: AssistantContext {
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: 48_000 * 60, chunks: [], bext: nil, ixml: nil, markers: [])
        return AssistantContext(project: Project(source: SourceRef(name: "Anna", path: "/dev/null", info: info)), selection: nil, playhead: 0)
    }
    func shown(_ reply: String, steps: [PlannedStep] = [], goal: String) async throws -> String {
        try await SayingPlanner(reply: reply, steps: steps).answer(goal: goal, context: Self.context, history: [], actions: AssistantCatalog.actions).reply
    }

    @Test("A made-up measurement never reaches the screen")
    func inventedFigure() async throws {
        // The case from the app: the model's sentence in front of the measured answer.
        let measure = [PlannedStep(op: "measure_loudness", params: [:])]
        #expect(try await shown("The loudness is -16 LUFS.", steps: measure, goal: "what is the loudness?") == "")
        #expect(try await shown("I'll measure it for you.", steps: measure, goal: "what is the loudness?") == "")
        // Without a measuring step the sentence with the figure goes, the rest stays.
        #expect(try await shown("Sure. The loudness is −16,5 LUFS. Anything else?", steps: [PlannedStep(op: "add_marker", params: ["name": .string("A"), "at": .number(5)])],
                                goal: "add a marker called A at five") == "Sure. Anything else?")
        for invented in ["The peak is at -1.2 dBTP.", "There is hum at 50 Hz.", "It is 3dB too loud.", "The tempo is 120 BPM.", "About 40 % of it is silence.", "Brummet ligger på 50 Hz."] {
            let got = try await shown(invented, goal: "how does this recording sound to you, tell me")
            #expect(ReplyGuard.figures(in: got).isEmpty && !got.isEmpty, "\(invented) → \(got)")
        }
    }

    @Test("Figures from the request, the plan and the document may be repeated")
    func knownFigures() async throws {
        let normalize = [PlannedStep(op: "normalize", params: ["target": .string("loudness"), "level": .number(-16)])]
        #expect(try await shown("I'll normalize to -16 LUFS.", steps: normalize, goal: "normalize to −16 LUFS") == "I'll normalize to -16 LUFS.")
        #expect(try await shown("Jag sänker volymen med 3 dB.", steps: [PlannedStep(op: "gain", params: ["db": .number(-3)])], goal: "sänk volymen med 3 dB") == "Jag sänker volymen med 3 dB.")
        // The document is 60.00 s long, and the model was told so.
        #expect(try await shown("The document is 60.00 s long.", goal: "how long is this document, tell me") == "The document is 60.00 s long.")
        #expect(try await shown("The document is 45 s long.", goal: "how long is this document, tell me") != "The document is 45 s long.")
        // Numbers without a unit are not measurements.
        #expect(try await shown("I'll work on track 2.", steps: normalize, goal: "normalize track two please") == "I'll work on track 2.")
    }

    @Test("The on-device model's action list stays the size it was measured at")
    func onDeviceList() {
        let all = AssistantCatalog.actions
        let plain = AssistantCatalog.forOnDevice(all, goal: "sänk volymen med 3 dB")
        // 28 actions and under 4 000 characters of instructions is what scored 14/14; a new action has to be
        // given its words in onDeviceWhenNamed, or be let in here on purpose after the evaluation was run.
        #expect(plain.count == 28, "\(plain.map(\.name).sorted())")
        #expect(AssistantPrompt.instructions(plain).count < 4_000)
        #expect(Set(AssistantCatalog.onDeviceWhenNamed.keys).isSubset(of: Set(all.map(\.name))))
        // Named, an action is there.
        for (goal, op) in [("duck the music under the speech", "duck"), ("vad är tempot?", "detect_tempo"), ("gör talarna lika högt", "level_speakers"),
                           ("normalize for Spotify", "loudness_preset"), ("döp om talare 2 till Erik", "rename_speaker"), ("ta bort läckaget mellan mikrofonerna", "debleed")] {
            #expect(AssistantCatalog.forOnDevice(all, goal: goal).contains { $0.name == op }, "\(goal)")
        }
    }

    @Test("The reply follows the language of the request")
    func language() async throws {
        let swedish = "Jag kan inte skriva en dikt om havet eftersom du inte specificerade något att göra med ljudet."
        let got = try await shown(swedish, goal: "write a poem about the sea")
        #expect(ReplyGuard.language(of: got) == .english && got.hasPrefix("I can't do that as asked."))
        let back = try await shown("I cannot write poems, I only edit audio in this document.", goal: "skriv en dikt om havet och vinden")
        #expect(ReplyGuard.language(of: back) == .swedish)
        // The right language is left alone, and so is a reply too short to tell.
        #expect(try await shown(swedish, goal: "skriv en dikt om havet och vinden") == swedish)
        #expect(try await shown("OK.", steps: [PlannedStep(op: "gain", params: ["db": .number(-3)])], goal: "lower the volume by 3 dB") == "OK.")
        // With steps, a reply in the wrong language is dropped: the plan speaks.
        #expect(try await shown("Jag sänker volymen i hela dokumentet nu.", steps: [PlannedStep(op: "gain", params: ["db": .number(-3)])], goal: "lower the volume by 3 dB please") == "")
    }
}
