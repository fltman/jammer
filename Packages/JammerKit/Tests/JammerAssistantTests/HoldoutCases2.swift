import Foundation

/// Hold-out set 2, written and committed before its first run, after the changes made
/// in response to set 1 (guardrails, clock times). Same document: 60 s, track 1 "Anna",
/// track 2 "Erik". Same notation as `HoldoutSet1`.
enum HoldoutSet2 {
    static let cases: [HoldoutCase] = [
        HoldoutCase(goal: "dra ner nivån med fyra decibel", ops: ["gain"], params: ["gain": ["db": "-4"]]),
        HoldoutCase(goal: "turn everything up a bit", ops: ["gain"], params: ["gain": ["db": ">0"]]),
        HoldoutCase(goal: "normalize the loudness to minus eighteen", ops: ["normalize"], params: ["normalize": ["target": "loudness", "level": "-18"]]),
        HoldoutCase(goal: "se till att toppen inte går över -2 dB", ops: ["normalize"], params: ["normalize": ["target": "peak|true_peak", "level": "-2"]]),
        HoldoutCase(goal: "fade out from 55 seconds to the end", ops: ["fade_out"], params: ["fade_out": ["start": "55", "end": "60"]]),
        HoldoutCase(goal: "tona in de första fyra sekunderna", ops: ["fade_in"], params: ["fade_in": ["start": "0", "end": "4"]]),
        HoldoutCase(goal: "Anna har brum i bakgrunden, ta bort det", ops: ["restore"], params: ["restore": ["kind": "dehum", "tracks": "{track1}"]]),
        HoldoutCase(goal: "there are pops and clicks everywhere", ops: ["restore"], params: ["restore": ["kind": "declick"]]),
        HoldoutCase(goal: "minska bruset", ops: ["restore"], params: ["restore": ["kind": "denoise"]]),
        HoldoutCase(goal: "the recording is distorted", ops: ["restore"], params: ["restore": ["kind": "declip"]]),
        HoldoutCase(goal: "ta bort pauser som är längre än en och en halv sekund", ops: ["remove_silences"], params: ["remove_silences": ["min_length": "1.5"]]),
        HoldoutCase(goal: "clean up all the ums and uhs", ops: ["remove_fillers"]),
        HoldoutCase(goal: "delete everything between 0:40 and 0:45", ops: ["delete"], params: ["delete": ["start": "40", "end": "45"]]),
        HoldoutCase(goal: "lägg in en sekund tystnad vid 30 sekunder", ops: ["insert_silence"], params: ["insert_silence": ["at": "30", "duration": "1"]]),
        HoldoutCase(goal: "add a marker named Outro at 0:50", ops: ["add_marker"], params: ["add_marker": ["name": "Outro", "at": "50"]]),
        HoldoutCase(goal: "transcribe it", ops: ["transcribe"]),
        HoldoutCase(goal: "ta bort brummet på båda talarna och normalisera sedan till -16 LUFS", ops: ["restore", "normalize"],
                    params: ["restore": ["kind": "dehum"], "normalize": ["level": "-16"]], kind: "multi"),
        HoldoutCase(goal: "cut the first two seconds and remove the long pauses", ops: ["delete", "remove_silences"],
                    params: ["delete": ["start": "0", "end": "2"]], kind: "multi"),
        HoldoutCase(goal: "kan du göra det proffsigare?", ops: [], kind: "clarify"),
        HoldoutCase(goal: "it sounds weird", ops: [], kind: "clarify"),
        HoldoutCase(goal: "byt utdataenhet till hörlurarna", ops: [], kind: "refuse"),
        HoldoutCase(goal: "move the file to my desktop", ops: [], kind: "refuse"),
        HoldoutCase(goal: "vilka format kan du exportera?", ops: [], kind: "answer"),
    ]
}
