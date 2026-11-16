# Changes that someone could notice

Not a list of commits: what behaves differently from before, for a user, an agent, or a file. Newest first.

## 2026-11-16

- **A cancelled freeze stops and leaves no file** (seen in the app: job `cancelled`, the track live, the media folder's count unchanged). **Soloing, exporting or measuring some tracks keeps the keys their plugins listen to** (debug builds, where keys exist).

- **Freezing** (`docs/MIXER.md`, step 7): `POST …/freeze` (a job) and `POST …/unfreeze`; `frozen` on strips in `GET …/mixer`; steps that would change what a frozen strip was made from fail with `reason: "frozen"`. A project with a frozen strip is format 2.

- **The plugin scanner could call a good plugin invalid on a busy Mac**, and the catalogue kept that until the bundle changed. Cause: the helper's answer was read both by a background handler and by the caller, and the verdict could be taken between the handler's read and its storing ("0 bytes out, exit 0"). Shown by slowing the handler (6 of 6 probes of a good plugin "invalid"); not reproduced by load alone in 60 probes. Now one reader per pipe and the verdict waits for both (the same slowing: 6 of 6 found; 80 of 80 under load).
  - Verdicts are kept apart: `invalid` only when the helper itself says the bundle isn't a plugin; no answer at all is `scan_failed` (new); `timed_out` as before. `timed_out` and `scan_failed` are tried again at every scan A bundle that has run out of time two scans running is then tried only at every fifth scan, or when a scan is forced (the Plugins sheet's scan button, `force` in the API), so a plugin that really hangs doesn't cost its time limit at every start; the sheet names it.
  - A plugin an earlier scan found stays listed through a failed scan, with `kept: true` in `scan.failed`; a crash or "not a plugin" replaces it only when it comes twice running.

- **A name Jämmer doesn't know is refused, never skipped** (SIBLINGS.md §3). 400 `bad_request` with the name and what the call takes; nothing is done. What the walk through found, all of it silent before:
  - Steps already refused unknown parameters (from the registry). A field beside `op` and `params` in a step was ignored: now refused.
  - **Every query parameter on every endpoint** was ignored when unknown (`GET …/analysis?brightness=3` answered 200): now refused, from one table of what each route takes (`RouteParameters.swift`), which the registry's endpoints add their parameters to.
  - JSON bodies of `export`, `transcribe`, `separate`, `diarize`, `play`, `solo`, `plugins/scan`, document and track creation, and the `/steps` body itself ignored unknown fields: now refused. `restore`, `restore/preview`, `batch` and `import/fcpxml` already refused them at the top level.
  - `batch`: a field beside `op` and `params` in a job, and an unknown parameter of a job, were ignored: now refused. `export` that isn't an object was read as "no export settings": now refused. (Unknown fields inside `export` were refused already; I first wrote that they weren't.)
  - The assistant, calling a sibling or one of Jämmer's own endpoints, sent names the schema doesn't have: now the call isn't made and the plan says why.
  - `rationale` (a string) is accepted everywhere and used for nothing, and is in every published schema. Every schema is closed (it already was); `restore`'s settings that belong to one kind only are published under `x-byType` on the operation's params schema, with `"x-byTypeKey": "kind"` beside it (SIBLINGS.md §3); a kind with none has an empty closed schema. Jämmer reads a sibling's table the same way, and doesn't send a name from a table that has no key.
  - What Jämmer sends Flimmer (Send to Flimmer: the uploads and the plan) was compared with `SEND-TO-FLIMMER-API.md` name for name: every query parameter and every field is one the sketch has. The plan's names are now a closed list in the code (`FlimmerSend.planFields` and the lists beside it), checked before anything is sent. Not run against a Flimmer that has the endpoint: it is still a sketch there.
  - A caller that sent a misspelt or invented name and got 200 before gets 400 now. Glimmer's waveform request (`GET …/waveform?width=`) is unaffected, and the cover flow was run once against Glimmer's build 11afa8b.

- **Sidechain keys, debug builds only** (`docs/MIXER.md`, step 6): `set_insert` `key`; `key`, `hasKeyInput`, `keyRefusal` on listed inserts. A release build has none of it. A project whose plugin has a key is format 2.

- **Solo** as a way of listening: `POST …/solo`, `solo` in `GET …/mixer`, a Solo box on every strip. Not saved, not undone, and no export or measurement changes. The mixer sheet is wider (1070 points).

- **VCA groups** (`docs/MIXER.md`, step 5): `add_vca`, `set_vca`, `remove_vca`; `vcas` in `GET …/mixer`, and `vca` and `heard` on every track and bus there. A project with a group is format 2.

- **The light behind the icon on the start screen breathes** (one breath in four seconds). It stands still with Reduce Motion, while any document plays, and when the window is covered or the app is in the background; with it in front the app idles at 0.0 % of a core. The start screen's window is now called "Welcome to Jämmer" to VoiceOver.

- **The master strip** (`docs/MIXER.md`, step 4): `set_master`, plugins on `track: "master"`, `master` in `GET …/mixer`. With its limiter on, an export measures its file and renders again until the ceiling holds, answers `X-Jammer-Master-Limiter`, and fails with 422 `ceiling_not_met` and no file when it can't. A project whose master does something is format 2.

- **`underruns`** in a document's summary and in the answer to `stop`: gaps heard since playback started. Read only.

- **Plugins on buses, with delay compensation across the mixer** (`docs/MIXER.md`, step 3). `add_insert`, `set_insert` and `remove_insert` take a bus's id as `track`; `GET …/buses/{busId}/inserts/{insert}`; `GET …/mixer` has `inserts` on buses, `latencySamples` and `compensationSamples` on every strip and `totalLatencySamples`. A project without plugins on a bus renders as before, bit for bit. `limit` answers `beforePlugins` also when the plugins are on a bus.

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
