# Tempo and beats

`GET …/analysis/rhythm` and the `detect_tempo` step (Audio › Detect Tempo). The beat tracking is the system's: `MusicUnderstandingSession(asset:).analyze(for: [.rhythm])` (macOS 27, on this Mac). Jämmer renders the range to a temporary file, has it analysed as a whole and in two halves, and decides whether to believe the answer. No model is fetched and nothing leaves the Mac: it gives the same answers with outgoing network blocked (`sandbox-exec -f scripts/no-network.sb`, tried 2026-11-16 outside the app and in it: the same tempi, the same refusals).

## Why the answer is judged

The tracker has a tempo for anything. Measured 2026-11-16:

| Sound | The tracker says | True |
|---|---|---|
| clicks at 120, 93; drums at 140, 72 | 120.00–120.06, 93.00, 140.00, 72.00 | the same |
| clicks at 174 | 87.00 | 174: half speed |
| a synthesised song at 120 | 120.00 | 120 |
| seven speech recordings | 60.9 to 129.4 | no tempo |
| four of the Mac's voices reading a text | 70.4 to 91.8 | no tempo |
| white noise | 83.4 | none |
| digital silence | 40.0 | none |

And it doesn't answer the same way twice: for the 120 click track, one run in ten gave beats on an exact grid (0.000, 0.500, 1.000 …) and nine gave 0.013, 0.515, 1.016 … with spacings up to 3.4 % off. So how regular its beats are says nothing (noise read more regular than the click track on most runs).

## What decides

1. **Pulse**: Jämmer's own measure, the same for the same sound every time. The onsets of the sound (the rise in level between 5 ms steps) are correlated with themselves at the beat length the tracker gave, and at half of it; the larger, as a share of the onsets' energy.

   | Sound | Pulse |
   |---|---|
   | clicks and drums | 0.70–0.96 |
   | the song (and three of it in a row) | 0.35, 0.34 |
   | eleven speech files, at the tracker's beat | 0.08 or less (0.13 at the best of any lag) |
   | noise | 0.05 |
   | silence | 0 |

   The line is at 0.18.
2. **The halves agree**: the tempo of the first half, of the second half and of the whole within 1 % of each other. Music: within 0.3 %. Speech: mostly tens of percent apart. This is what refuses music whose tempo changes; one tempo is all the first version sets.
3. **There is sound**: a peak over −70 dBFS, and at least 8 s of it.

The tempo that is reported is the slope of a line through the tracker's beats, the first beat where that line starts; the tracker's own figure is not used.

## Checked by

`RhythmReferenceTests` (runs the system's analysis): five known tempi within 0.1 BPM and the first beat within 20 ms, also from the middle of the file; 174 comes back as 87 with 174 among the alternatives, and `multiply: 2` gives it; eight speech cases (four voices, two texts), noise, a steady tone and silence are refused; under 8 s is refused. With `JAMMER_TEMPO_DIR` the test recordings too: seven speech recordings refused, the song 120.0. Run three times in a row without a wrong answer. `RhythmTests`: the judgement, the pulse measure and the tempo map without the system.

## Not known, and not claimed

- **Bars.** The tracker's bar starts were wrong on the synthetic files (the accented beat was not the one it called a bar start, and some "bars" had three beats). They are not passed on; bar numbers on the ruler count from the first beat.
- **Real recordings of music** with a played, slightly uneven beat. None has been through it; the pulse of dense music is lower than a click track's (0.35 for the one song), so some real music may be refused. A refusal is the safe side: the tempo can be given with `bpm`.
- **Tempo changes.** Refused by the halves test, not followed.
- **Half and double tempo** is the caller's to put right (`alternatives`, `multiply`, `bpm`).
