import Foundation

/// Hold-out set 4, written 2026-11-16 without looking at any model's answers, when the mixer's first
/// actions came in. Small on purpose: the assistant can add a bus by name and nothing more of the mixer
/// yet (changing or removing one needs its id, which the assistant isn't told). Unseen until a change
/// is made because of it.
enum HoldoutSet4 {
    static let cases: [HoldoutCase] = [
        HoldoutCase(goal: "create a bus called Music", ops: ["add_bus"], params: ["add_bus": ["name": "Music"]]),
        HoldoutCase(goal: "lägg till en buss som heter Tal", ops: ["add_bus"], params: ["add_bus": ["name": "Tal"]]),
        HoldoutCase(goal: "add a submix bus named Ambience and then normalize to -16 LUFS", ops: ["add_bus", "normalize"],
                    params: ["add_bus": ["name": "Ambience"], "normalize": ["level": "-16"]], kind: "multi"),
        // The mixer has things the assistant can't do yet; it should say so or ask, not do something else.
        HoldoutCase(goal: "pan Erik a little to the left", ops: [], kind: "refuse"),
        HoldoutCase(goal: "ta bort bussen Musik", ops: [], kind: "refuse"),
        // The word "bus" in a request that isn't about the mixer.
        HoldoutCase(goal: "remove the noise from the bus passing by at 20 seconds", ops: ["restore"], params: ["restore": ["kind": "denoise"]]),
    ]
}
