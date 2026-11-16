# Restoration: what was measured

Numbers behind the repairs that have a claim to check. Hum, clipping and clicks are covered by their tests in `JammerCoreTests`; noise reduction is DeepFilterNet 3 (see `LICENSES.md`).

## Reduce Reverb (`restore` kind `dereverb`)

Weighted prediction error (WPE; Nakatani, Yoshioka, Kinoshita, Miyoshi and Juang, 2010), written here from the paper, no model and no dependency. In each frequency band up to 12 kHz the late reverberation is what can be predicted linearly from the band's own past, starting 3 frames (about 30 ms) back and over 24 frames (about 0.25 s); that prediction is subtracted, so the direct sound and early reflections stay. Three iterations. The variance each frame is weighted by is floored at 0.3 % of the band's mean power, which is what keeps noise between words from being lifted. Stereo is processed a channel at a time.

### Synthetic bursts (always run, `DereverbTests`)

Speech-shaped noise bursts at 48 kHz in a room of decaying noise, reverberation time 0.6 s, 6 dB under the direct sound.

| Case | Requirement | Measured |
|---|---|---|
| Tails 60–300 ms after each burst ends | down at least 6 dB | −44.9 → −51.6 dB (6.7 dB) |
| Closeness to the dry sound (SI-SDR) | better | 5.9 → 8.3 dB |
| Dry sound through the repair | level changed at most 0.5 dB | −0.02 dB (SI-SDR against itself 31.9 dB) |
| Amount 0 | bit-exact | bit-exact |
| Noise at 15 dB SNR added: the floor between bursts | lifted at most 1 dB | −39.8 → −39.8 dB (+0.02 dB) |

### Voices (`JAMMER_EVAL_DIR`, not in the repository)

Two macOS voices (Alva in Swedish, Samantha in English; clean and perfectly dry) and a LibriVox reader, 20 s each at 44.1 kHz, in the same kind of room. "Pauses" are the 20 ms frames where the dry voice is at least 45 dB under its loudest frame.

