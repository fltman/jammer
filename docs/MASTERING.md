# Mastering: limiter, sample rate, dither, delivery checks

Phase 3, part 1. What is built is said here with the numbers it was measured to; what isn't is listed last.

## Limit (true-peak limiter), built 2026-11-16

`limit` in the operation registry, **Audio › Limit Peaks…** in the app. Offline: the result is bounced into new files, like `echo` and `duck`.

**How it works** (`JammerCore/Limiter.swift`, `LimiterApply.swift`). For every frame the level is the highest of the samples and the oversampled points around it, over all channels; the oversampler is the meter's own (`TruePeak`: 4× at 44.1/48 kHz, 2× at 88.2/96, none from 176.4), so the limiter sees the peaks the meter will. Required gain = ceiling / level, at most 1 → the lowest required gain in the lookahead ahead → release (falls at once, rises with the time constant) → mean over the lookahead. Every value averaged for a frame is at most what that frame needs, so the applied gain never exceeds it. One gain for all channels and all limited tracks: it is found on the tracks' mix (their levels and mutes, not their plugins) and put on each track, so their sum is the limited mix.

**No delay.** The lookahead is hidden inside the processor; frame k out is frame k in. `latencySamples` in the answer is 0, and a test checks that an impulse and the zero crossings of a tone stay where they were.

**Untouched where nothing is needed.** Where the gain is 1 the samples are copied, never multiplied or filtered: the first and last seconds of the test document null against the original. Outside the range nothing is touched.

**The promise is kept by measuring.** A moving gain shifts inter-sample peaks a little, so the limiter aims 0.05 dB under the ceiling, the result is read as the meter reads it, and if it is over, the pass is run again 0.1, 0.2, 0.4 and 0.8 dB under; after that it fails in words rather than hand back audio over the ceiling. Hours of audio are done in blocks; only gains and blocks are held in memory.

**Measured** (48 kHz, release 100 ms, lookahead 5 ms; "after" read by `LoudnessMeter`, the meter validated against EBU Tech 3341/3342 and ffmpeg):

| Signal | Ceiling | True peak before | After | Aimed under by |
|---|---|---|---|---|
| Sine at fs/4, 45° phase, amplitude 1 (no sample over 0.7071) | −1 | −0.17 | −1.05 | 0.05 |
| Tone bursts at +6 dB | −0.1 / −1 / −3 | +6.64 | −0.15 / −1.05 / −3.05 | 0.05 |
| Full-scale impulse | −0.1 / −1 / −3 | 0.00 | −0.15 / −1.05 / −3.05 | 0.05 |
| White noise ×2 | −0.1 / −1 / −3 | +11.01 | −0.15 / −1.05 / −3.05 | 0.05 |
| White noise ×2 at 44.1 / 96 / 192 kHz | −1 | +10.85 / +10.04 / +6.02 | −1.05 / −1.05 / −1.05 | 0.05 |
| White noise ×2, release 1 ms, lookahead 0.5 ms | −0.1 | +11.01 | −0.12 | 0.10 (second try) |

**What "true peak" means here, exactly.** The fs/4 sine has a real peak of 0 dBTP and the meter reads −0.17: its 4× points fall 11.25° beside the crest at that frequency (20·log10(cos 11.25°) = −0.169 dB). That is inside the 0.3 dB the meter is held to, and it is what a four-times oversampling meter of the BS.1770 kind does. The limiter uses the same points, so after limiting to −1 that signal's real peak is −0.88 dBTP. The ceiling is therefore kept *as a BS.1770 meter reads it*, not analytically; the manual says so. Reading finer (8× or more) would change the meter that the loudness tests are calibrated with, so it is a decision of its own, not made here.

**Proved by planting a fault**: with detection on sample peaks only, the fs/4 test fails ("couldn't keep the true peak under −1.0 dBTP (it came to −0.17)") and six others with it; with the tracks written unlimited, the document tests fail.

**Refused in words**: a peak already under the ceiling (422 `nothing_to_do`), nothing in the range, a track that isn't there (`not_found`), and values outside ceiling −20…0 dBTP, release 1…2000 ms, lookahead 0.5…20 ms, including NaN and infinity, before any audio is read.

**Known limits.** At the edges of a range the gain can step (the audio outside is not touched, so the gain can't ramp there); for the whole document there is no edge. A track's plugins come after the limiter and are not in its figures (`beforePlugins` in the answer). The last ~16 frames of a file are read by the meter as sample peak only; the limiter does see them.

**In the app** (2026-11-16): the sheet read through the accessibility API (ceiling field named, no unnamed controls); a ceiling of 5 refused with "The ceiling has to be a number from −20 to 0 dBTP"; the limiter run from the menu and offered back as "Undo Limit". The before and after figures were not read in the app in that pass.

## Not built yet

- `loudness_preset` with `limit` (reach the target when the peaks hold it back, and say what dynamics it cost).
- The `acx` check against ACX's published requirements.
- Sample-rate conversion on export (r8brain-free-src, MIT; to be fetched only when Anders has said yes) and dither when the bit depth goes down.
- The limiter as a live insert comes with the mixer, after its realtime measurements.
