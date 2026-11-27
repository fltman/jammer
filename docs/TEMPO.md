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
2. **The halves agree**: the tempo of the first half, of the second half and of the whole within 1 % of each other. Music: within 0.3 %. Speech: mostly tens of percent apart. Music whose halves disagree is not one tempo; it goes on to the tempo map below.
3. **There is sound**: a peak over −70 dBFS, and at least 8 s of it.

The tempo that is reported is the slope of a line through the tracker's beats, the first beat where that line starts; the tracker's own figure is not used.

## Tempo that changes (2026-11-27)

When the halves disagree, the tempo may change. **The tracker is not used for this**: it keeps one tempo through a reading and locks wrong around a change (on clicks at 120 → 90 → 140 it gave beats a third of a beat off the clicks for seconds after each change, read whole or in 16 s windows). The stretches are Jämmer's own, from the sound (`Rhythm.ownStretches`), up to 600 s of it:

1. **A tempo for every 6 s**, a second apart: the autocorrelation, between 0.25 and 1.5 s, of the onsets smoothed over ±20 ms (a played beat is early or late by some ms; unsmoothed, a beat-to-beat unevenness of 15 ms made the double beat win), the shortest lag at least 0.8 of the strongest (so a bar's accent doesn't win), between steps by a parabola. A window without a pulse (under 0.18) has none.
2. **Runs** of at least three windows within 1.5 % of their median are stretches. A run at twice the beat of another run is the same beat with an accent on every other one (a kick and a snare read 1.2 s for a few windows of 100 BPM), and takes the shorter beat. A double-time change therefore reads as the same beat counted on.
3. **A glide**: windows one after the other, each with a pulse, whose beat moves one way, over 6 % in all, with at least three windows at levels between those at its ends, are refused with `tempo_glides`, saying about from what to what and between when (a map of steps would only roughly follow it). Nothing is changed. A step has no windows between: each reads the old beat or the new.
4. **Each stretch's beats** are the onset peaks on its grid (within 25 ms), its tempo and phase a line through them. A change is the first peak on the new grid after the last on the old one; the beat between them has the old tempo's length, the new one's, or its own (a **bridge**, one beat).
5. **Checked against the sound**, as one tempo is: every stretch's pulse at its beat at least 0.18 and at least half of its onsets on its grid. One stretch that fails refuses the whole map.

The map has a tempo per stretch, each starting on its first beat, with a whole number of beats between changes, so the bars stay whole. When the tracker finds no usual beat with a pulse (speech, but also a glide), only a glide is taken from the sound.

Measured on made-up sound (clicks; a kick on every beat with a snare on every other):

| Sound | Found |
|---|---|
| clicks 120 → 90 → 140, 16 s each | 120.00 from 0.200, 90.00 from 16.200, 140.00 from 32.200 |
| drums 100 → 128, 20 s each | 100.00 from 0.200, 128.00 from 20.600 |
| clicks 140, gliding to 100 over 30 s, then 100 | refused: 140 to 100 between 0:09 and 0:42 (true: 0:10 to 0:40) |
| clicks at 120, ten runs | one tempo every time |
| speech, noise, silence | refused, as before |

## Checked by

`RhythmReferenceTests` (runs the system's analysis): five known tempi within 0.1 BPM and the first beat within 20 ms, also from the middle of the file; 174 comes back as 87 with 174 among the alternatives, and `multiply: 2` gives it; eight speech cases (four voices, two texts), noise, a steady tone and silence are refused; under 8 s is refused. With `JAMMER_TEMPO_DIR` the test recordings too: seven speech recordings refused, the song 120.0. Run three times in a row without a wrong answer. `RhythmTests`: the judgement, the pulse measure and the tempo map without the system. For a tempo that changes: `RhythmReferenceTests` (the whole estimate, with the system's tracker) on the steps and the glide above, and a steady tempo ten times; `TempoChangeTests` (`ownStretches` alone): three sets of steps, a bridge with every click on the map's grid within 20 ms, seven steady tempi from 72 to 174, each beat up to 8 ms early or late (up to 15 ms from beat to beat; clicks, and drums at 100 and 128), that never grow a change and come back at their own speed, the glide, and clicks on no grid, silence and 10 s refused.

## Not known, and not claimed

- **Bars.** The tracker's bar starts were wrong on the synthetic files (the accented beat was not the one it called a bar start, and some "bars" had three beats). They are not passed on; bar numbers on the ruler count from the first beat.
- **Real recordings of music** with a played, slightly uneven beat. None has been through it; the pulse of dense music is lower than a click track's (0.35 for the one song), so some real music may be refused. A refusal is the safe side: the tempo can be given with `bpm`.
- **Tempo changes in real music.** Only made-up steps have been through it. A played change that eases in over a bar or two may read as a glide and be refused; that is the safe side. A glide is not followed, only said.
- **Steps under 8 s** (two windows' worth) are not found: such music is refused as a whole.
- **Half and double tempo** is the caller's to put right (`alternatives`, `multiply`, `bpm`).
