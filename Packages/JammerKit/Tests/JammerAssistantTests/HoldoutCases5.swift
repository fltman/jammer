import Foundation

/// Hold-out set 5, written 2026-11-16 without looking at any model's answers, when the assistant was
/// given the mixer's later parts: the master and its limiter, sends, VCA groups and freezing. Its
/// document has two tracks (Anna, Erik), a bus called Music and a VCA group called Voices.
/// Among them are requests that use the new actions' words for something else.
enum HoldoutSet5 {
    static let cases: [HoldoutCase] = [
        // The master.
        HoldoutCase(goal: "put a limiter on the master at -1 dBTP", ops: ["set_master"], params: ["set_master": ["ceiling": "-1"]]),
        HoldoutCase(goal: "sänk mastern till -3 dB", ops: ["set_master"], params: ["set_master": ["gainDB": "-3"]]),
        HoldoutCase(goal: "turn the limiter on the master off", ops: ["set_master"], params: ["set_master": ["limiter": "false"]]),
        // Freezing.
        HoldoutCase(goal: "freeze the Music bus", ops: ["freeze"], params: ["freeze": ["strip": "{music}"]]),
        HoldoutCase(goal: "frys spåret Erik", ops: ["freeze"], params: ["freeze": ["strip": "{track2}"]]),
        HoldoutCase(goal: "unfreeze Anna", ops: ["unfreeze"], params: ["unfreeze": ["strip": "{track1}"]]),
        // A send.
        HoldoutCase(goal: "send Erik to the Music bus at -6 dB", ops: ["set_send"], params: ["set_send": ["from": "{track2}", "to": "{music}", "gainDB": "-6"]]),
        // VCA groups.
        HoldoutCase(goal: "create a VCA group called Drums", ops: ["add_vca"], params: ["add_vca": ["name": "Drums"]]),
        HoldoutCase(goal: "turn the Voices VCA down to -4 dB", ops: ["set_vca"], params: ["set_vca": ["vca": "{voices}", "gainDB": "-4"]]),
        HoldoutCase(goal: "tysta VCA-gruppen Voices", ops: ["set_vca"], params: ["set_vca": ["vca": "{voices}", "muted": "true"]]),
        HoldoutCase(goal: "remove the Voices VCA", ops: ["remove_vca"], params: ["remove_vca": ["vca": "{voices}"]]),
        // The same words, meaning something else.
        HoldoutCase(goal: "limit the peaks to -1 dBTP", ops: ["limit"], params: ["limit": ["ceiling": "-1"]]),
        HoldoutCase(goal: "master the episode for Spotify", ops: ["loudness_preset"], params: ["loudness_preset": ["preset": "spotify"]]),
        HoldoutCase(goal: "send it to Flimmer", ops: [], kind: "refuse"),
        // Two in one.
        HoldoutCase(goal: "freeze Erik and then set the master to -2 dB", ops: ["freeze", "set_master"],
                    params: ["freeze": ["strip": "{track2}"], "set_master": ["gainDB": "-2"]], kind: "multi"),
    ]
}
