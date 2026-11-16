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

    func checked(_ reply: String, steps: [PlannedStep] = [], goal: String, selection: Range<Frame>? = nil, playhead: Frame = 0) -> AssistantPlan {
        ReplyGuard.checked(AssistantPlan(reply: reply, steps: steps), goal: goal,
                           context: AssistantContext(project: Self.project, selection: selection, playhead: playhead))
    }

    @Test("A figure worked out rightly from what was given stays, and a made-up one beside it is held back and said to be")
    func derivedFigures() {
        // The document is 60 s; the selection is 10–25 s; the playhead is at 40 s.
        let sel: Range<Frame> = (48_000 * 10)..<(48_000 * 25)
        var p = checked("The selection is 15 s long. The peak is at -3.2 dBTP.", goal: "how long is the selection, please tell me", selection: sel)
        #expect(p.reply == "The selection is 15 s long.")
        #expect(p.heldBack == ["The peak is at -3.2 dBTP."])
        #expect(ReplyGuard.heldBackNote(.english, count: 1).contains("held back") && ReplyGuard.heldBackNote(.swedish, count: 2).contains("hölls tillbaka"))
        // Half the document, what is left after the playhead, the length in minutes.
        #expect(checked("Half of it is 30 s.", goal: "what is half of this document, tell me").heldBack.isEmpty)
        #expect(checked("There are 20 s left after the playhead.", goal: "how much is left of it, tell me", playhead: 48_000 * 40).heldBack.isEmpty)
        #expect(checked("That is 1 min of sound.", goal: "how long is it, tell me that").heldBack.isEmpty)
        // Two times in the request: their difference, and one of them in another unit.
        #expect(checked("That is 15 s of sound.", goal: "how much is it from 10 s to 25 s?").heldBack.isEmpty)
        #expect(checked("A fade of 500 ms.", goal: "what is 0.5 s in milliseconds?").heldBack.isEmpty)
        // Two levels: how far apart they are. Not some other distance.
        #expect(checked("That is 7 dB up.", goal: "how far is it from -23 LUFS to -16 LUFS?").heldBack.isEmpty)
        #expect(checked("That is 9 dB up.", goal: "how far is it from -23 LUFS to -16 LUFS?").heldBack.count == 1)
        // A time is not backed by a level's arithmetic, nor the other way round.
        #expect(checked("That is 7 s.", goal: "how far is it from -23 LUFS to -16 LUFS?").heldBack.count == 1)
        // A number the request gives in words is given.
        #expect(checked("Loudness normalized to -18 LUFS.", goal: "normalize the loudness to minus eighteen").heldBack.isEmpty)
        #expect(checked("Pauser över 2 sekunder kortas till 0,5 sekunder.", goal: "korta alla pauser över två sekunder till en halv sekund").heldBack.isEmpty)
        #expect(checked("Ta bort pauser längre än 1.5 sekunder.", goal: "ta bort pauser som är längre än en och en halv sekund").heldBack.isEmpty)
        #expect(checked("Pauses over 2.5 seconds go.", goal: "remove pauses longer than two and a half seconds").heldBack.isEmpty)
        // Not within "seems reasonable": 31 s is not half of 60.
        #expect(checked("Half of it is 31 s.", goal: "what is half of this document, tell me").heldBack.count == 1)
    }

    @Test("When every planned step was left out, the model's sentence about them isn't shown")
    func nothingLeftToDo() {
        let p = ReplyGuard.checked(AssistantPlan(reply: "VCA Voices removed.", steps: [], dropped: ["remove_vca (remove_vca needs \"vca\".)"]),
                                   goal: "remove the Voices VCA", context: Self.context)
        #expect(p.reply.hasPrefix("I can't do that as asked.") && p.dropped.count == 1)
        // Some steps stay, one was left out: the plan and the line about what was left out speak, not the model.
        let gain = [PlannedStep(op: "gain", params: ["db": .number(-3)])]
        let q = ReplyGuard.checked(AssistantPlan(reply: "Lowered it and removed the group.", steps: gain, dropped: ["remove_vca"]), goal: "lower it 3 dB and remove the group", context: Self.context)
        #expect(q.reply == "" && q.steps == gain)
        // Nothing left out: the sentence stays.
        #expect(ReplyGuard.checked(AssistantPlan(reply: "Lowering it.", steps: gain), goal: "lower it 3 dB", context: Self.context).reply == "Lowering it.")
        // A delivery target that the request names is its preset, not a level the model chose; a level the request gives stays.
        let n = [PlannedStep(op: "normalize", params: ["target": .string("loudness"), "level": .number(-16), "start": .number(0), "end": .number(60)])]
        #expect(PlanParser.augment(goal: "master the episode for Spotify", plan: AssistantPlan(reply: "", steps: n)).steps
                == [PlannedStep(op: "loudness_preset", params: ["preset": .string("spotify"), "start": .number(0), "end": .number(60)])])
        #expect(PlanParser.augment(goal: "normalize to -16 LUFS for Spotify", plan: AssistantPlan(reply: "", steps: n)).steps == n)
    }

    @Test("An action's own figures stand only in a sentence about that action, and never as a claim about the user's sound")
    func actionFigures() {
        // `limit` says its default ceiling is −1 dBTP and its release 100 ms.
        #expect(checked("The limiter's ceiling is -1 dBTP unless you say otherwise.", goal: "what does the limiter do by default?").heldBack.isEmpty)
        #expect(checked("By default the release is 100 ms.", goal: "what does the limiter do by default?").heldBack.isEmpty)
        // The same figure in a sentence that names no action.
        #expect(checked("It settles after 100 ms.", goal: "what happens to the peaks then, tell me").heldBack.count == 1)
        // And as a statement about the user's own sound, even with the action named.
        #expect(checked("Your recording is at -20 dBTP, so the limiter isn't needed.", goal: "do I need the limiter here?").heldBack.count == 1)
        #expect(checked("Inspelningen ligger på -20 dBTP, så limitern behövs inte.", goal: "behöver jag en limiter här?").heldBack.count == 1)
        // (The same figure where the sentence is about the action: its range.)
        #expect(checked("The limiter's ceiling can be set from -20 dBTP.", goal: "do I need the limiter here?").heldBack.isEmpty)
    }

    @Test("Money, sizes on disk, how long something takes and anything about a service: only when given")
    func neverWorkedOut() {
        #expect(checked("That costs $0.02.", goal: "transcribe this for me please").heldBack.count == 1)
        #expect(checked("Det kostar 3 kr.", goal: "transkribera det här åt mig").heldBack.count == 1)
        #expect(checked("The file will be 30 MB.", goal: "what is half of this document, tell me").heldBack.count == 1)
        // 30 s is half the document, but not how long anything takes.
        #expect(checked("It takes 30 s to finish.", goal: "what is half of this document, tell me").heldBack.count == 1)
        #expect(checked("The service allows 30 s per request.", goal: "can I transcribe it in the cloud?").heldBack.count == 1)
        // Given in the request, they may be repeated.
        #expect(checked("You said 5 kr.", goal: "it cost me 5 kr last time").heldBack.isEmpty)
    }

    @Test("The mixer's names: a strip to freeze, the ends of a send, a VCA group; and the master without settings nobody asked for")
    func mixerNames() throws {
        var project = ReplyGuardTests.project
        let b = SourceRef(name: "Erik", path: "/dev/null", info: project.sources[0].info)
        project.sources.append(b)
        project.tracks.append(Track(name: "Erik", clips: [Clip(sourceID: b.id, start: 0, length: 48_000)]))
        let music = try project.addBus(name: "Music"), voices = try project.addVCA(name: "Voices")
        let anna = project.tracks[0].id.uuidString, erik = project.tracks[1].id.uuidString
        let c = AssistantContext(project: project, selection: nil, playhead: 0)
        #expect(c.rendered.contains("- VCA groups, by name: Voices"))
        let actions = AssistantCatalog.actions
        func step(_ op: String, _ args: [(String, String)]) -> PlannedStep? { PlanParser.typed(op: op, args: args, why: "", actions: actions, context: c) }
        #expect(step("freeze", [("strip", "the Music bus")])?.params == ["strip": .string(music.id.uuidString)])
        #expect(step("freeze", [("strip", "spåret Erik")])?.params == ["strip": .string(erik)])
        #expect(step("unfreeze", [("track", "Anna")])?.params == ["strip": .string(anna)])
        #expect(step("freeze", [("strip", "Nobody")]) == nil)
        #expect(step("set_send", [("from", "Erik"), ("to", "Music"), ("gainDB", "-6")])?.params == ["from": .string(erik), "to": .string(music.id.uuidString), "gainDB": .number(-6)])
        #expect(step("set_vca", [("vca", "the Voices VCA"), ("gainDB", "-4")])?.params == ["vca": .string(voices.id.uuidString), "gainDB": .number(-4)])
        #expect(step("remove_vca", [("name", "Voices")])?.params == ["vca": .string(voices.id.uuidString)])
        #expect(step("set_vca", [("name", "Voices"), ("muted", "true")])?.params == ["vca": .string(voices.id.uuidString), "muted": .bool(true)])
        #expect(step("set_vca", [("vca", "Voices"), ("members", "Anna, Music")])?.params["members"] == .array([.string(anna), .string(music.id.uuidString)]))
        // The master.
        func master(_ goal: String, _ params: [String: JSONValue]) -> [String: JSONValue]? {
            PlanParser.augment(goal: goal, plan: AssistantPlan(reply: "", steps: [PlannedStep(op: "set_master", params: params)])).steps.first?.params
        }
        #expect(master("put a limiter on the master at -1 dBTP", ["ceiling": .number(-1), "limiter": .bool(false), "gainDB": .number(-1)]) == ["ceiling": .number(-1), "limiter": .bool(true)])
        #expect(master("sänk mastern till -3 dB", ["ceiling": .number(-3), "gainDB": .number(-3), "limiter": .bool(false)]) == ["gainDB": .number(-3)])
        #expect(master("turn the limiter on the master off", ["limiter": .bool(true), "ceiling": .number(-1)]) == ["limiter": .bool(false)])
        #expect(master("set the master to -2 dB", ["ceiling": .number(0), "gainDB": .number(-2), "limiter": .bool(false), "lookahead": .number(10)]) == ["gainDB": .number(-2)])
        // A freeze answered with an empty change to the bus is the freeze; a send answered with the bus's level is nothing.
        let viaBus = PlanParser.augment(goal: "freeze the Music bus", plan: AssistantPlan(reply: "", steps: [PlannedStep(op: "set_bus", params: ["bus": .string(music.id.uuidString)])]))
        #expect(viaBus.steps == [PlannedStep(op: "freeze", params: ["strip": .string(music.id.uuidString)])])
        let notASend = PlanParser.augment(goal: "send Erik to the Music bus at -6 dB", plan: AssistantPlan(reply: "", steps: [PlannedStep(op: "set_bus", params: ["bus": .string(music.id.uuidString), "gainDB": .number(-6)])]))
        #expect(notASend.steps.isEmpty && notASend.dropped.count == 1)
        let notNew = PlanParser.augment(goal: "tysta VCA-gruppen Voices", plan: AssistantPlan(reply: "", steps: [PlannedStep(op: "add_vca", params: ["name": .string("muted")])]))
        #expect(notNew.steps.isEmpty && notNew.dropped.count == 1)
        #expect(PlanParser.augment(goal: "create a VCA group called Drums", plan: AssistantPlan(reply: "", steps: [PlannedStep(op: "add_vca", params: ["name": .string("Drums")])])).steps.count == 1)
        // Offered to the small model only when named.
        for (goal, op) in [("freeze the Music bus", "freeze"), ("frys spåret Erik", "freeze"), ("unfreeze Anna", "unfreeze"), ("sänk mastern 3 dB", "set_master"),
                           ("send Erik to the Music bus", "set_send"), ("remove the Voices VCA", "remove_vca")] {
            #expect(AssistantCatalog.forOnDevice(actions, goal: goal).contains { $0.name == op }, "\(goal)")
        }
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
