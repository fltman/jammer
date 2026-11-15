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
| POST | `/api/v1/documents/{id}/export` | The rendered audio as bytes. Body: `{"format": "wav", "bitDepth": 16\|24\|32, "start", "end", "dither": false}`; all optional (24-bit WAV of everything by default). Up to 2 GB per response; export a range for more. |
| POST | `/api/v1/documents/{id}/play` | Starts playback in the document's window, from `{"at": seconds}` or the playhead. Only works when the window is visible. |
| POST | `/api/v1/documents/{id}/stop` | Stops playback. |
| POST | `/api/v1/uploads` | Starts an upload for a big file. Answers `{"upload": {"id": "…", "size": 0}}`. |
| PUT | `/api/v1/uploads/{id}?offset=N` | Appends a chunk (≤ 256 MB). `offset` must equal the bytes received so far. |
| GET | `/api/v1/uploads/{id}` | How many bytes have arrived. |
| DELETE | `/api/v1/uploads/{id}` | Throws an upload away. |

Document ids are stable while the window is open. `GET /api/v1/documents` also lists documents the user opened.

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
| 422 | `step_failed` | A step ran and failed. `error.step` is its index; `results` has the status of every step. |
| 500 | `internal` | Jämmer failed unexpectedly. The message has the detail. |

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
