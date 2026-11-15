# Stem separation

`separate` (Audio › Separate Stems) uses Spleeter's 4stems model. Why not HTDemucs, which the plan first named: its author states that the weights aren't covered by the code's MIT licence and are for research only (see `LICENSES.md`).

## How it's built

- **Weights:** Deezer's own release (`4stems.tar.gz`, v1.4.0, 146 MB, SHA-256 `3adb4a50…dfaa8`, MIT), downloaded by the user in Settings › Models. Jämmer reads the TensorFlow checkpoint itself (`TFCheckpoint`: the bundle index is a LevelDB-style table), so no converted copy is hosted anywhere. All 296 tensors read identically to TensorFlow.
- **Network:** the four U-Nets on MPSGraph (system framework), after `spleeter/model/functions/unet.py`. Against TensorFlow's own ops on the same input: 110–137 dB SNR per stem.
- **Separation:** 44.1 kHz stereo, 4096-sample Hann frames, hop 1024, the lowest 1024 bins, ratio masks with exponent 2 applied to the mix's own spectrum (so its phase), streamed in 512-frame blocks. One deliberate difference from Spleeter, which leaves everything above 11 kHz out of every stem: here whatever the masks don't cover goes to "other", so the stems add up to the original.

## Measured (2026-11-15)

| What | Result |
|---|---|
| Sum of stems minus the original (null test), 44.1 kHz stereo | −138 dB |
| The same through a 48 kHz mono project (resampled in and out) | −82 dB |
| A 15 kHz tone | all of it in "other" |
| Synthetic song (spoken voice, bass line, drum hits), SI-SDR in the mix → in its stem | voice −7.0 → 22.0 dB; bass 6.6 → 31.5 dB; drums −18.4 → −1.6 dB |
| In the app: mix loudness and true peak before and after separating | −13.85 LUFS, −3.99 dBTP both times |
| Speed | 8 s of audio in 3.2 s in the package test; 8 s in the debug app |

## Caveats

- The reference is TensorFlow's ops following Spleeter's network code, not Spleeter's command-line tool, which wouldn't install here (an old dependency doesn't build). The STFT, masking and inverse are our own, tested by the null test and by the stand-in network in `StemTests`.
- The song is synthetic; the drums (noise bursts) are a hard case and real music will differ. The stem levels of that song are pinned as a golden, and the test writes listenable stems when `JAMMER_SPLEETER_DIR` is set.
- Spleeter is from 2019; newer models separate better, but none we found has weights that everyone may use.
