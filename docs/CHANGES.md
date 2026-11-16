# Changes that someone could notice

Not a list of commits: what behaves differently from before, for a user, an agent, or a file. Newest first.

## 2026-11-16

- **The mixer's first part**: buses, pan and routing (`docs/MIXER.md`). A project that uses them is saved as project format 2, which a Jämmer from before refuses with "saved by a newer Jämmer"; a project that doesn't is format 1 and byte for byte what it was. `GET …/tracks` has `pan` and `output` on each track.

- **Importing a file at another sample rate than the document's now converts with r8brain** (the same converter that exports use), where it used the system's converter. Measured on the same file through both: the same length, and the same audio within −145 dB for a signal under 18 kHz (`ResamplerTests.importAgrees`). Projects made before this point at files that were already converted when they were imported; those files are not touched, so an old project plays exactly as it did. A build without r8brain falls back to the system's converter.
- **Still on the system's converter**, and so not the same converter yet: drift correction (`correct_drift`, which stretches by a few parts per million to a rate that isn't a standard one), noise reduction and stem separation (which convert to their model's rate and back; the models were measured with that converter), and the 16 kHz copies made for transcription and speaker analysis (never heard). They change when those parts are next worked on.
- **Files handed to Flimmer at Flimmer's sample rate** are converted with r8brain too, like an export (`ResamplerTests.flimmerHandOver`: the file is the converter's output rounded to 24 bits).
- **Exports can be at another sample rate** (`sampleRate` on `export` and in a batch's `export`, **Sample rate** in the export sheet). Default unchanged: the document's own rate.
- **Dither is added only to samples that rounding would change.** Before, every sample got it. Audio already at the target bit depth now comes out bit for bit, and digital silence stays silent. The level of the dither on everything else is the same (`DitherTests`).
- **`loudness_preset`** takes `limit`; without it nothing changed.
- **A linked document** follows its file while open: `linkedFile.available` in the agent API can change from true to false and back without a restart. The same file handed over again no longer opens a second document.
- **The assistant**: a step that changes the document without the request naming it waits for a yes; a measured value is always written by Jämmer, never by the model; ⌥⌘A puts the cursor in the assistant's field and hides the panel only from there (it used to toggle the panel).
- **`GET …/transcript`**: `textOnly`, and for a word nobody knows the time of, `start` and `end` are null with `"untimed": true`. Words from the engines on this Mac are as before.