| Voice | Room | SI-SDR against the dry voice | Level in the pauses |
|---|---|---|---|
| Alva (sv) | 0.6 s | 8.4 → 11.8 dB | −34.5 → −44.8 dB |
| Alva (sv) | 1.0 s | 8.1 → 12.3 dB | −31.2 → −38.7 dB |
| Samantha (en) | 0.6 s | 5.4 → 6.6 dB | −35.4 → −40.8 dB |
| Samantha (en) | 1.0 s | 5.7 → 7.8 dB | −31.6 → −36.2 dB |
| LibriVox reader | 0.6 s | 7.8 → 9.7 dB | (no pauses under the recording's own noise) |
| LibriVox reader | 1.0 s | 7.7 → 10.2 dB | (same) |

Speed, release build, one channel: 0.7 s for 20 s of audio on its own (about 30 times faster than real time).

What it doesn't do: it takes the reverberation down by 5 to 10 dB, it doesn't remove it; early reflections (the boxy colour of a small room) are left; and what remains decays at the room's own rate, so the reverberation time measured afterwards is about the same even though the tail is quieter.

## The reverberation time in the analysis (`reverb.rt60`)

A blind estimate from how the level falls after sounds stop: 30 ms level values every 10 ms, each free decay of at least 12 dB fitted from 8 dB under its start (the first drop is the direct sound ending, not the room), the median of those. Calibrated on the two clean voices (up to 60 s) in rooms of known length:

| Room | Alva (sv) | Samantha (en) |
|---|---|---|
| dry | 0.14 s | 0.14 s |
| 0.3 s | 0.41 s | 0.34 s |
| 0.6 s | 0.66 s | 0.65 s |
| 1.0 s | 0.93 s | 0.93 s |
| 1.5 s | 1.30 s | 0.73 s |

So: within about 0.1 s up to a second; longer rooms read short, because speech rarely pauses long enough to show them. `present` is `rt60 ≥ 0.3`. It needs pauses and a noise floor some 20 dB or more under the voice: on the LibriVox recording, whose noise sits 20 dB under the reader, it answers `null` ("can't tell") for every room, and the app says "reverb not measurable" rather than a number.

A known false positive, found by an agent reading the guide cold (2026-11-15): on a dry synthetic voice with added noise, the estimate went from "can't tell" before noise reduction to 0.44 s (`present: true`) after it. The denoiser's own fade-outs after each word look like a room's decay to this estimator. So after `denoise`, the reverb figure is not to be trusted; the guide says so.

The same after `dehum` (cold read run 3, 2026-11-16): the preview of a hum removal went from not present to 0.51 s.

What it isn't (measured 2026-11-16 on the two voices, dry and in rooms of 0.3, 0.6 and 1.0 s, with white noise added): plain noise under the voice. Down to 25 dB signal-to-noise the dry voices still read 0.14–0.20 s and the rooms within their usual error; at 20 dB a dry voice reads 0.30–0.47 s, which is where the estimator should say "can't tell" and doesn't always. Fitting only the part of each decay that is 6, 10 or 15 dB clear of the floor was tried and made it worse (too few points left: dry voices at 30 dB read up to 0.70 s), so it was not kept. So it is the repair's own tails: the denoiser's release after each word and the ringing of narrow hum filters. Telling those from a room blindly is not something this estimator can do. So the estimate is not made at all on audio that has been through `denoise` or `dehum` (decided 2026-11-16: a meter that is wrong after Jämmer's own processing is worse than none). Each file a repair makes records the repairs its sound has been through (`repairs` on the source, carried into later files made from it: de-bleed, levelling, spectral edits, stems), and the analysis answers `rt60: null, present: null, unknown: "after_noise_reduction"`; the Repair sheet says "reverb not measurable after noise or hum removal". This also hides the figure where it would have been right.

## Noise floor (2026-11-16)

`noiseFloor` in the analysis: 50 ms frames, the quiet ones (within 4 dB of the level that 2 % of the frames are under, in runs of 150 ms or more), their mean power in dBFS, and how much pause that was. Reference: white noise added at a known RMS under a voice with pauses.

| Noise put in | Measured |
|---|---|
| −45, −55, −65, −75 dBFS | each within 1 dB (test `noiseFloor`) |

It answers nothing rather than a number for: noise alone, a steady tone, under a second of sound, speech that is digitally silent between its words (gated or edited: not a room), and a voice whose level only dips briefly between syllables. That last case is why a pause has to last 150 ms: measured in 50 ms dips the floor read several dB too high.

Not a loudness: it is plain RMS, not K-weighted, so it doesn't compare with LUFS figures.

## Click count (2026-11-16)

Found when a cold-reading agent saw the count rise after a hum removal: the count was not about clicks. The detector flagged every sample whose prediction error was over 12 times the block's usual error. A voice's pitch pulses and a note's attack are that large too, so clean synthetic voices read 60 to 190 "clicks" in 30 s and a synth song 300, and the number changed with where the measured stretch began (0, 5, 1 and 3 for overlapping stretches of one recording). The declick repair used the same detector and "repaired" them.

Now a click must also stand out from the block's own peaks: over 5 times what 1 % of the block's samples exceed (wide pulses fill more than that), and over 3 times its fifth-largest separate peak (sharp pulses come several to a block), judged with half a block of context on each side. Measured on eight recordings (30 s each, four block alignments), and with twenty clicks of one to three samples added at 1, 3 and 10 times the recording's RMS:

| Recording | False counts before | after | Added clicks found (×1, ×3, ×10) |
|---|---|---|---|
| Kitchen take (voice, hum, noise) | 0–10 | 0 | 20, 20, 20 of 20 |
| Episode 7 (voice) | 0–11 | 0 | 20, 20, 20 |
| Daniel, Flo (synthetic voices) | 63–189 | 1–3 | 20, 20, 20 |
| Church hall (voice in a room) | 0–41 | 0 | 20, 20, 20 |
| Booth | 76–265 | 0 | 20, 20, 20 |
| Demo song (synth music) | 299–320 | 0 | 4, 4, 7 of 7 |
| interview | 0–4 | 0 | 10, 10, 10 of 10 |

So: in speech every added click is found and nothing else is, bar one to three per 30 s on the two synthetic voices; in dense music a click has to be well over the music to be found. More than four clicks in 170 ms (dense crackle) hide each other from this detector; that is not what it is for. The table is the gated test `clickTable` (`JAMMER_CLICK_TABLE=1`); the permanent check is `clicksNotPulses`, a pulsed synthetic voice at four alignments.
