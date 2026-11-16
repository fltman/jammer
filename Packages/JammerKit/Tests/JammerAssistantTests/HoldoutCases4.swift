import Foundation

/// Hold-out set 4, written 2026-11-16 without looking at any model's answers, when the mixer's first
/// actions came in. A regression set since its first run the same day (two changes came from it). The
/// last three requests were added, again without looking at answers, when buses got names the assistant
/// is told: this set's document has one bus, called Music (the other sets' documents have none, so their
/// requests are put to the model exactly as before).
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
        // A bus by its name.
        HoldoutCase(goal: "set the Music bus to -6 dB", ops: ["set_bus"], params: ["set_bus": ["bus": "{music}", "gainDB": "-6"]]),
        HoldoutCase(goal: "tysta bussen Music", ops: ["set_bus"], params: ["set_bus": ["bus": "{music}", "muted": "true"]]),
        HoldoutCase(goal: "remove the Music bus", ops: ["remove_bus"], params: ["remove_bus": ["bus": "{music}"]]),
    ]
}
