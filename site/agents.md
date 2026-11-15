# Jämmer: guide for agents

Jämmer 0.1.0 is a native macOS audio editor (speech, restoration, post). This page tells an agent how to drive the running app through its local HTTP API. Everything here works today; nothing else does yet.

- Base URL: `http://127.0.0.1:9003` (this Mac only; the server listens on loopback). Before you change anything, check that `app.name` in `GET /api/v1/status` is exactly `"Jammer"` (ASCII, no ä). The window and splash say "Jämmer"; it's the same app. Glimmer and Flimmer run similar APIs on nearby ports.
- Every request that isn't a GET needs the header **`X-Jammer-Agent: 1`**. Without it you get `403 forbidden`.
- Don't send an `Origin` header: requests that look like they come from a web page are refused.
- Audio travels in request and response bodies. The API never reads or writes file paths.
- Edits land in document windows the user can see, and can be undone. One `steps` request is one undo step. The source files are never changed.
- Times are in **seconds** (decimals allowed). Jämmer rounds them to the nearest sample; replies give both seconds and frames.
- Steps that cost money are refused unless you pass `"allowPaid": true`. Nothing costs money yet: all processing runs on the Mac.

## Quick start

Run these in order. Replace `talk.wav` with any audio file (WAV, AIFF, MP3, AAC/M4A, FLAC, ALAC, CAF).

```sh
BASE=http://127.0.0.1:9003

# 1. Is Jämmer there? Check "app": {"name": "Jammer", …}.
curl -s $BASE/api/v1/status

# 2. Open the file as a new document. The reply contains its id.
curl -s -X POST -H 'X-Jammer-Agent: 1' -H 'Content-Type: audio/wav' \
     --data-binary @talk.wav "$BASE/api/v1/documents?name=Talk"
# → {"document": {"id": "3F2A…", "duration": 754.2, …}}
ID=3F2A…

# 3. Measure it: loudness (LUFS), loudness range, true peak.
curl -s $BASE/api/v1/documents/$ID/analysis

# 4. Edit: cut the first 2.5 seconds, fade in, then bring it to -16 LUFS.
curl -s -X POST -H 'X-Jammer-Agent: 1' -H 'Content-Type: application/json' \
     -d '{"steps": [{"op": "delete", "params": {"start": 0, "end": 2.5}},
                    {"op": "fade_in", "params": {"start": 0, "end": 0.5}},
                    {"op": "normalize", "params": {"target": "loudness", "level": -16}}]}' \
     $BASE/api/v1/documents/$ID/steps

# 5. Export the result as a 24-bit WAV.
curl -s -X POST -H 'X-Jammer-Agent: 1' -H 'Content-Type: application/json' \
     -d '{"format": "wav", "bitDepth": 24}' $BASE/api/v1/documents/$ID/export -o talk-edited.wav
```

Opening a document answers `201 Created`. To send the audio inside JSON instead: `-d '{"audio": "<base64 of the file>", "name": "Talk"}'`. Files over 256 MB go through uploads (below).

## Endpoints

