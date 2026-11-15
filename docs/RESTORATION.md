# Restoration: what was measured

Numbers behind the repairs that have a claim to check. Hum, clipping and clicks are covered by their tests in `JammerCoreTests`; noise reduction is DeepFilterNet 3 (see `LICENSES.md`).

## Reduce Reverb (`restore` kind `dereverb`)

In debug builds only until the patent question in `RELEASE.md` is decided (`Config/Features.xcconfig`). Weighted prediction error (WPE; Nakatani, Yoshioka, Kinoshita, Miyoshi and Juang, 2010), written here from the paper, no model and no dependency. In each frequency band up to 12 kHz the late reverberation is what can be predicted linearly from the band's own past, starting 3 frames (about 30 ms) back and over 24 frames (about 0.25 s); that prediction is subtracted, so the direct sound and early reflections stay. Three iterations. The variance each frame is weighted by is floored at 0.3 % of the band's mean power, which is what keeps noise between words from being lifted. Stereo is processed a channel at a time.

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
