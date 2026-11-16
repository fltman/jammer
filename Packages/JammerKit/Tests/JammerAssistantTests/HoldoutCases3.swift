import Foundation

/// Hold-out set 3, written 2026-11-16 without looking at any model's answers, after set 2 had been used
/// to find two rules and so was no longer unseen. The same 60 s document with Anna on track 1 and Erik on
/// track 2. It is the unseen set until a change is made because of something it showed; from then on it
/// is a regression set like 1 and 2, and a new one is written (docs/ASSISTANT.md says which is which).
enum HoldoutSet3 {
    static let cases: [HoldoutCase] = [
        // Single tasks, worded another way.
        HoldoutCase(goal: "höj volymen två decibel", ops: ["gain"], params: ["gain": ["db": "2"]]),
        HoldoutCase(goal: "make Erik 4 dB quieter", ops: ["gain"], params: ["gain": ["db": "-4", "tracks": "{track2}"]]),
        HoldoutCase(goal: "normalisera topparna till minus en decibel", ops: ["normalize"], params: ["normalize": ["target": "peak|true_peak", "level": "-1"]]),
        HoldoutCase(goal: "bring the loudness to -14 LUFS", ops: ["normalize"], params: ["normalize": ["target": "loudness", "level": "-14"]]),
        HoldoutCase(goal: "tona ut de sista fem sekunderna", ops: ["fade_out"], params: ["fade_out": ["start": "55", "end": "60"]]),
        HoldoutCase(goal: "give it a three second fade in", ops: ["fade_in"], params: ["fade_in": ["start": "0", "end": "3"]]),
        HoldoutCase(goal: "det knäpper i ljudet, kan du få bort det", ops: ["restore"], params: ["restore": ["kind": "declick"]]),
        HoldoutCase(goal: "get rid of the mains hum on track 1", ops: ["restore"], params: ["restore": ["kind": "dehum", "tracks": "{track1}"]]),
        HoldoutCase(goal: "det brusar för mycket", ops: ["restore"], params: ["restore": ["kind": "denoise"]]),
        HoldoutCase(goal: "the room sounds too echoey, reduce the reverb", ops: ["restore"], params: ["restore": ["kind": "dereverb"]]),
        HoldoutCase(goal: "stryk alla öh och ehm", ops: ["remove_fillers"]),
        HoldoutCase(goal: "shorten every pause over two seconds", ops: ["remove_silences"], params: ["remove_silences": ["min_length": "2"]]),
        HoldoutCase(goal: "radera från 20 till 25 sekunder", ops: ["delete"], params: ["delete": ["start": "20", "end": "25"]]),
        HoldoutCase(goal: "mute the part between 12 and 14 seconds", ops: ["silence"], params: ["silence": ["start": "12", "end": "14"]]),
        HoldoutCase(goal: "sätt en markör som heter Reklam vid 45 sekunder", ops: ["add_marker"], params: ["add_marker": ["name": "Reklam", "at": "45"]]),
        HoldoutCase(goal: "transkribera på svenska", ops: ["transcribe"], params: ["transcribe": ["language": "sv-SE"]]),
        HoldoutCase(goal: "how loud is this?", ops: ["measure_loudness"]),
        HoldoutCase(goal: "lägg på ett eko", ops: ["echo"]),
        // The newer actions, which the on-device model is given only when the request names them.
        HoldoutCase(goal: "duck the music under the speech", ops: ["duck"]),
        HoldoutCase(goal: "vad är tempot i låten?", ops: ["detect_tempo"]),
        HoldoutCase(goal: "gör så att talarna är lika högt", ops: ["level_speakers"]),
        HoldoutCase(goal: "master it for Spotify", ops: ["loudness_preset"]),
        // Several tasks in one sentence; the last is as long as a real plan gets (six steps), and has to
        // come back whole: the on-device model's answer is limited to 700 tokens.
        HoldoutCase(goal: "ta bort bruset och normalisera sedan till -16 LUFS", ops: ["restore", "normalize"],
                    params: ["restore": ["kind": "denoise"], "normalize": ["level": "-16"]], kind: "multi"),
        HoldoutCase(goal: "fade in the first two seconds, lower the volume by 3 dB, add a marker called Intro at 5 seconds, add a marker called End at 50 seconds, fade out the last three seconds and normalize to -16 LUFS",
                    ops: ["fade_in", "gain", "add_marker", "add_marker", "fade_out", "normalize"],
                    params: ["fade_in": ["start": "0", "end": "2"], "gain": ["db": "-3"], "fade_out": ["start": "57", "end": "60"], "normalize": ["level": "-16"]], kind: "multi"),
        // Unclear, outside what Jämmer does, and a question.
        HoldoutCase(goal: "fixa det", ops: [], kind: "clarify"),
        HoldoutCase(goal: "can you make it better", ops: [], kind: "clarify"),
        HoldoutCase(goal: "skicka filen till min kollega med mejl", ops: [], kind: "refuse"),
        HoldoutCase(goal: "what's the weather like in Stockholm", ops: [], kind: "refuse"),
        HoldoutCase(goal: "kan du ta bort brus?", ops: [], kind: "answer"),
    ]
}