| Method | Path | What it does |
|---|---|---|
| GET | `/jammer` | This guide (Markdown). |
| GET | `/api/v1/status` | App name and version, API version, port, open documents. |
| GET | `/api/v1/operations` | Every step operation with its parameters (JSON). |
| GET | `/api/v1/documents` | The open documents. |
| POST | `/api/v1/documents` | Open audio: raw bytes (`Content-Type: audio/…` or `application/octet-stream`, optional `?name=`), JSON `{"audio": "<base64>", "name"}`, or JSON `{"upload": "<id>", "name"}`. |
| GET | `/api/v1/documents/{id}` | Duration, sample rate, channels, tracks and clips, markers, tempo, selection, playhead. |
| POST | `/api/v1/documents/{id}/steps` | Run steps in order. Body: `{"steps": [{"op": "…", "params": {…}}], "allowPaid": false}`. |
| POST | `/api/v1/documents/{id}/undo` | Undo the last change (a whole `steps` request counts as one). |
| POST | `/api/v1/documents/{id}/redo` | Redo. |
| GET | `/api/v1/documents/{id}/analysis` | Loudness of the document, or of `?start=&end=` (seconds): integrated LUFS, range LU, max momentary and short-term, sample peak dBFS, true peak dBTP. |
| GET | `/api/v1/documents/{id}/waveform` | Min/max per column for `?width=` columns (default 200, max 4000), optionally over `?start=&end=`. Lets you see where the sound is. |
| POST | `/api/v1/documents/{id}/export` | The rendered audio as bytes. Body: `{"format": "wav"\|"aiff"\|"flac"\|"alac"\|"aac"\|"opus"\|"mp3", "bitDepth", "bitRate", "start", "end", "dither"}`; all optional (24-bit WAV of everything by default). bitDepth: wav 16, 24 or 32; aiff, flac, alac 16 or 24. bitRate: aac 64000–320000 (default 192000), opus 16000–256000 (default 96000; Ogg Opus, mono or stereo), mp3 64000–320000 in standard steps (default 160000). The formats this copy of Jämmer can write are listed in `GET /api/v1/operations` (export). `"chapters": true` (default) writes the markers as chapters: ID3 CHAP in mp3, a QuickTime chapter track in aac and alac (as Apple Podcasts reads them), CHAPTERxxx comments in opus; wav keeps markers as cue points; aiff and flac have none. Content-Type follows the format; only WAV carries Broadcast Wave metadata and markers. Up to 2 GB per response; export a range for more. |
| POST | `/api/v1/documents/{id}/transcribe` | Starts transcribing the document (a job, see below). Body: `{"language": "sv-SE", "engine": "auto"}`; both optional (the Mac's language and the best engine for it). `engine`: `auto`, `apple`, `parakeet` (25 European languages) or `whisper` (KB-Whisper, Swedish). Models are installed by the user in Jämmer's Settings, never by the API; asking for one that isn't there answers 422 with reason `model_missing`. Answers `202` with the job. |
| GET | `/api/v1/documents/{id}/transcript` | The transcript as it plays now: `{"words": [{"id", "text", "start", "end", "confidence", "speaker", "partial"}], "text", "speakers": [{"id", "name"}]}`, times in seconds on the timeline, optionally over `?start=&end=`. Empty until transcribed. |
| GET | `/api/v1/documents/{id}/analysis/restoration` | Looks for problems without changing anything: mains hum (frequency, how prominent), clipping (runs, samples, level) and clicks, over `?start=&end=` and `?tracks=id,id` (default: the selection, else everything; all tracks). Long ranges are sampled. |
| POST | `/api/v1/documents/{id}/restore/preview` | The repaired audio of a stretch (at most 30 s), without changing the document. Same body as `restore`, with `start` and `end`. Answers a 24-bit WAV; with `Accept: application/json` it answers `{"before": {…}, "after": {…}}` instead: the detector numbers plus `integratedLUFS` and `truePeakDBTP`. |
| POST | `/api/v1/documents/{id}/restore` | Repairs audio (a job). Body: `{"kind": "dehum"\|"declip"\|"declick", "amount": 0–1, "start", "end", "tracks": [id], "humFrequency", "sensitivity"}`; only `kind` is required. The repaired clips play from new files; the originals are untouched and one undo step brings them back. |
| POST | `/api/v1/documents/{id}/tracks` | Adds a track from audio sent like `POST /api/v1/documents` (bytes, base64 or upload; `?name=`). Answers `201` with `{"track": {"id", "name"}, "document"}`; one undo step. For double-enders, add each speaker's recording and the call recording, then run `align_tracks`. |
| GET | `/api/v1/documents/{id}/tracks/{trackId}/drift?against=<trackId>` | How far two recorders' clocks part: `{"drift": {"ppm", "msPerHour", "confidence"}}`. Needs at least 90 s of overlap. |
| GET | `/api/v1/documents/{id}/tracks` | The tracks with their ids, clips and plugins (`inserts`). |
| GET | `/api/v1/documents/{id}/tracks/{trackId}/inserts/{insert}` | One plugin: `{"insert": {"id", "plugin", "name", "bypass", "latencyMs", "factoryPresets", "params": [{"identifier", "name", "unit", "min", "max", "value"}]}}`. |
| GET | `/api/v1/documents/{id}/history` | The history tree: `{"current", "pruned", "limit", "nodes": [{"id", "parent", "action", "time", "branch"}]}`. A change made after an undo starts a branch; the old future stays reachable. |
| POST | `/api/v1/documents/{id}/history/{node}` | Goes to that step (any branch). One undo step; `undo` goes back. |
| GET | `/api/v1/plugins` | The Audio Unit effects installed on this Mac, optionally filtered by `?q=`: `{"plugins": [{"id", "name", "manufacturer", "kind", "version", "v3"}], "safeMode"}`. |
| POST | `/api/v1/documents/{id}/diarize` | Finds who speaks when (a job). Body: `{"mode": "by_track"\|"ml", "tracks": [id], "speakers", "minSpeakers", "maxSpeakers"}`; all optional. The result has `speakers` (names) and `seconds` (each one's speaking time) in order of id. |
| GET | `/api/v1/documents/{id}/speakers` | `{"speakers": [{"id", "name", "seconds"}], "turns": [{"speaker", "track", "start", "end"}]}`, as it plays now, optionally over `?start=&end=`. |
| GET | `/api/v1/documents/{id}/chapters` | The markers as Podcasting 2.0 chapters: `{"version": "1.2.0", "chapters": [{"startTime", "endTime", "title"}]}` (Content-Type `application/json+chapters`), optionally over `?start=&end=`. |
| GET | `/api/v1/jobs/{id}` | A job's state. |
| DELETE | `/api/v1/jobs/{id}` | Cancels a job. |
| POST | `/api/v1/documents/{id}/play` | Starts playback in the document's window, from `{"at": seconds}` or the playhead. Only works when the window is visible. |
| POST | `/api/v1/documents/{id}/stop` | Stops playback. |
| POST | `/api/v1/uploads` | Starts an upload for a big file. Answers `{"upload": {"id": "…", "size": 0}}`. |
| PUT | `/api/v1/uploads/{id}?offset=N` | Appends a chunk (≤ 256 MB). `offset` must equal the bytes received so far. |
| GET | `/api/v1/uploads/{id}` | How many bytes have arrived. |
| DELETE | `/api/v1/uploads/{id}` | Throws an upload away. |

Document ids are stable while the window is open. A document a sibling app handed over to edit (SIBLINGS.md §6) has `"linkedFile": {"name", "format", "requester"}` in the document list; the user saves it back with ⌘S, and the API never writes that file. `GET /api/v1/documents` also lists documents the user opened.

### Big files

```sh
UP=$(curl -s -X POST -H 'X-Jammer-Agent: 1' $BASE/api/v1/uploads | sed -E 's/.*"id" *: *"([^"]+)".*/\1/')
split -b 100m long.wav part.
OFF=0; for p in part.*; do
  curl -s -X PUT -H 'X-Jammer-Agent: 1' --data-binary @$p "$BASE/api/v1/uploads/$UP?offset=$OFF" >/dev/null
  OFF=$((OFF + $(stat -f%z $p)))
done
curl -s -X POST -H 'X-Jammer-Agent: 1' -H 'Content-Type: application/json' -d "{\"upload\": \"$UP\"}" $BASE/api/v1/documents
```

Uploads are deleted once they're opened, after an hour without new chunks, or when Jämmer quits. Jämmer checks free disk space before taking a chunk and answers `507 insufficient_storage` instead of filling the disk.

### Steps

A steps request runs every step in order and stops at the first failure. Then nothing from the request is applied: steps that had run are reported as `reverted`, later ones as `skipped`. The reply lists each step:

```json
{"results": [{"index": 0, "op": "delete", "status": "done"},
             {"index": 1, "op": "normalize", "status": "done", "info": {"gainDB": 3.4, "before": -19.4}}],
 "document": {…}}
```

Ranges: most operations take `start` and `end` in seconds. Without them they act on the selection (`select`, `select_all`); `gain` and `normalize` act on everything when there's no range and no selection. Edits work on all tracks at once, like a waveform editor.

## Errors

Errors are JSON: `{"error": {"code": "…", "message": "…"}}`. A failed step also gives its index: `{"error": {"code": "step_failed", "message": "…", "step": 1}}`.

| Status | Code | Meaning |
|---|---|---|
| 400 | `bad_request` | The body or a parameter is malformed. The message says which (and `step` which step). |
| 402 | `paid_not_allowed` | A step costs money and `allowPaid` wasn't `true`. |
| 403 | `forbidden` | Missing `X-Jammer-Agent: 1`, an `Origin` header, or a Host other than this Mac. |
| 404 | `not_found` | No such document, upload, path or operation. |
| 405 | `method_not_allowed` | Wrong HTTP method for the path. |
| 409 | `not_available` | Not possible right now: nothing to undo, the window isn't visible for playback, the upload offset is wrong. |
| 413 | `too_large` | A body over 256 MB (use uploads), an upload over 16 GB, or an export over 2 GB (export a range). |
| 507 | `insufficient_storage` | Not enough free disk space for the upload or export. |
| 422 | `step_failed` | A step ran and failed. `error.step` is its index; `results` has the status of every step. Some failures add `error.reason` (`ambiguous`, `not_found`) and numbers such as `error.matches`. |
| 422 | `unprocessable` | The request is fine, but the document doesn't allow it; `error.reason` says why (`no_hum`, `nothing_in_range`). Nothing started. |
| 500 | `internal` | Jämmer failed unexpectedly. The message has the detail. |

## Jobs

Work that takes a while (transcription) runs as a job. The request that starts it answers `202` with `{"job": {"id", "kind", "status", "progress"}}`. `status` is `queued`, `running`, `done`, `failed` or `cancelled`; `progress` goes from 0 to 1. Poll `GET /api/v1/jobs/{id}` every second or two. When it's `done`, `result` has a summary and the document has changed (one undo step); a failed job has `error: {code, message}`. `DELETE /api/v1/jobs/{id}` cancels. Running jobs are also listed under `jobs` in `GET /api/v1/status`. The user can keep editing while a job runs; words are anchored to the audio itself, so they land right regardless.

## Transcripts

A transcript is a view of the edit: it always reads what plays now. Each word has an `id` that stays the same across edits, undo, redo and saving, so you can keep ids between requests. Delete words with `delete_words` and `{"words": ["<id>", …]}`. You can pass `{"text": "…"}` instead, but it must match in exactly one place; otherwise the step fails with `reason: "ambiguous"` and `matches`, and you pick one with `occurrence` or all with `"all": true`. `correct_word` changes the spelling only.

## Restoration

Look, listen, then repair. `GET …/analysis/restoration` tells you whether there is hum, clipping or clicks. `POST …/restore/preview` with `Accept: application/json` gives the numbers before and after for a short stretch, so you can check that a repair helps (and that `amount` isn't too much) without listening. `POST …/restore` then runs it as a job. `dehum` finds 50 or 60 Hz by itself; pass `humFrequency` if it says `no_hum` and you know better. `amount` blends between the original (0) and the full repair (1). Use `tracks` to repair one speaker in a multitrack recording.

## Speakers

`POST …/diarize` labels the document with speakers as a job. For a double-ender (several tracks playing at once, one person per track) the default is `"mode": "by_track"`: each track is its speaker, named after the track, and bleed from the other tracks doesn't count. Otherwise it's `"ml"`, a diarisation model run on each track; tell it `speakers` when you know how many, especially for similar voices and short back-and-forth, where it's much weaker (docs/DIARISATION.md has the numbers). If `ml` finds only one speaker, the job's result has a `hint`: when the recording is a conversation, run it again with `speakers`, since the model often merges voices that sound alike. The first `ml` run downloads the model (about 20 MB); if that fails the job fails with `error.code` `model_unavailable`. Afterwards `GET …/speakers` lists who talks when, `GET …/transcript` gives each word a `speaker` id and lists `speakers`, and `rename_speaker` names them ("0" → "Anna"). Turns are anchored in the audio, so they stay right through edits.

## Plugins

A track can run through Audio Unit effects (AUv2 and AUv3) before its gain. `GET /api/v1/plugins` lists what's installed; `add_insert` puts one on a track (by id like `aufx/lmtr/appl` or by its exact name) and answers its id in `info.insert`; `GET …/tracks/{trackId}/inserts/{insert}` lists its parameters with their ranges; `set_insert` changes one parameter, a factory preset or bypass; `remove_insert` takes it off. A value outside a parameter's range fails with `reason: "out_of_range"`; nothing is clipped. Every change is one undo step, settings are saved in the document, and each plugin's latency is compensated so the tracks stay in time. Exports and loudness measurements (including `normalize` and `loudness_preset`) hear the plugins. You can't open a plugin's window; the user can, under Audio › Plugins.

Plugins are third-party code that runs with Jämmer's rights. If one crashes or misbehaves, the right fix is safe mode (Audio › Plugins, or ask the user): every plugin then runs in a process of its own. Plugins whose developer isn't Apple always run that way, for safety. Errors: `plugin_not_found`, `plugin_unsupported_format` (it can't take the document's mono or stereo float audio), `plugin_failed` (it didn't start).

## Sibling apps

Glimmer and Flimmer call Jämmer the same way you do (see their own guides). They add `X-Sibling: <slug>`; Jämmer logs it and shows "Requested by …" in the window, and it gives no extra rights. `GET /api/v1/operations` lists every op with `params` as a JSON Schema, plus `paid`, `undoable` and `startsJob`, so an assistant can turn them into tools named `jammer.<op>`. `tier` is `"core"` for the 15 most useful ones and `"advanced"` for the rest: start from core when tools are scarce.

## Operations

These are the `op` values for `steps`, with their `params`. The same list is available as JSON from `GET /api/v1/operations`.

### `select`

Selects a range. Later steps without `start`/`end` act on it.

| Param | Type | Description |
|---|---|---|
| `start` | seconds | **Required.** Start in seconds. |
| `end` | seconds | **Required.** End in seconds. |

### `select_all`

Selects the whole document.

No params: `{"op": "select_all"}`

### `deselect`

Clears the selection.

No params: `{"op": "deselect"}`

### `set_playhead`

Moves the playhead (where paste and markers go by default).

| Param | Type | Description |
|---|---|---|
| `at` | seconds | **Required.** Position in seconds. |

### `delete`

Removes the range and closes the gap (everything after moves left).

| Param | Type | Description |
|---|---|---|
| `start` | seconds | Range start in seconds. With `end`, overrides the selection. |
| `end` | seconds | Range end in seconds. |

### `silence`

Replaces the range with silence without moving anything.

| Param | Type | Description |
|---|---|---|
| `start` | seconds | Range start in seconds. With `end`, overrides the selection. |
| `end` | seconds | Range end in seconds. |

### `cut`

Copies the range to Jammer's clipboard and removes it, closing the gap.

| Param | Type | Description |
|---|---|---|
| `start` | seconds | Range start in seconds. With `end`, overrides the selection. |
| `end` | seconds | Range end in seconds. |

### `copy`

Copies the range to Jammer's clipboard.

| Param | Type | Description |
|---|---|---|
| `start` | seconds | Range start in seconds. With `end`, overrides the selection. |
| `end` | seconds | Range end in seconds. |

### `paste`

Inserts the clipboard, pushing what follows to the right.

| Param | Type | Description |
|---|---|---|
| `at` | seconds | Where to insert. Defaults to the selection start, else the playhead. |

### `crop`

Keeps only the range.

| Param | Type | Description |
|---|---|---|
| `start` | seconds | Range start in seconds. With `end`, overrides the selection. |
| `end` | seconds | Range end in seconds. |

### `insert_silence`

Opens a silent gap.

| Param | Type | Description |
|---|---|---|
| `at` | seconds | Position in seconds. Defaults to the playhead. |
| `duration` | seconds | **Required.** Length of the gap in seconds. |

### `gain`

Changes the level of the range (the whole document without a range or selection).

| Param | Type | Description |
|---|---|---|
| `db` | number | **Required.** Change in dB, e.g. -3 or 2.5. |
| `start` | seconds | Range start in seconds. With `end`, overrides the selection. |
| `end` | seconds | Range end in seconds. |

### `fade_in`

Fades in over the range. The range must lie inside one clip per track.

| Param | Type | Description |
|---|---|---|
| `start` | seconds | Range start in seconds. With `end`, overrides the selection. |
| `end` | seconds | Range end in seconds. |
| `shape` | string | Fade curve. One of: `equal_power`, `linear`. |

### `fade_out`

Fades out over the range. The range must lie inside one clip per track.

| Param | Type | Description |
|---|---|---|
| `start` | seconds | Range start in seconds. With `end`, overrides the selection. |
| `end` | seconds | Range end in seconds. |
| `shape` | string | Fade curve. One of: `equal_power`, `linear`. |

### `normalize`

Sets the level of the range (the whole document without a range or selection) to a target.

| Param | Type | Description |
|---|---|---|
| `target` | string | **Required.** What to match. One of: `loudness`, `peak`, `true_peak`. |
| `level` | number | **Required.** Target: LUFS for loudness, dBFS for peak, dBTP for true_peak. E.g. -16 or -1. |
| `start` | seconds | Range start in seconds. With `end`, overrides the selection. |
| `end` | seconds | Range end in seconds. |

### `align_tracks`

Lines up separately recorded tracks (double-enders) by their sound. Use the call recording (Zoom, Riverside, phone), where everyone is heard, as the reference; without one, the track that matches the others best is used. Tracks without a clear match don't move.

| Param | Type | Description |
|---|---|---|
| `reference` | string | Track id to line up with. Default: the best-matching track. |
| `tracks` | list | Track ids to move. Default: all the others. |
| `window` | seconds | Seconds from the start to compare. Default 120. |

### `spectral_attenuate`

Lowers a frequency band inside the range (the selection without one), per track, rendered into a new file; the original audio is one undo away.

| Param | Type | Description |
|---|---|---|
| `low` | number | **Required.** Lower edge in Hz. |
| `high` | number | **Required.** Upper edge in Hz. |
| `db` | number | Change in dB, -80 to 0. Default -20. |
| `start` | seconds | Range start in seconds. With `end`, overrides the selection. |
| `end` | seconds | Range end in seconds. |
| `tracks` | list | Track ids. Default: every track. |

### `correct_drift`

Resamples a separately recorded track whose recorder's clock ran fast or slow, so it stays in sync to the end. Without ppm the drift is measured against another track; an uncertain measurement fails with reason drift_uncertain instead of guessing.

| Param | Type | Description |
|---|---|---|
| `track` | string | **Required.** The track to correct. |
| `against` | string | Track to measure against (the call recording is best). Default: the best-matching track. |
| `ppm` | number | The drift in parts per million (positive: it ran fast). Skips the measurement. |

### `spectral_edit`

Changes an area of the spectrogram, per track, rendered into a new file (the original audio is one undo away). action attenuate lowers it by db; heal rebuilds it from the sound just before and after (for short sounds such as clicks, coughs, a phone ringing: at most 0.5 s, longer fails with reason too_long; use attenuate). shape box takes start, end, low, high; polygon takes points [t1, f1, t2, f2, …] (seconds, Hz; at least three corners); brush takes points along the stroke plus radius (Hz) and radiusTime (s). Bad shapes fail with reason bad_shape.

| Param | Type | Description |
|---|---|---|
| `action` | string | **Required.** What to do. One of: `attenuate`, `heal`. |
| `shape` | string | **Required.** The area's kind. One of: `box`, `polygon`, `brush`. |
| `start` | seconds | Range start in seconds. With `end`, overrides the selection. |
| `end` | seconds | Range end in seconds. |
| `low` | number | box: lower edge in Hz. |
| `high` | number | box: upper edge in Hz. |
| `points` | numbers | polygon, brush: time (s) and frequency (Hz) pairs, flattened. |
| `radius` | number | brush: Hz around the stroke. Default 200. |
| `radiusTime` | number | brush: seconds around the stroke. Default 0.02. |
| `db` | number | attenuate: change in dB, -80 to 0. Default -20. |
| `tracks` | list | Track ids. Default: every track. |

### `level_speakers`

Brings every speaker to the same loudness with one gain each, measured over their own turns (needs diarize first; fails with reason no_speakers otherwise). A track that is one speaker gets track gain; a track with several is split in the pauses where the speaker changes. Run loudness_preset afterwards for the mix. info: speakers, maxChangeDB, limitedByMaxGain.

| Param | Type | Description |
|---|---|---|
| `target` | number | LUFS per speaker. Default -18. |
| `maxGain` | number | Largest change in dB, up or down. Default 12. |
| `speakers` | list | Speaker ids as strings ("0", "1"). Default: everyone. |

### `rename_speaker`

Gives a speaker a name, e.g. after diarize. Use it to pair up speakers found on different tracks.

| Param | Type | Description |
|---|---|---|
| `speaker` | string | **Required.** The speaker's id as a string ("0", "1", …) or current name. |
| `name` | string | **Required.** The new name. |

### `add_insert`

Puts an Audio Unit effect on a track, last in its chain unless position says otherwise; its latency is compensated. Plugins are third-party code running with Jämmer's rights. GET /api/v1/plugins lists what's installed. info has latencyMs; ids has the new insert's id.

| Param | Type | Description |
|---|---|---|
| `track` | string | **Required.** Track id. |
| `plugin` | string | **Required.** Plugin id from GET /api/v1/plugins (e.g. aufx/lmtr/appl) or its exact name. |
| `position` | number | Place in the chain, 0 first. Default: last. |
| `preset` | string | A factory preset, by name. |

### `set_insert`

Changes a plugin on a track: bypass, a factory preset, or one parameter by identifier (GET …/tracks/{track}/inserts/{insert} lists them with their ranges). A value outside the range fails with reason out_of_range; nothing is clipped. Send several steps to change several parameters at once.

| Param | Type | Description |
|---|---|---|
| `track` | string | **Required.** Track id. |
| `insert` | string | **Required.** Insert id (or its name when that's unique on the track). |
| `bypass` | boolean | True to bypass, false to switch back on. |
| `preset` | string | A factory preset, by name. |
| `parameter` | string | Parameter identifier, e.g. global.0, or its exact name. |
| `value` | number | The parameter's new value, in its unit. |

### `remove_insert`

Takes a plugin off a track.

| Param | Type | Description |
|---|---|---|
| `track` | string | **Required.** Track id. |
| `insert` | string | **Required.** Insert id (or its name when that's unique on the track). |

### `loudness_preset`

Brings the range (the whole document without a range or selection) to a delivery target in one step. Without a limiter, the gain stops where the true peak would pass the ceiling; info.limitedByPeak is then 1 and integratedAfter shows what was reached.

| Param | Type | Description |
|---|---|---|
| `preset` | string | **Required.** The target. One of: `apple_podcasts`, `spotify`, `youtube`, `ebu_r128`, `atsc_a85`. |
| `start` | seconds | Range start in seconds. With `end`, overrides the selection. |
| `end` | seconds | Range end in seconds. |

### `add_marker`

Adds a marker, or a region when `duration` is given.

| Param | Type | Description |
|---|---|---|
| `at` | seconds | Position in seconds. Defaults to the selection start, else the playhead. |
| `name` | string | **Required.** Marker name. |
| `duration` | seconds | Region length in seconds. |

### `remove_marker`

Removes the markers with this name.

| Param | Type | Description |
|---|---|---|
| `name` | string | **Required.** Marker name. |

### `set_tempo`

Sets the tempo, and the time signature when given, from `at` on. Tempo changes move with the audio in ripple edits.

| Param | Type | Description |
|---|---|---|
| `bpm` | number | **Required.** Quarter notes per minute, 10–999. |
| `at` | seconds | Where the tempo starts. Defaults to 0, the start of the document. |
| `beats` | number | Beats per bar (1–64). Give it with `unit`; without both, the time signature in effect at `at` is kept. |
| `unit` | number | Note value of a beat: 1, 2, 4, 8, 16 or 32 (4 is a quarter note). |

### `delete_words`

Removes words from the audio by their transcript, closing the gaps (ripple). Give word ids (best: they stay valid across edits, undo and saving) or the text to find. Text must match in exactly one place, unless you pass `occurrence` or `all`.

| Param | Type | Description |
|---|---|---|
| `words` | list | Word ids from GET /api/v1/documents/{id}/transcript. |
| `text` | string | A word or phrase as it reads in the transcript; case and punctuation don't count. |
| `occurrence` | number | With `text`: which match, counting from 1. |
| `all` | boolean | With `text`: every match. |
| `bridge` | seconds | Also remove pauses up to this long between the deleted words. Default 0. |

### `correct_word`

Changes how a word is spelled in the transcript. The audio doesn't change.

| Param | Type | Description |
|---|---|---|
| `word` | string | **Required.** The word's id. |
| `text` | string | **Required.** The corrected text. |

### `echo`

Adds a feedback echo to the range (the whole document without a range or selection), bounced into a new file per track; the original audio is untouched and one undo brings it back. With `tail`, the document grows after the range so the echoes ring out.

| Param | Type | Description |
|---|---|---|
| `delay` | seconds | **Required.** Time between repeats in seconds, 0.02–2. |
| `feedback` | number | How much of each repeat comes back, 0–0.95. Default 0.4. |
| `mix` | number | Level of the echoes against the original, 0–1. Default 0.35; 0 changes nothing. |
| `start` | seconds | Range start in seconds. With `end`, overrides the selection. |
| `end` | seconds | Range end in seconds. |
| `tracks` | list | Track ids to change. Default: every track. |
| `tail` | boolean | Make room after the range for the echoes to ring out. Default false. |

### `remove_tempo_change`

Removes the tempo change at exactly `at` (see `tempo.changes` in the document). The first one can't be removed, only changed with `set_tempo`.

| Param | Type | Description |
|---|---|---|
| `at` | seconds | **Required.** Position of the change in seconds. |

## Good to know

- Nothing is destructive: clips play from the original files, so you can always undo. `GET /api/v1/documents/{id}` shows the clips.
- Measure before and after: `analysis` gives the numbers, `waveform` shows the shape.
- Common targets: podcasts −16 LUFS (Apple) with true peak at most −1 dBTP; EBU broadcast −23 LUFS.
- The user may be editing the same document. Read it before you act on it, and keep requests small.
- `tempo.changes` in the document lists each tempo change with `at` (seconds), `bpm` and `meter` (e.g. `"3/4"`); the first is at 0. The API speaks seconds only: to work in bars and beats, compute them yourself from `tempo.changes`. A beat lasts 60 / `bpm` × 4 / unit seconds, and a new time signature starts a new bar.
- Playback is for the user to hear what you did. Don't start it unless they asked; recording can only be started by the user.
