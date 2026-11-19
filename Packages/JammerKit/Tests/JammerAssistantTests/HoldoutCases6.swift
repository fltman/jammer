import Foundation

/// Hold-out set 6, written 2026-11-19 without looking at any model's answers, after the on-device model named a
/// track "music" (and then put "12" where a track goes) in the product film's Swedish request. Its document has
/// two tracks, Dialog and Music, as the film's had. A track may be given by its id or its name.
enum HoldoutSet6 {
    static let cases: [HoldoutCase] = [
        HoldoutCase(goal: "duck the music under the speech", ops: ["duck"], params: ["duck": ["tracks": "{track2}"]]),
        HoldoutCase(goal: "sänk musiken med 12 dB när någon pratar", ops: ["duck"], params: ["duck": ["tracks": "{track2}", "amount": "-12"]]),
        HoldoutCase(goal: "duck Music under Dialog by 10 dB", ops: ["duck"], params: ["duck": ["tracks": "{track2}", "under": "{track1}", "amount": "-10"]]),
        HoldoutCase(goal: "mute the Music track", ops: ["set_track"], params: ["set_track": ["track": "{track2}", "muted": "true"]]),
        HoldoutCase(goal: "tysta musikspåret", ops: ["set_track"], params: ["set_track": ["track": "{track2}", "muted": "true"]]),
        HoldoutCase(goal: "pan the dialog a little to the left", ops: ["set_track"], params: ["set_track": ["track": "{track1}", "pan": "<0"]]),
        HoldoutCase(goal: "set the Music track's level to -8 dB", ops: ["set_track"], params: ["set_track": ["track": "{track2}", "gainDB": "-8"]]),
        HoldoutCase(goal: "freeze the music track", ops: ["freeze"], params: ["freeze": ["strip": "{track2}"]]),
        HoldoutCase(goal: "limit the music track to -1 dBTP", ops: ["limit"], params: ["limit": ["tracks": "{track2}", "ceiling": "-1"]]),
        HoldoutCase(goal: "ta bort brummet på dialogspåret", ops: ["restore"], params: ["restore": ["kind": "dehum", "tracks": "{track1}"]]),
    ]
}
