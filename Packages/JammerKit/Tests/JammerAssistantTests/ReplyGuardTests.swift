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
    static var project: Project {
        let info = AudioFileInfo(container: .wav, sampleFormat: .float32, bigEndian: false, channels: 2, sampleRate: 48_000,
                                 channelMask: nil, dataOffset: 0, frames: 48_000 * 60, chunks: [], bext: nil, ixml: nil, markers: [])
        return Project(source: SourceRef(name: "Anna", path: "/dev/null", info: info))
    }
    static var context: AssistantContext { AssistantContext(project: project, selection: nil, playhead: 0) }
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

    @Test("A change the request didn't ask for waits for a yes")
    func unasked() {
        let actions = AssistantCatalog.actions
        func plan(_ ops: String...) -> AssistantPlan { AssistantPlan(reply: "", steps: ops.map { PlannedStep(op: $0) }) }
        // The case from the evaluation: a poem answered with a measurement and a tempo change.
        let poem = plan("measure_loudness", "set_tempo")
        #expect(poem.unasked(goal: "write a poem about the sea", actions: actions).map(\.op) == ["set_tempo"])
        #expect(poem.needsConfirmation(goal: "write a poem about the sea", actions: actions))
        for goal in ["tell me a joke", "vad är klockan", "write a poem about the sea"] {
            for op in ["gain", "normalize", "set_tempo", "add_marker", "transcribe", "fade_in", "rename_speaker", "duck"] {
                #expect(plan(op).needsConfirmation(goal: goal, actions: actions), "\(op) for “\(goal)”")
            }
            // Measuring, and moving the playhead or the selection, changes nothing and needs no yes.
            #expect(!plan("measure_loudness", "select_all", "set_playhead").needsConfirmation(goal: goal, actions: actions))
        }
        // Asked for in so many words: runs as before.
        for (goal, op) in [("sänk volymen med 3 dB", "gain"), ("normalize to −16 LUFS", "normalize"), ("fade in the first two seconds", "fade_in"),
                           ("lägg till en markör som heter Intro vid 5 sekunder", "add_marker"), ("transcribe this in Swedish", "transcribe"),
                           ("set the tempo to 96", "set_tempo"), ("gör talarna lika högt", "level_speakers"), ("make it louder", "gain")] {
            #expect(!plan(op).needsConfirmation(goal: goal, actions: actions), "\(op) for “\(goal)”")
        }
        // What removes or replaces audio waits as it always did, named or not.
        #expect(plan("delete").needsConfirmation(goal: "delete from 2 to 4 seconds", actions: actions))
        // Every action that changes the document has its words, or waits: none is forgotten into running.
        let unnamed = actions.map(\.name).filter { !AssistantCatalog.changesNothing.contains($0) && AssistantCatalog.spokenAs[$0] == nil }
        #expect(unnamed.allSatisfy { plan($0).needsConfirmation(goal: $0, actions: actions) })
        print("ACTIONS WITHOUT WORDS (always wait): \(unnamed)")
    }

    @Test("delete_words with nothing but filler words is remove_fillers")
    func fillersTheLongWay() {
        let long = AssistantPlan(reply: "", steps: [PlannedStep(op: "delete_words", params: ["text": .string("eh, ehm, öh, um, uh"), "words": .array([.string("eh"), .string("ehm")])])])
        #expect(PlanParser.augment(goal: "ta bort alla ehm", plan: long).steps.map(\.op) == ["remove_fillers"])
        // Real words stay a deletion of those words.
        let real = AssistantPlan(reply: "", steps: [PlannedStep(op: "delete_words", params: ["text": .string("ehm faktiskt")])])
        #expect(PlanParser.augment(goal: "ta bort ehm faktiskt", plan: real).steps.map(\.op) == ["delete_words"])
    }

    @Test("Pauses: putting silence in adds nothing, and deleting everything becomes removing the pauses")
    func pauses() {
        let insert = AssistantPlan(reply: "", steps: [PlannedStep(op: "insert_silence", params: ["at": .number(30), "duration": .number(1)])])
        #expect(PlanParser.augment(goal: "lägg in en sekund tystnad vid 30 sekunder", plan: insert).steps.map(\.op) == ["insert_silence"])
        let all = AssistantPlan(reply: "", steps: [PlannedStep(op: "delete", params: ["start": .number(0), "end": .number(60)])])
        #expect(PlanParser.augment(goal: "ta bort pauser som är längre än en och en halv sekund", plan: all).steps.map(\.op) == ["remove_silences"])
        // A range the request names is deleted as asked.
        let named = AssistantPlan(reply: "", steps: [PlannedStep(op: "delete", params: ["start": .number(0), "end": .number(12)])])
        #expect(PlanParser.augment(goal: "delete the pause in the first 12 seconds", plan: named).steps.map(\.op) == ["delete"])
    }

    @Test("A plan that only moves the playhead, for a request that asks for nothing of the kind, is no plan")
    func viewOnly() async throws {
        let planner = SayingPlanner(reply: "", steps: [PlannedStep(op: "set_playhead", params: ["at": .number(0)])])
        let poem = try await planner.answer(goal: "write a poem about the sea", context: Self.context, history: [], actions: AssistantCatalog.actions)
        #expect(poem.steps.isEmpty && poem.reply.hasPrefix("I can't do that as asked."))
        let asked = try await planner.answer(goal: "go to the start", context: Self.context, history: [], actions: AssistantCatalog.actions)
        #expect(asked.steps.map(\.op) == ["set_playhead"])
        // Beside a real step it stays: it may be how the model set the place for it.
        let both = SayingPlanner(reply: "", steps: [PlannedStep(op: "set_playhead", params: ["at": .number(5)]), PlannedStep(op: "add_marker", params: ["name": .string("A")])])
        #expect(try await both.answer(goal: "put a marker called A here", context: Self.context, history: [], actions: AssistantCatalog.actions).steps.count == 2)
    }

    @Test("A value named after what it is, not after the parameter, is still the missing required value")
    func strayArgument() {
        let actions = AssistantCatalog.actions
        let bus = PlanParser.typed(op: "add_bus", args: [("bus", "Music")], why: "", actions: actions)
        #expect(bus?.params["name"] == .string("Music"))
        // Two unknown names, or nothing missing: nothing is guessed.
        #expect(PlanParser.typed(op: "add_bus", args: [("bus", "Music"), ("title", "Other")], why: "", actions: actions)?.params["name"] == nil)
        let named = PlanParser.typed(op: "add_bus", args: [("name", "Speech"), ("colour", "red")], why: "", actions: actions)
        #expect(named?.params["name"] == .string("Speech") && named?.params.count == 1)
        // A number where a number is wanted, through the same checks as if it had the right name.
        #expect(PlanParser.typed(op: "gain", args: [("amount", "-3")], why: "", actions: actions)?.params["db"] == .number(-3))
        // Not a number where a number is wanted: nothing is filled in.
        #expect(PlanParser.typed(op: "gain", args: [("amount", "a bit")], why: "", actions: actions)?.params["db"] == nil)
        // Never for an action that removes or replaces audio: there the right name is asked for.
        for op in ["echo", "limit", "delete", "restore"] where actions.first(where: { $0.name == op })?.destructive == true {
            // (Some of these have a default for their required value; what matters is that the stray 1.7 isn't it.)
            let step = PlanParser.typed(op: op, args: [("something", "1.7")], why: "", actions: actions)
            #expect(step?.params.values.contains(.number(1.7)) != true, "\(op): \(String(describing: step?.params))")
        }
    }

    @Test("A bus is named by its name; the step gets its id, and a name that isn't a bus fills in nothing")
    func busByName() throws {
        var project = ReplyGuardTests.project
        let music = try project.addBus(name: "Music"), speech = try project.addBus(name: "Speech bus")
        let c = AssistantContext(project: project, selection: nil, playhead: 0)
        #expect(c.rendered.contains("- buses, by name: Music, Speech bus"))
        #expect(!AssistantContext(project: ReplyGuardTests.project, selection: nil, playhead: 0).rendered.contains("buses"))
        let actions = AssistantCatalog.actions
        func step(_ op: String, _ args: [(String, String)]) -> PlannedStep? { PlanParser.typed(op: op, args: args, why: "", actions: actions, context: c) }
        #expect(step("set_bus", [("bus", "Music"), ("gainDB", "-6")])?.params == ["bus": .string(music.id.uuidString), "gainDB": .number(-6)])
        #expect(step("set_bus", [("bus", "the music bus"), ("muted", "true")])?.params["bus"] == .string(music.id.uuidString))
        #expect(step("set_bus", [("bus", "speech"), ("output", "Music")])?.params == ["bus": .string(speech.id.uuidString), "output": .string(music.id.uuidString)])
        #expect(step("remove_bus", [("bus", "Speech bus"), ("reroute", "master")])?.params == ["bus": .string(speech.id.uuidString), "reroute": .string("master")])
        // The bus's name given as `name`, with no bus: it is the bus meant, not a new name for nothing.
        #expect(step("set_bus", [("name", "Music"), ("gainDB", "-6")])?.params == ["bus": .string(music.id.uuidString), "gainDB": .number(-6)])
        // With a bus given, `name` is the new name, as the step says.
        #expect(step("set_bus", [("bus", "Music"), ("name", "Songs")])?.params == ["bus": .string(music.id.uuidString), "name": .string("Songs")])
        // What the on-device model really sends (2026-11-16): the bus's name as the argument's name.
        #expect(step("set_bus", [("Music", "-6"), ("output", "Music")])?.params == ["bus": .string(music.id.uuidString), "gainDB": .number(-6)])
        #expect(step("set_bus", [("Music", "muted")])?.params == ["bus": .string(music.id.uuidString), "muted": .bool(true)])
        #expect(step("remove_bus", [("Music", "none")])?.params == ["bus": .string(music.id.uuidString)])
        // "tysta bussen Music" came as a level of 0 and a removal: it is a mute, and the bus stays.
        let tysta = AssistantPlan(reply: "", steps: [step("set_bus", [("Music", "0.0")])!, step("remove_bus", [("Music", "none")])!])
        let muted = PlanParser.augment(goal: "tysta bussen Music", plan: tysta)
        #expect(muted.steps.map(\.op) == ["set_bus"] && muted.steps[0].params == ["bus": .string(music.id.uuidString), "muted": .bool(true)])
        // A removal that is asked for stays, and waits for a yes whatever the request says.
        let gone = PlanParser.augment(goal: "remove the Music bus", plan: AssistantPlan(reply: "", steps: [step("remove_bus", [("bus", "Music")])!]))
        #expect(gone.steps.map(\.op) == ["remove_bus"] && gone.needsConfirmation(goal: "remove the Music bus", actions: actions))
        // A change to a bus with nothing to change is left out, and said.
        let nothing = PlanParser.augment(goal: "do something with the Music bus", plan: AssistantPlan(reply: "", steps: [step("set_bus", [("bus", "Music")])!]))
        #expect(nothing.steps.isEmpty && nothing.dropped.contains { $0.contains("nothing to change") })
        // No such bus: the step has no bus, and is left out when checked.
        let none = step("set_bus", [("bus", "Drums"), ("gainDB", "-6")])
        #expect(none?.params["bus"] == nil)
        #expect(PlanParser.validate(AssistantPlan(reply: "", steps: [none!]), actions: actions).steps.isEmpty)
        // A change to a bus the request names runs; one it doesn't name waits.
        let plan = AssistantPlan(reply: "", steps: [step("set_bus", [("bus", "Music"), ("gainDB", "-6")])!])
        #expect(!plan.needsConfirmation(goal: "set the Music bus to -6 dB", actions: actions) && plan.needsConfirmation(goal: "write a poem about the sea", actions: actions))
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
