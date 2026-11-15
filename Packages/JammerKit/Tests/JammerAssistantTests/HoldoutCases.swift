import Foundation

/// Hold-out set 1 for the assistant, written (and committed) before it was ever run,
/// with nothing in the prompt or rules tuned on it. 24 requests on a 60 s document with
/// two speakers, track 1 "Anna" and track 2 "Erik".
///
/// `ops`: the expected actions in order; [] means the right answer is no steps (a
/// clarifying question, a refusal, or just an answer). `params`: checks on the first step
/// with that op. A value is compared as text, except "<0" / "<1" / ">0" (a number below or
/// above), "{track1}" / "{track2}" (that track's id), and "a|b" (either).
struct HoldoutCase {
    var goal: String
    var ops: [String]
    var params: [String: [String: String]] = [:]
    var kind: String = "task"
}

enum HoldoutSet1 {
    static let cases: [HoldoutCase] = [
        // Other phrasings of single tasks.
        HoldoutCase(goal: "gör allt lite tystare", ops: ["gain"], params: ["gain": ["db": "<0"]]),
        HoldoutCase(goal: "höj volymen 6 dB på hela filen", ops: ["gain"], params: ["gain": ["db": "6"]]),
        HoldoutCase(goal: "make it as loud as a typical podcast", ops: ["normalize"], params: ["normalize": ["target": "loudness", "level": "-16|-14"]]),
        HoldoutCase(goal: "set the true peak to -1 dBTP", ops: ["normalize"], params: ["normalize": ["target": "true_peak", "level": "-1"]]),
        HoldoutCase(goal: "tona ut de sista två sekunderna", ops: ["fade_out"], params: ["fade_out": ["start": "58", "end": "60"]]),
        HoldoutCase(goal: "get rid of the buzzing on Erik's track", ops: ["restore"], params: ["restore": ["kind": "dehum", "tracks": "{track2}"]]),
        HoldoutCase(goal: "det knastrar, kan du fixa det?", ops: ["restore"], params: ["restore": ["kind": "declick"]]),
        HoldoutCase(goal: "ljudet är överstyrt och spräckt", ops: ["restore"], params: ["restore": ["kind": "declip"]]),
        HoldoutCase(goal: "remove the background hiss but keep it natural", ops: ["restore"], params: ["restore": ["kind": "denoise", "amount": "<1"]]),
        HoldoutCase(goal: "lägg på ett kort eko på allt", ops: ["echo"]),
        HoldoutCase(goal: "rensa bort alla öh och hm", ops: ["remove_fillers"]),
        HoldoutCase(goal: "shorten every pause over two seconds to half a second", ops: ["remove_silences"], params: ["remove_silences": ["min_length": "2", "keep": "0.5"]]),
        HoldoutCase(goal: "transkribera på engelska", ops: ["transcribe"], params: ["transcribe": ["language": "en-US|en-GB"]]),
        HoldoutCase(goal: "sätt en markör vid 1:30 som heter Kapitel 2", ops: ["add_marker"], params: ["add_marker": ["at": "90", "name": "Kapitel 2"]]),
        HoldoutCase(goal: "markera 20 till 25 sekunder", ops: ["select"], params: ["select": ["start": "20", "end": "25"]]),
        HoldoutCase(goal: "silence 10 to 12 seconds without moving anything", ops: ["silence"], params: ["silence": ["start": "10", "end": "12"]]),
        // Several steps.
        HoldoutCase(goal: "klipp bort de första tre sekunderna och tona sedan in början på en halv sekund", ops: ["delete", "fade_in"],
                    params: ["delete": ["start": "0", "end": "3"], "fade_in": ["start": "0", "end": "0.5"]], kind: "multi"),
        HoldoutCase(goal: "mät hur högt det är och normalisera sedan till -23 LUFS", ops: ["measure_loudness", "normalize"],
                    params: ["normalize": ["target": "loudness", "level": "-23"]], kind: "multi"),
        HoldoutCase(goal: "copy the first five seconds and paste them at the end", ops: ["copy", "paste"],
                    params: ["copy": ["start": "0", "end": "5"], "paste": ["at": "60"]], kind: "multi"),
        // Unclear: the right answer is a question.
        HoldoutCase(goal: "fixa ljudet", ops: [], kind: "clarify"),
        HoldoutCase(goal: "gör det bättre", ops: [], kind: "clarify"),
        // Not allowed, or nothing to do.
        HoldoutCase(goal: "spela in en ny tagning", ops: [], kind: "refuse"),
        HoldoutCase(goal: "radera originalfilen från disken", ops: [], kind: "refuse"),
        HoldoutCase(goal: "vad kan du hjälpa till med?", ops: [], kind: "answer"),
    ]
}
