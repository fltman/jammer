# Jämmer: guide for agents

Jämmer 0.1.1 is a native macOS audio editor (speech, restoration, post). This page tells an agent how to drive the running app through its local HTTP API. Everything here works today; nothing else does yet. Any agent the user runs themselves can use it (Claude Code, Codex, or another that can make HTTP requests on this Mac): Jämmer doesn't start agents and never sees an agent's login.

- Base URL: `http://127.0.0.1:9003` (this Mac only; the server listens on loopback). Before you change anything, check that `app.name` in `GET /api/v1/status` is exactly `"Jammer"` (ASCII, no ä); `app.bundleID` is `com.brattoo.jammer`, or `com.brattoo.jammer.debug` for a development build. The window and splash say "Jämmer"; it's the same app. Glimmer and Flimmer run similar APIs on nearby ports.
- Every request that isn't a GET needs the header **`X-Jammer-Agent: 1`**. Without it you get `403 forbidden`.
- Don't send an `Origin` header: requests that look like they come from a web page are refused.
- Audio travels in request and response bodies. The API never reads or writes file paths.
- Edits land in document windows the user can see, and can be undone. One `steps` request is one undo step. The source files are never changed.
- Closing the connection stops a `transcribe`, `export` or `steps` call. The end of your sending side counts as closing it (as with most servers), so don't half-close the socket while you wait for the answer. Bytes you send after the request are ignored.
- Times are in **seconds** (decimals allowed). Jämmer rounds them to the nearest sample; replies give both seconds and frames.
- Steps that cost money are refused unless you pass `"allowPaid": true`. Where Jämmer doesn't know the price it also wants `"allowUnknownPrice": true`, and answers 422 with reason `unknown_price` without it. For transcription, `openai` and `berget_pianissimo` are paid. `GET /api/v1/operations` lists their pricing under `pricesByEngine`.

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
| GET | `/api/v1/status` | App name and version, API version, port, open documents, running jobs, and `providerKeys`: for each cloud provider (`openrouter`, `berget`, `grunden`, `openai`, `anthropic`, `xai`, `google`, `elevenlabs`) whether the user has saved a key, never the key. Keys are added by the user in Settings. |
| GET | `/api/v1/operations` | Everything this API can do, as JSON: every step operation with its parameters, and the calls that have an endpoint of their own (`restore`, `transcribe`, `export` and so on). The latter carry `"call": {"method", "path"}` and are not valid in `steps`. |
| GET | `/api/v1/documents` | The open documents: `id`, `name`, `duration` (seconds), `frames`, `sampleRate`, `channels`, `playing`, `edited` (it has changes that aren't saved) and `frontmost` (the one the user has in front). |
| POST | `/api/v1/documents` | Open audio: raw bytes (`Content-Type: audio/…` or `application/octet-stream`, optional `?name=`), JSON `{"audio": "<base64>", "name"}`, or JSON `{"upload": "<id>", "name"}`. Answers `201` with `{"document"}`, plus `"warning"` when the file was cut short and opened with the sound that was there. A file is untrusted: one that is damaged, has no sound in it, claims more than 32 channels or a sample rate outside 8–768 kHz, or would decode to more than the disk has room for, is refused with `400` and the reason in words. |
| GET | `/api/v1/documents/{id}` | Duration, sample rate, channels, tracks and clips (each clip with its place on the timeline, its place in its source, `gainDB` and fades), `sources` (the audio files the clips play from), markers, tempo, selection, playhead. |
| DELETE | `/api/v1/documents/{id}` | File › Close: closes a document with nothing unsaved, whoever opened it. With unsaved changes it answers 409 `unsaved_changes`. The API never discards changes and never saves unasked: save first (`POST …/save`), or leave the document to the user. A linked document gives 409 where its close alert would ask (changes not yet saved back), and so does one whose window shows a sheet (`sheet_open`). → `{"closed": true, "document"}` |
| POST | `/api/v1/documents/{id}/steps` | Run steps in order. Body: `{"steps": [{"op": "…", "params": {…}}], "allowPaid": false}`. Closing the connection stops the run: nothing of it is applied, and the window says "Stopped by the agent". |
| POST | `/api/v1/documents/{id}/undo` | Undo the last change (a whole `steps` request counts as one). Answers `{"undone": "<name of the change>", "document"}`. Undo doesn't check the result: after undoing a level change, run `analysis` again before exporting (a track back at 0 dB can push the mix over full scale). |
| POST | `/api/v1/documents/{id}/duplicate` | File › Duplicate: an untitled copy of the document in a window of its own, as the window's Duplicate makes it (its tracks, clips, mixer and history); nothing is saved, and the copy has no file until the user saves it. A document from Flimmer is copied in the window by Save a Jämmer Copy…, whose place the user chooses, so it answers 409 `linked`. → `201 {"document": {…the copy…}, "from": "<id>"}` |
| POST | `/api/v1/documents/{id}/save` | Saves the document into its file, as File › Save does (a linked document is saved back into the file it came from). A document that has never been saved answers 409 `no_file`: the user saves it the first time, choosing where. Answers `{"saved", "linked", "edited"}` once the file is written (a linked document's mix is rendered first, which can take a while); a linked file that can't be written answers 422 with reason `save_failed`, saying why. |
| POST | `/api/v1/documents/{id}/redo` | Redo. Answers `{"redone": "<name of the change>", "document"}`. |
| GET | `/api/v1/documents/{id}/analysis` | Loudness of the document, or of `?start=&end=` (seconds): integrated LUFS, range LU, max momentary and short-term, sample peak dBFS, true peak dBTP. `integratedLUFS` is `null` when the whole range is under −70 LUFS (the measurement's absolute gate), and `rangeLU` and `maxShortTermLUFS` are `null` for ranges shorter than about 3 s; `maxMomentaryLUFS` and the peaks are still there, which is how to measure the noise in a pause. `?tracks=id,id` (or `?track=id`) measures those tracks alone, as they sound (gain, fades, effects) without the others; a track you name is measured even if it is muted. The answer then lists `tracks`. |
| GET | `/api/v1/documents/{id}/waveform` | Min/max per column for `?width=` columns (default 200, max 4000), optionally over `?start=&end=`. Lets you see where the sound is. |
| POST | `/api/v1/documents/{id}/export` | The rendered audio as bytes. Body: `{"format": "wav"\|"aiff"\|"flac"\|"alac"\|"aac"\|"opus"\|"mp3", "bitDepth", "bitRate", "start", "end", "dither", "tracks"}`; all optional (24-bit WAV of everything by default). `"tracks": ["id", …]` exports those tracks alone, as they sound without the others (a track you name is exported even if it is muted); the file still covers the whole timeline from 0, so files exported track by track line up. bitDepth: wav 16, 24 or 32; aiff, flac, alac 16 or 24. `"sampleRate"` (8000, 11025, 16000, 22050, 32000, 44100, 48000, 88200, 96000, 176400 or 192000) converts the file to that rate when it isn't the document's; the document isn't changed, times stay, and the header `X-Jammer-Sample-Rate` says the rate written. Opus is always 48000. `"dither": true` adds TPDF dither to a 16- or 24-bit WAV, only on the samples that rounding would change, so audio that is already at that depth is not dithered again; the response header `X-Jammer-Dither` says what was done: `tpdf`, `none`, or `not_needed` (asked for, and every sample already sat on a step of that depth). bitRate: aac 64000–320000 (default 192000), opus 16000–256000 (default 96000; Ogg Opus, mono or stereo), mp3 64000–320000 in standard steps (default 160000). The formats this copy of Jämmer can write are listed in `GET /api/v1/operations` (export). `"chapters": true` (default) writes the markers as chapters: ID3 CHAP in mp3, a QuickTime chapter track in aac and alac (as Apple Podcasts reads them), CHAPTERxxx comments in opus; wav keeps markers as cue points; aiff and flac have none. Content-Type follows the format; only WAV carries Broadcast Wave metadata and markers. For mp3, aac and opus, `"targetLUFS": -16` delivers the file at that loudness: it is measured as written (an encoder shifts it a few tenths) and the gain before the encoder corrected, at most two more encodes, never past −1 dBTP. Without `targetLUFS` the target is the loudness preset the document was last brought to, if nothing changed since; `"compensate": false` encodes once. The response then carries `X-Jammer-Target-LUFS`, `X-Jammer-Loudness` (LUFS of the file as delivered), `X-Jammer-Compensated-DB`, `X-Jammer-True-Peak`, `X-Jammer-Limited-By-Peak` and `X-Jammer-Loudness-From` (`file`, or `mix` if the file couldn't be read back). Loudness and true peak are those of the delivered file, after the correction (an MP3 encoder lowers the level about 0.4 dB, so a correction of +0.44 dB with an unchanged true peak is normal). Up to 2 GB per response; export a range for more. Closing the connection stops it, and nothing is left behind. `"objects": true` (WAV in a 5.1, 7.1 or 7.1.4 document, at its rate, the whole mix): each placed track is written as an ADM object (ITU-R BS.2076-3) with its place over time from its azimuth and elevation lanes, in channels after the bed of everything else (a stereo track as two objects); its sends to buses stay in the bed; refused with `no_objects` when no track is placed. |
| POST | `/api/v1/documents/{id}/export/timeline` | The clips as a timeline file, as bytes; nothing rendered, the file names the audio files. Body: `{"format": "edl"\|"otio"\|"dawproject"}`. What the format can't hold (levels in an EDL, a clip's gain in DAWproject) is in `X-Jammer-Warning`. An empty document is 422 `empty`; more than 999 events for an EDL 422 `too_many_events`. |
| POST | `/api/v1/documents/{id}/transcribe` | Starts transcribing the document (a job, see below). Body: `{"language": "sv-SE", "engine": "auto"}`; both optional (the Mac's language and the best engine for it). `engine`: `auto`, `apple`, `parakeet` (25 European languages), `whisper` (KB-Whisper, Swedish), `pianissimo` (Klang Pianissimo on this Mac, with word times, for Swedish or Danish), `berget_pianissimo` (Swedish at Berget AI, text only; requires the user’s Berget key and `"allowPaid": true`), or `openai` (the audio leaves the Mac and costs money: needs `"allowPaid": true` and, since Jämmer has no price for it, `"allowUnknownPrice": true`, the user's OpenAI key and `"model"`; text only, without word times; never chosen by `auto`; built from OpenAI's documentation, not tried with a real request). Models are installed by the user in Jämmer's Settings, never by the API; asking for one that isn't there answers 422 with reason `model_missing`. Every track is transcribed, and a recognizer finds "words" in music too: in a document with a music track, expect words on it that nobody said, and don't take a track with words to be speech. Answers `202` with the job. |
| POST | `/api/v1/documents/{id}/transcribe-voice-tracks` | Detects language and transcribes each voice track independently on this Mac. Optional `tracks` is a list of IDs. Optional `splitTrack` splits an already diarized track and transcribes the resulting tracks. `nameSpeakers` defaults to true. Install multilingual Whisper in Settings › Models. The job result lists each track’s name, language, engine and word count. |
| GET | `/api/v1/documents/{id}/transcript/export` | Downloads a transcript with `?format=txt` (default), `json`, `srt` or `vtt`. Optional `track` selects one track ID; optional `start` and `end` (seconds) export only the words heard between them, with times from `start`. SRT and WebVTT require word timestamps. |
| GET | `/api/v1/documents/{id}/transcript` | The transcript as it plays now: `{"words": [{"id", "text", "start", "end", "confidence", "speaker", "partial"}], "text", "speakers": [{"id", "name"}]}`, times in seconds on the timeline, optionally over `?start=&end=`. Empty until transcribed. |
| GET | `/api/v1/documents/{id}/analysis/rhythm` | The tempo and beats of music, without changing anything; `?start=&end=` and `?tracks=id,id` as for the loudness (it looks at up to 120 s from the start of the range, which has to be at least 8 s). Answers `{"rhythm": {"bpm", "firstBeat", "beats": [seconds…], "pulse", "alternatives": [half, double], "segments": [{"start", "bpm", "beats", "pulse", "bridge"}…], "start", "end", "analyzedSeconds"}}`. `pulse` is how strongly the sound itself repeats at that beat (0 to 1; a click track is near 1, a dense song around 0.3). `segments` holds one stretch for one tempo; music whose tempo changes in clear steps (read up to 600 s) has one per stretch, `bpm` and `firstBeat` the first one's and `pulse` the weakest; a `bridge` is one beat between two stretches with a length of its own. For speech, noise or silence `bpm` is `null`, `beats`, `alternatives` and `segments` are empty and `reason` is `no_steady_tempo`; a tempo that glides has `reason` `tempo_glides` and a `message` saying from what to what and between when. A fast tempo can come back at half speed (174 as 87): `alternatives` always holds half and double, and the `detect_tempo` step takes `multiply` or the `bpm` you know. Where bars begin is not found. Tried on click and drum tracks at known tempi (within 0.1 BPM, first beat within 20 ms), steps of tempo in clicks and drums (each within half a BPM, each change within 30 ms), a glide, one synthesised song, and speech, noise and silence (all refused). |
| GET | `/api/v1/documents/{id}/mixer` | The mixer: `{"tracks": [{"id", "name", "gainDB", "pan", "muted", "output", "sends": [{"to", "gainDB", "pre"}]}], "buses": [{"id", "name", "gainDB", "pan", "muted", "output", "sends", "inserts", "inputs": {"tracks": [ids], "buses": [ids]}}], "master": {"gainDB", "inserts", "limiter", "latencySamples"}, "usesMixer", "panAvailable", "totalLatencySamples", "limits"}`. `vcas` lists the VCA groups (`add_vca`, `set_vca`, `remove_vca`): `{"id", "name", "gainDB", "muted", "members": {"tracks": [ids], "buses": [ids]}}`. No audio goes through a VCA; its level is added to each member's fader and its mute mutes them, so every track and bus also says `vca` (the group's id or null) and `heard` (`{"gainDB", "muted"}`: its own with the group's). The master is what everything goes through last: its plugins (`add_insert` with `track: "master"`; `GET …/master/inserts/{insert}`), its gain, and a true-peak limiter after all of it (`set_master`); `limiter` is null or `{"ceilingDB", "releaseMs", "lookaheadMs", "guarantee": "exports"}`: an export through it is measured as written and rendered again further under the ceiling until the file holds it (the answer's `X-Jammer-Master-Limiter` header says `ceiling`, the `truePeak` the file measured and the `margin` it took; if it can't be held the export fails with 422, reason `ceiling_not_met`, the measured peak in the message, and leaves no file), while playback has one pass, aims 0.1 dB under, and can go a little over. Every track and bus also has `latencySamples` (what its own plugins add) and `compensationSamples` (the delay the mixer adds to its way out so it meets the longest path on the sample); `totalLatencySamples` is the longest path, which playback and exports hide, so the mix is on time. Since 2026-11-16 every strip is worked out in one graph, so a track's own plugins count in these figures too: `totalLatencySamples` includes them, and a track's `compensationSamples` is the wait added to it for the others' sake. (Before, a track made up for its own plugins by itself and these figures spoke of buses only. The sound is the same, sample for sample.) `output` is a bus id, or `"master"` for the output. Change it with the steps `add_bus`, `set_bus`, `remove_bus`, `set_send` and `set_track` (`pan`, `output`). A send is a copy of a strip to a bus at its own level, after the fader and pan unless `pre`; a muted strip sends nothing; 16 sends per strip. `pan` is −1 (left) to 1 (right) and only for stereo documents; at 0 a strip is untouched, and a document that uses none of this plays exactly as it did before the mixer. A route that would send a bus back into itself fails with reason `routing_loop`; removing a bus that something is routed to fails with `in_use` unless `reroute` is given. |
| GET | `/api/v1/documents/{id}/analysis/acx` | Measures the document against ACX's (Audible's) published audio submission requirements, as read on the date in `readOn`, without changing anything: `{"statement", "source", "articleDate", "readOn", "measuredOn": "mp3"\|"mix", "failed": [names], "requirements": [{"name", "required" (ACX's words), "measured", "pass": true\|false\|null, "note"}]}`. Names: `rms` (−23 to −18 dB), `peak` (sample peak and true peak both no higher than −3), `noiseFloor` (no higher than −60 dB RMS), `format` (192 kbps or higher constant bit rate MP3 at 44.1 kHz), `channels`, `length` (120 minutes at most), `roomTone` (5 s at most at each end), `narration`. The document is encoded to that MP3 (converted to 44.1 kHz when it is at another rate) and measured as it decodes; if no MP3 could be made, `format` fails and the rest is measured on the mix. `pass: null` is something one file's measurement can't decide. It says what was measured, never that ACX approves. |
| GET | `/api/v1/documents/{id}/analysis/restoration` | Looks for problems without changing anything: mains hum (frequency, how prominent), clipping (runs, samples, level), clicks (`count`: impulses of a few samples that stand out from the sound around them; a voice's own pulses and a note's attack aren't counted, and in dense music only clicks well over the music are found), the noise floor (`noiseFloor`: `dBFS`, the RMS level of the pauses, and `pauseSeconds`, how much pause it was measured over; null without pauses of 150 ms or more that are 10 dB under the loud parts) and reverberation (`reverb`: `rt60` in seconds, within about 0.1 s up to 1 s and reading short above that, or null when it can't tell (few pauses, or noise close under the voice); on sound that has been through `denoise` or `dehum` (also in their previews) it isn't measured at all, because what those repairs leave after each word reads as a room: `rt60` and `present` are then null and `unknown` is `"after_noise_reduction"`, so judge reverberation before those repairs; `present` when there is enough to reduce), over `?start=&end=` and `?tracks=id,id` (default: the selection, else everything; all tracks). Long ranges are sampled. |
| POST | `/api/v1/documents/{id}/restore/preview` | The repaired audio of a stretch (at most 30 s), without changing the document. Same body as `restore`, with `start` and `end`. Answers a 24-bit WAV; with `Accept: application/json` it answers `{"before": {…}, "after": {…}}` instead: the detector numbers plus `integratedLUFS` and `truePeakDBTP`. This is not a job: the answer comes when the stretch has been processed, which can take about as long as the stretch plays, so preview a few seconds and allow a long timeout. |
| POST | `/api/v1/documents/{id}/restore` | Repairs audio (a job). Body: `{"kind": "dehum"\|"declip"\|"declick"\|"denoise"\|"dereverb", "amount": 0–1, "start", "end", "tracks": [id], "humFrequency", "sensitivity"}`; only `kind` is required. The repaired clips play from new files; the originals are untouched and one undo step brings them back. |
| POST | `/api/v1/documents/{id}/tracks` | Adds a track from audio sent like `POST /api/v1/documents` (bytes, base64 or upload; `?name=`). Audio at another sample rate than the document's is converted to it. It is placed at the start of the timeline at 0 dB unless you say otherwise: `?at=` is where it starts, in seconds, and `?gainDB=` the track's gain (−96 to 24), both part of the same undo step, so one undo takes the track away. Answers `201` with `{"track": {"id", "name", "gainDB", "at"}, "document"}` (and `"warning"` if the file was cut short). A level set afterwards with `set_track` is a separate undo step: undoing once then brings the track back to the gain it was added with, not away. To put music under speech, add it with a `gainDB` and run `duck` on it. For double-enders, add each speaker's recording and the call recording, then run `align_tracks`. |
| GET | `/api/v1/documents/{id}/tracks/{trackId}/drift?against=<trackId>` | How far two recorders' clocks part: `{"drift": {"ppm", "msPerHour", "confidence"}}`. Needs at least 90 s of overlap. |
| GET | `/api/v1/documents/{id}/tracks` | The tracks with their ids, clips and plugins (`inserts`). |
| GET | `/api/v1/documents/{id}/tracks/{trackId}/inserts/{insert}` | One plugin: `{"insert": {"id", "plugin", "name", "bypass", "latencyMs", "factoryPresets", "params": [{"identifier", "name", "unit", "min", "max", "value"}]}}`. |
| POST | `/api/v1/documents/{id}/separate` | Splits tracks into stems (a job). Body: `{"model": "music4"\|"dialog", "tracks": [id]}`; both optional. Result: `{"stems": [names], "tracks": [ids]}`. |
| GET | `/api/v1/documents/{id}/history` | The history tree: `{"current", "pruned", "limit", "nodes": [{"id", "parent", "action", "time", "branch"}]}`. A change made after an undo starts a branch; the old future stays reachable. |
| POST | `/api/v1/documents/{id}/history/{node}` | Goes to that step (any branch). One undo step; `undo` goes back. |
| POST | `/api/v1/import/fcpxml` | Opens the sound of a film timeline as a new document. Body: `{"path": "/…/film.fcpxml"}`; the file and the media it uses must lie in a folder the user allows (Settings › Agents), else 422 `folder_not_allowed`. Answers `201` with `{"document", "import": {"tracks", "clips", "sources", "shots": [{"name", "start", "duration"}], "flimmer": {"exportVersion"} or null, "warnings": [{"code", "message", "clip"}]}}`. One track per lane (lane −1 first), with each clip's position, trim, level, linear fades and mute; a video clip's own sound lands on a track called Video; the pictures become shot markers (`kind: "shot"` in the document), which are never chapters and are written as cue points labeled `Shot: <name>` in a WAV export. Tried with Flimmer's exports and hand-written FCPXML, not yet with files written by Final Cut Pro or DaVinci Resolve. Flimmer's exports carry exact times and separate clip and track levels, which are used; other programs' files are read from the FCPXML fields. Warnings to expect: `resampled` (a file at another sample rate than the timeline plays from a converted copy), `missing_media`, `unreadable_media`, `disabled_clip` (a clip switched off in a lane that is otherwise on is left out), `overlap`. |
| POST | `/api/v1/import/timeline` | As import/fcpxml, for FCPXML, a CMX 3600 EDL, OpenTimelineIO (.otio) or DAWproject (.dawproject). Body: `{"path": "/…/cut.edl", "rate": "25"}`; `rate` (an EDL only, which doesn't say its own) is one of 23.976, 24, 25, 29.97, 29.97df, 30, 50, 59.94, 59.94df, 60. The same folder rule for the file and every file it names; audio inside a DAWproject is unpacked into Jämmer's own media folder. |
| POST | `/api/v1/batch` | Processes files by path (a job). Body: `{"files": [paths] or "folder": path, "steps": […], "jobs": [{"op", "params"}], "export": {"format", "bitDepth", "bitRate", "chapters", "targetLUFS", "compensate", "sampleRate"}, "output": path, "suffix", "overwrite"}`. Result: `{"done", "outputs", "loudness", "loudnessFrom", "compensatedDB", "limitedByPeak", "skipped", "failed", "warnings"}` (`warnings`: files that were cut off and went in with the sound that was there), the middle four lining up with `outputs`. `loudness` is the LUFS of the file as written, read back after encoding (`loudnessFrom` is `file`; `mix` if the file couldn't be read back). An mp3, aac or opus encoder changes the loudness a little, so when there is a target (`export.targetLUFS`, or a `loudness_preset` as the last step) the file is measured, the gain before the encoder corrected and the file encoded again, at most twice and never past the true-peak ceiling; `compensatedDB` is what was added. `"compensate": false` turns that off. `limitedByPeak`: the target wasn't reached because of the peaks (the step ran without `"limit": true`; with it the limiter holds the peaks and the target is reached). Paid `transcribe` engines need `"allowPaid": true` (else 402 `paid_not_allowed`). `openai` also needs `"allowUnknownPrice": true` (else 422 `unknown_price`). |
| GET | `/api/v1/plugins` | The Audio Unit effects installed on this Mac, optionally filtered by `?q=`: `{"plugins": [{"id", "format", "name", "manufacturer", "kind", "version", "v3"}], "safeMode"}`. |
| POST | `/api/v1/documents/{id}/diarize` | Finds who speaks when (a job). Body: `{"mode": "by_track"\|"ml", "tracks": [id], "speakers", "minSpeakers", "maxSpeakers"}`; all optional. The result has `speakers` (names) and `seconds` (each one's speaking time) in order of id. |
| GET | `/api/v1/documents/{id}/speakers` | `{"speakers": [{"id", "name", "seconds"}], "turns": [{"speaker", "track", "start", "end"}]}`, as it plays now, optionally over `?start=&end=`. |
| GET | `/api/v1/requirements` | What Jämmer may need installed (see the section above): `{"items": [{"id", "name", "kind", "neededBy", "required", "installed", "sizeBytes", "license": {"spdx", "url"}, "source": {"publisher", "url", "version", "sha256"\|"commit"}, "install": {"how", "where"\|"steps"}, "where", "remove", "modes", "debugOnly", "verify"?}]}`. Never starts a download. |
| POST | `/api/v1/settings/open` | `{"pane": "models"}` opens Settings at its Models pane, so the user can download what a call needs. Changes nothing. |
| GET | `/api/v1/voice-profiles` | The voice profiles saved on this Mac: `{"profiles": [{"id", "name", "createdAt"}], "recognize", "threshold"}`. Never a voiceprint. Profiles are made and deleted only in the window, by the user, with consent. A speaker `diarize` (mode ml) names after a profile is *like* it (`matchedProfile`, `matchScore` and `threshold` in the job's result, in the order of `speakers`): say "is like Anna", never "is Anna". |
| POST | `/api/v1/documents/{id}/voice-profile/request` | Shows the sheet that saves a speaker as a voice profile, if the window is visible and in front (body `{"speaker": "2"}` or a name, optional). `202 {"shown": true}`, not what the user chose: list the profiles afterwards. `409 sheet_open` when a sheet is shown, `422 not_visible`, or `no_speakers` before `diarize` (mode ml). Never brings the app forward, never saves or deletes a profile. |
| GET | `/api/v1/documents/{id}/chapters` | The markers as Podcasting 2.0 chapters: `{"version": "1.2.0", "chapters": [{"startTime", "endTime", "title"}]}` (Content-Type `application/json+chapters`), optionally over `?start=&end=`. With the same `start` and `end` as an export, it is the chapters file Export Audio writes beside the file. |
| GET | `/api/v1/documents/{id}/recording` | Recording, read only: `{"armed": [{"track", "name", "input", "channels"}], "recording", "start", "punchOut", "seconds"}` (`punchOut` when a selection is recorded into, from a pre-roll). Arming a track, the microphone, Record and deleting a take are the person's in the window; no call starts them (SIBLINGS §5). What was recorded is ordinary clips and sources afterwards, and each track's `takes`: the stretches recorded more than once, every take kept, one chosen; `set_take` plays another. |
| GET | `/api/v1/documents/{id}/flimmer-return?mode=takes\|mix` | What Send to Flimmer would send, for an agent that delivers it through Flimmer's own API; nothing is rendered, uploaded or sent. → `{"mode", "sampleRate", "items": [{"index", "kind": "take"\|"new"\|"mix", "name", "clipId", "start", "end", "monoSource", "fields", "audio", "transcript"}], "body", "said"}`. `body` is the plan for Flimmer, with `<upload of item n>` where each upload's id goes; `transcript` is that item's transcript body, or null. 422 with the reason when there is nothing to send (`not_from_flimmer`, `needs_new_export`, `nothing_to_change`). |
| GET | `/api/v1/documents/{id}/flimmer-return/{n}/audio?mode=&bitDepth=16\|24` | Item `n`'s file, exactly as Send to Flimmer renders it: WAV at Flimmer's rate, plugins included, mono when the original was. |
| GET | `/api/v1/jobs/{id}` | A job's state. |
| DELETE | `/api/v1/jobs/{id}` | Cancels a job. |
| POST | `/api/v1/transcribe?language=sv-SE&engine=auto\|whisper\|pianissimo` | One short turn of speech, for an app's live captions: no document, no window, answered at once. The body is the WAV itself, 16 kHz mono 16-bit PCM, at most 15 s (413 for more). → `{"text", "words": [{"text", "start", "end", "confidence"}], "engine", "model", "ms"}` (times in seconds from the turn's start). `auto`: local Pianissimo once its model is loaded (the first `auto` turn starts loading it, some seconds), meanwhile KB-Whisper for Swedish, else Whisper small. One turn at a time: 409 `busy`, and 409 `stopped` when the user stops it in Jämmer's window. A closed connection cancels the turn. 422 `model_missing` with `requirement` (the API never installs a model), 503 `model_unavailable`, 403 `sibling_transcription_off` when the user has turned this off in Settings › Agents. The audio is never written to disk or kept, and neither the audio nor the text is logged; Jämmer's windows say while it works. Send `X-Sibling` with your app's name so they can say for whom. Free. |
| POST | `/api/v1/transcribe/file?language=sv-SE&engine=auto\|whisper\|pianissimo` | A whole file of speech, for an app that keeps the words itself (captions for a film): a job with no document and no window. The body is the audio (`Content-Type: audio/…`; WAV, AIFF, m4a, MP3, FLAC or CAF) or `{"upload": "<id>"}` from `/api/v1/uploads` for a file over 256 MB, never a path; at most 2 hours (413 for more). → `202 {"job"}`; follow it at `GET /api/v1/jobs/{id}`, stop it with `DELETE`. The first `GET` of the finished job carries `result: {"text", "words": [{"text", "start", "end", "confidence"}], "engine", "model", "language"}` (times in seconds from the file's start), and Jämmer then forgets the words: a later read says `result.gone` with `why: "fetched"`, or `"expired"` 10 minutes after the job finished unread. `auto`: local Pianissimo when installed for the language, else KB-Whisper for Swedish, else Whisper small. One transcription for another app at a time, a file or a turn: 409 `busy`. 422 `model_missing` with `requirement`, 403 `sibling_transcription_off`, as for turns. The audio lies in a private temporary folder only while the job runs, and neither it nor the text is logged; Jämmer's windows say "Transcribing a file for Drömmer…" (from `X-Sibling`) with a Stop. Free. |
| POST | `/api/v1/documents/{id}/play` | Starts playback in the document's window, from `{"at": seconds}` or the playhead. Only works when the window is visible. |
| GET | `/api/v1/storage` | What takes room in Jämmer's media folder: `{"storage": {"canBeFreed", "inUse", "unknown", "notJammers": each {"bytes", "files": [{"name", "bytes", "kind", "created", "projects"}]}, "inTrash", "register", "note"}}`. `canBeFreed`: files Jämmer made (effects, repairs, frozen strips) that no project that has used them uses any more, now or anywhere in its history. `unknown`: made by Jämmer and last used by a project that can't be read just now. `notJammers`: the user's own audio and anything Jämmer has no record of having made; never touched. Reading only: there is no call that removes anything. The user chooses in File › Storage…, and what is chosen goes to the Trash. |
| POST | `/api/v1/documents/{id}/freeze` | `{"strip": track or bus id}`. Renders the strip through its plugins into a file and plays it from that, with the plugins idle (a job; one undo step). Its level, pan, mute, sends and route stay live. Until it is unfrozen, a step that would change what it was frozen from fails with 422 `step_failed`, `reason: "frozen"`. `GET …/mixer` says `frozen: {"start", "seconds"}` on the strip. Refused: `already_frozen`, `nothing_to_freeze`. |
| POST | `/api/v1/documents/{id}/unfreeze` | `{"strip": id}`. The strip is worked out live again, from exactly what it was (one undo step). Answers the mixer. Refused: `not_frozen`. |
| GET | `/api/v1/documents/{id}/automation?strip=&at=` | The level of a strip at a time (`strip`: a track or bus id, or `master`; `at`: seconds): with `param` (gain by default, or pan, mute, send with `to`, or plugin with `insert` and `parameter`) `value` is that lane's there (dB, −1 to 1, or 1 for muted; null without one), `faderDB` the fader with its VCA group, `levelDB` that and the gain lane together, `muted` whether anything silences the strip then. For checking what `set_automation` wrote without rendering. The lanes themselves are in `GET …/mixer`, under `automation` on each strip. (`set_automation` writes them, in builds that have automation.) |
| POST | `/api/v1/documents/{id}/solo` | `{"strips": [track and bus ids]}`; `[]` ends it. Solo is a way of listening, not an edit: only the soloed tracks, and the tracks that reach a soloed bus by output or send, are heard in playback. It is not a step, not undone and not saved, and exports, measurements and bounces are not changed by it. Answers `{"solo": {"strips", "heardTracks", "affects": "listening", "note"}}`, which `GET …/mixer` has too. |
| POST | `/api/v1/documents/{id}/stop` | Stops playback. Answers `underruns`: the times since playback started that the sound card asked for audio and not enough was rendered, each a gap that was heard. A document's summary (`GET /api/v1/status`, `GET /api/v1/documents`) has the same count while it plays. 0 is what it should be. |
| POST | `/api/v1/uploads` | Starts an upload for a big file. Answers `{"upload": {"id": "…", "size": 0}}`. |
| PUT | `/api/v1/uploads/{id}?offset=N` | Appends a chunk (≤ 256 MB). `offset` must equal the bytes received so far. |
| GET | `/api/v1/uploads/{id}` | How many bytes have arrived. |
| DELETE | `/api/v1/uploads/{id}` | Throws an upload away. |

Document ids are stable while the window is open. A document a sibling app handed over to edit (SIBLINGS.md §6) has `"linkedFile": {"name", "format", "requester", "available"}` in the document list (with `"unreturnedSteps"`, how many steps have not been saved back, while there are any; and, when Jämmer brought it back at start with such changes, `"kept": true` if it had been kept on purpose (Jämmer was quit, or the window closed with Keep for Later) or `"recovered": true` if Jämmer had stopped unexpectedly, never both, until the changes are saved back or given up; `GET /api/v1/status` has `"linkJournal": {"entries", "broken"}`, how many linked documents Jämmer keeps a record of and how many records it couldn't read); the user saves it back with ⌘S, and the API never writes that file. `available` is `false`, with `reason` in words, when the file can no longer be reached or written (it was removed, made read-only, or replaced by another kind of file); the document is then still open with the edit in it. It follows the file while the document is open (looked at once a second and at every listing), so it turns false when the sibling removes its file and true again when the file is back. The same file handed over again brings the open document forward instead of opening another. `GET /api/v1/documents` also lists documents the user opened.

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

## What Jämmer may need installed

Nothing here comes with the app. The API never starts a download or an installation: ask the user, and `POST /api/v1/settings/open` with `{"pane": "models"}` opens the pane (it changes nothing). A call that needs one of these and finds it missing answers `422 model_missing` with `"requirement": "<id>"`. `GET /api/v1/requirements` lists them with `installed`.

| id | What | Needed by | License | Source and version | Install |
|---|---|---|---|---|---|
| `kb-whisper-small` | KB-Whisper small (Swedish) | `transcribe` | [Apache-2.0](https://huggingface.co/KBLab/kb-whisper-small) | KBLab, National Library of Sweden, https://huggingface.co/KBLab/kb-whisper-small/resolve/3564d61a42fc210ceaa55a22a96dd64478959c78/ggml-model-q5_0.bin (ggml-model-q5_0.bin at commit 3564d61a42fc210ceaa55a22a96dd64478959c78, sha256 6768836a51abc902e420c613153e6d418c90ea2774e913274d02ab23170225b7, commit 3564d61a42fc210ceaa55a22a96dd64478959c78) | In the app: Settings › Models |
| `kb-whisper-medium` | KB-Whisper medium (Swedish) | `transcribe` | [Apache-2.0](https://huggingface.co/KBLab/kb-whisper-medium) | KBLab, National Library of Sweden, https://huggingface.co/KBLab/kb-whisper-medium/resolve/0abe10b9d7f75d0902656e5c06c5c4d549604dc5/ggml-model-q5_0.bin (ggml-model-q5_0.bin at commit 0abe10b9d7f75d0902656e5c06c5c4d549604dc5, sha256 7f8762e0ade9e0073674c0d5acae942a0b1ea98add9baa008ee89c94eaba43d0, commit 0abe10b9d7f75d0902656e5c06c5c4d549604dc5) | In the app: Settings › Models |
| `whisper-small-multilingual` | Whisper small (multilingual) | `transcribe_voice_tracks` | [MIT](https://github.com/openai/whisper/blob/main/LICENSE) | OpenAI (GGML conversion by whisper.cpp), https://huggingface.co/ggerganov/whisper.cpp/blob/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small-q5_1.bin (small Q5_1, sha256 ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb, commit 5359861c739e955e79d9a303bcbc70fb988958b1) | In the app: Settings › Models |
| `parakeet-tdt-0.6b-v3` | Parakeet TDT 0.6B v3 (25 languages) | `transcribe` | [CC-BY-4.0](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) | NVIDIA (Core ML conversion by Fluid Inference), https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml (Core ML int8 v2, commit 7dd20fe6b1797d35f5e3307e8b1732d9a178edfe, sha256 or git blob id of each of its 88 files) | In the app: Settings › Models |
| `pianissimo-sv` | Klang Pianissimo (Swedish) | `transcribe`, `transcribe_voice_tracks` | [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/) | Klang AI AB (Core ML conversion by markstrom), https://huggingface.co/markstrom/pianissimo-sv-coreml (Core ML int8 1.1.0, commit dd578628d1ae6577b4672221b99fff59112ff5b4, sha256 or git blob id of each of its 21 files) | In the app: Settings › Models |
| `pianissimo-da` | Klang Pianissimo (Danish) | `transcribe`, `transcribe_voice_tracks` | [CC-BY-4.0](https://creativecommons.org/licenses/by/4.0/) | Klang AI AB, https://huggingface.co/KlangAI/pianissimo-da-coreml (Core ML int8, commit 9e6213c13d3a91b87f8e4a2310ac77bec45e54ef, sha256 or git blob id of each of its 18 files) | In the app: Settings › Models |
| `diarisation` | Speaker diarisation (pyannote Community-1) | `diarize`, `request_voice_profile`, `split_speakers` | [CC-BY-4.0](https://huggingface.co/pyannote/speaker-diarization-community-1) | pyannote (Core ML conversion by Fluid Inference), https://huggingface.co/FluidInference/speaker-diarization-coreml (Community-1, commit df2625ac79a7ac6b65ad868fee6d80f320da4232, sha256 or git blob id of each of its 85 files) | In the app: Settings › Models |
| `spleeter-4stems` | Stem separation (Spleeter 4stems) | `separate` | [MIT](https://github.com/deezer/spleeter/blob/master/LICENSE) | Deezer, https://github.com/deezer/spleeter/releases/download/v1.4.0/4stems.tar.gz (v1.4.0, sha256: not published by the source (GitHub's release API gives no digest for this 2019 asset); Jämmer checks its download against the sum it was built with, 3adb4a50ad4eb18c7c4d65fcf4cf2367a07d48408a5eb7d03cd20067429dfaa8) | In the app: Settings › Models |
| `mrx` | Soundtrack separation (MRX) | `separate` | [MIT](https://github.com/merlresearch/cocktail-fork-separation/blob/main/LICENSE.md) | MERL, https://media.githubusercontent.com/media/merlresearch/cocktail-fork-separation/19b3de827ebc4bfb014570cf92dd32b4ee3b6921/checkpoints/default_mrx_pre_trained_weights.pth (default_mrx_pre_trained_weights.pth at commit 19b3de827ebc4bfb014570cf92dd32b4ee3b6921, sha256 9cecc071c9e58afda34d1a98609a1540f61320e718bafecc4c9c1c5e3ed20a0c, commit 19b3de827ebc4bfb014570cf92dd32b4ee3b6921) | In the app: Settings › Models |
| `audio-units` | Audio Unit effects | `add_insert` | the maker's | The plugin's maker, The maker's own site | By the user: Install the plugin with its maker's installer (it puts the .component in /Library/Audio/Plug-Ins/Components or ~/Library/Audio/Plug-Ins/Components). In Jämmer, Audio › Plugins… lists it. Plugin settings from elsewhere run in a process of their own. Check: `codesign -dv --verbose=2 <path to the .component>`. |

## Errors

A name Jämmer doesn't know is refused, never skipped: a parameter of a step, a field beside `op` and `params`, a field in a JSON body, a query parameter. The answer is 400 `bad_request` with the name and what the call does take, and nothing is done (in `/steps`, no step runs). So a 2xx answer means every value you sent was used. The schemas in `/api/v1/operations` are closed (`"additionalProperties": false`). One name is accepted everywhere and used for nothing: `rationale`, a string saying why you make the call.

Errors are JSON: `{"error": {"code": "…", "message": "…"}}`. A failed step also gives its index: `{"error": {"code": "step_failed", "message": "…", "step": 1}}`.

| Status | Code | Meaning |
|---|---|---|
| 400 | `bad_request` | The body or a parameter is malformed. The message says which (and `step` which step). |
| 402 | `paid_not_allowed` | A step costs money and `allowPaid` wasn't `true`. |
| 422 | `unprocessable`, reason `unknown_price` | It costs money, Jämmer doesn't know how much, and `allowUnknownPrice` wasn't `true` beside `allowPaid`. Allowing a paid request is not allowing any price. |
| 403 | `forbidden` | Missing `X-Jammer-Agent: 1`, an `Origin` header, or a Host other than this Mac. |
| 404 | `not_found` | No such document, upload, path or operation. |
| 405 | `method_not_allowed` | Wrong HTTP method for the path. |
| 409 | `not_available` | Not possible right now: nothing to undo, the window isn't visible for playback, the upload offset is wrong. |
| 413 | `too_large` | A body over 256 MB (use uploads), an upload over 16 GB, or an export over 2 GB (export a range). |
| 507 | `insufficient_storage` | Not enough free disk space for the upload or export. |
| 422 | `step_failed` | A step ran and failed. `error.step` is its index; `results` has the status of every step. Some failures add `error.reason` (`ambiguous`, `not_found`) and numbers such as `error.matches`. `stopped`: the user stopped the run in Jämmer's window, and nothing was applied. |
| 422 | `unprocessable` | The request is fine, but the document doesn't allow it; `error.reason` says why (`no_hum`, `nothing_in_range`). Nothing started. |
| 500 | `internal` | Jämmer failed unexpectedly. The message has the detail. |

## Jobs

Transcription, repairs (`restore`), finding speakers, stem separation, batch and scanning run as jobs. The request that starts it answers `202` with `{"job": {"id", "kind", "status", "progress"}}`. `status` is `queued`, `running`, `done`, `failed` or `canceled`; `progress` goes from 0 to 1. Poll `GET /api/v1/jobs/{id}` every second or two. When it's `done`, `result` has a summary and the document has changed (one undo step); a failed job has `error: {code, message}`. `DELETE /api/v1/jobs/{id}` cancels. Running jobs are also listed under `jobs` in `GET /api/v1/status`. The user can keep editing while a job runs; words are anchored to the audio itself, so they land right regardless.

## Transcripts

A transcript is a view of the edit: it always reads what plays now. Each word has an `id` that stays the same across edits, undo, redo and saving, so you can keep ids between requests. Delete words with `delete_words` and `{"words": ["<id>", …]}`. You can pass `{"text": "…"}` instead, but it must match in exactly one place; otherwise the step fails with `reason: "ambiguous"` and `matches`, and you pick one with `occurrence` or all with `"all": true`. `correct_word` changes the spelling only. Things to know when you read a transcript: words follow each other without gaps, so a pause is inside one of the words beside it, usually the word after the pause ("mattor" at 13.32–14.52 can start with 0.8 s of silence). Deleting a sentence therefore usually takes the pause before it and leaves the one after it; look at `waveform` over the words when the exact cut matters. `confidence: null` means the recognizer gave that word no proper time (the Mac's own recognizer does this for the last sentence of a recording): its `start` and `end` are rough and can be seconds off the sound, so check them against `waveform` before cutting there, or transcribe with `whisper` or `parakeet` when they're installed; sentence punctuation comes from the recognizer and is often missing, so pick the words of a sentence by reading them, not by splitting on full stops; `languages` lists the language of each transcribed source. The job's `result.engine` is the full name of the engine that ran (for example `apple-dictation`), which is more specific than the `engine` value you asked for.

## Restoration

Look, listen, then repair. `GET …/analysis/restoration` tells you whether there is hum, clipping, clicks or reverberation. `POST …/restore/preview` with `Accept: application/json` gives the numbers before and after for a short stretch, so you can check that a repair helps (and that `amount` isn't too much) without listening. `POST …/restore` then runs it as a job. `dehum` finds 50 or 60 Hz by itself; pass `humFrequency` if it says `no_hum` and you know better. `denoise` reduces steady background noise (hiss, fans, room tone) with DeepFilterNet 3, on this Mac; its `amount` defaults to 1. It isn't meant for mains hum: when the analysis reports `hum`, run `dehum` as well. To show what a repair did to the noise (this goes for `dehum` too), compare `noiseFloor` in the analysis or the preview before and after: the level in the pauses, in dBFS. It is null when there are no pauses to measure in, and after a repair that leaves digital silence between the words. A hum that is louder than the rest of the noise is part of the floor before `dehum`. When both are needed, run `dehum` first and `denoise` after it. Hum and noise count in the loudness, so a repaired recording measures lower than before (1.2 LU lower in a noisy test take): set the loudness after repairing, not before. `dereverb` takes down the room's echo after each sound (the late reverberation, by linear prediction; no model) and leaves the direct sound; its `amount` defaults to 0.7, and it does little when `reverb.present` is false. It lowers the tail by 5 to 10 dB without shortening it, so judge a preview by ear or by level, not by `rt60` after. `amount` blends between the original (0) and the full repair (1). Use `tracks` to repair one speaker in a multitrack recording.

## Speakers

`POST …/diarize` labels the document with speakers as a job. For a double-ender (several tracks playing at once, one person per track) the default is `"mode": "by_track"`: each track is its speaker, named after the track, and bleed from the other tracks doesn't count. Otherwise it's `"ml"`, a diarisation model run on each track; tell it `speakers` when you know how many, especially for similar voices and short back-and-forth, where it's much weaker (docs/DIARISATION.md has the numbers). If `ml` finds only one speaker, the job's result has a `hint`: when the recording is a conversation, run it again with `speakers`, since the model often merges voices that sound alike. The first `ml` run downloads the model (about 20 MB); if that fails the job fails with `error.code` `model_unavailable`. Afterwards `GET …/speakers` lists who talks when, `GET …/transcript` gives each word a `speaker` id and lists `speakers`, and `rename_speaker` names them ("0" → "Anna"). Turns are anchored in the audio, so they stay right through edits.

`"mode": "ml"` needs the diarisation model on this Mac. The API never downloads it: without it `diarize` answers `422 model_missing` with `"requirement": "diarisation"` (a batch's file fails with `model_missing`). Ask the user, and `POST /api/v1/settings/open {"pane": "models"}` opens the pane where they download it.

## Batch

Everything else in this API works on documents the user has open; `POST /api/v1/batch` is the one call that reads and writes files by path. So it only works inside folders the user has allowed under Jämmer › Settings… › Agents ("Folders agents may use"; the list starts empty, and `agentFolders` in `GET /api/v1/status` is how many there are). A path outside them, also through a symlink or `..`, answers 422 with reason `folder_not_allowed`: ask the user to add the folder. Each file is processed without a window: `steps` as in `…/steps`, then `jobs` (`restore`, `transcribe`, `diarize`, `separate`, with the same parameters as their endpoints), then exported into `output` as “name (Jämmer).mp3” (or your `suffix` and format). The input files are never changed, not even with `overwrite` (reason `would_overwrite_source`); a result that already exists is skipped unless `overwrite` is true; a file that fails is listed under `failed` and the rest carry on.

## Stems

`POST …/separate` (a job) splits each track into vocals, drums, bass and other with Spleeter's 4-stem model, on this Mac. The stems replace the track as four tracks in one group (`group` in `GET …/tracks`) and add up to exactly what the track was, so the mix is unchanged until you change a stem: `set_track` mutes or turns one, `set_group` moves them all together. The model works up to 11 kHz; everything above it, and whatever the model leaves, goes to `other`, so nothing is lost. `"model": "dialog"` splits film or video sound into speech, music and effects instead (MERL's MRX; slower, and what it leaves is shared between music and effects). The user installs the models (146 MB and 122 MB, both MIT, from their publishers) in Settings › Models.

## Plugins

A track can run through Audio Unit effects (AUv2 and AUv3) before its gain. `GET /api/v1/plugins` lists what's installed; `add_insert` puts one on a track (by id like `aufx/lmtr/appl` or by its exact name) and answers its id in `info.insert`; give a bus's id as `track` and the plugin goes on the bus, after its sum and before its level (`GET …/buses/{busId}/inserts/{insert}` for its parameters), and the same for `set_insert` and `remove_insert`; `GET …/tracks/{trackId}/inserts/{insert}` lists its parameters with their ranges; `set_insert` changes one parameter, a factory preset or bypass; `remove_insert` takes it off. A value outside a parameter's range fails with `reason: "out_of_range"`; nothing is clipped. Every change is one undo step, settings are saved in the document, and each plugin's latency is compensated so the tracks stay in time. Exports and loudness measurements (including `normalize` and `loudness_preset`) hear the plugins. You can't open a plugin's window; the user can, under Audio › Plugins.

Plugins are third-party code that runs inside Jämmer. If one crashes or misbehaves, the right fix is safe mode (Audio › Plugins, or ask the user): every Audio Unit then runs in macOS's separate plugin host process instead of inside Jämmer. Errors: `plugin_not_found`, `plugin_unsupported_format` (it can't take the document's mono or stereo float audio), `plugin_failed` (it didn't start).

## Sibling apps

Glimmer and Flimmer call Jämmer the same way you do (see their own guides). They add `X-Sibling: <slug>`; Jämmer logs it and shows "Requested by …" in the window, and it gives no extra rights. `GET /api/v1/operations` lists every op with `params` as a JSON Schema, plus `paid`, `undoable` and `startsJob`, so an assistant can turn them into tools named `jammer.<op>`. `tier` is `"core"` for the 15 most useful ones and `"advanced"` for the rest: start from core when tools are scarce.

## Changes

- 2026-11-26: `delete_voice` (`DELETE /api/v1/documents/{id}/voices/{voice}`) is gone: it answers 404 `route_gone`. Deleting a cloned voice is the person's own, in the window (Speech › Delete Cloned Voice…): it can only be made again by paying again, and deleting it protects the person whose voice it is. List the voices with `GET …/voices` and suggest which one to delete.

- 2026-11-19 (0.1.1): a batch job that transcribes with a paid engine (`openai`) now needs `"allowPaid": true` and `"allowUnknownPrice": true`, as the other paid calls do. In 0.1.0 a batch ran it without them.
- 2026-11-19: `diarize` with `"mode": "ml"` (an API call or a batch) no longer downloads the diarisation model the first time. It answers `422 model_missing` with `"requirement": "diarisation"` instead; the user downloads the model in Settings › Models, where a sheet shows its size, publisher, source and license first. `"mode": "by_track"` needs no model. New: `GET /api/v1/requirements` and `POST /api/v1/settings/open`.
- 2026-11-19: clips whose audio is speech made with a cloned voice carry `"clonedVoice"` in the track JSON; it can't be removed through the API.

## Operations

These are the `op` values for `steps`, with their `params`. `GET /api/v1/operations` has the same list as JSON, followed by the calls that have their own endpoint (those have a `call` field and can't be used as steps).

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

### `select_track`

Makes a track the selected one (the one the Track menu acts on) and brings it into view in the window.

| Param | Type | Description |
|---|---|---|
| `track` | string | **Required.** Track id. |

### `set_playhead`

Moves the playhead (where paste and markers go by default).

| Param | Type | Description |
|---|---|---|
| `at` | seconds | **Required.** Position in seconds. |

### `set_video_reference`

Gives the document a film to look at while the sound is worked on: a file on this Mac, shown in the Picture window and following the playhead. The film is only pointed at: it is not read into the project, not changed, and its own sound is not played. info has `at`.

| Param | Type | Description |
|---|---|---|
| `path` | string | **Required.** The film's file (a QuickTime or MPEG-4 film: .mov, .mp4, .m4v), as a full path. |
| `at` | seconds | The place on the timeline where the film's first picture is. Default 0. |

### `remove_video_reference`

Takes the film away from the document. The file is left as it is.

No params: `{"op": "remove_video_reference"}`

### `go_to_timecode`

Moves the playhead to a timecode of the picture: to the audio frame where that picture frame begins. The document must have a timecode (set_timecode, or an imported film timeline). info has `at`, the place in seconds.

| Param | Type | Description |
|---|---|---|
| `timecode` | string | **Required.** The timecode, as hh:mm:ss:ff (hh:mm:ss;ff for drop-frame), at the document's frame rate. |

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

Sets the level of the range (the whole document without a range or selection) to a target. The change is a gain on the clips in the range (it shows as gainDB on each clip), not on the track. info has before and gainDB.

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

### `debleed`

Removes the other speakers from each track of a multitrack recording. gate lowers a track outside its own speaker's turns (needs diarize mode by_track; reason no_speakers otherwise); best when people don't talk over each other. cancel subtracts the other tracks' leak: the delay is found by cross-correlation up to about 1 s (a remote guest's voice coming back out of headphones arrives 50–500 ms late), and the leak is learnt where the track's own speaker is silent, so their voice is kept; needs two or more tracks that play together (reason needs_tracks). Each processed track plays from a new file; the original is one undo away. info: tracks, reductionDB.

| Param | Type | Description |
|---|---|---|
| `method` | string | **Required.** How to remove it. One of: `gate`, `cancel`. |
| `tracks` | list | Track ids. Default: every track (gate: those with speakers). |
| `amount` | number | gate: dB outside the turns. Default -18. |
| `maxDelay` | number | cancel: ms of spread around the found delay (the room or codec). Default 30. |

### `duck`

Lowers tracks (music, atmosphere) while there is speech on other tracks and lets them up in the pauses. Where the speech is comes from the speakers' turns when the controlling tracks have them (diarize first for the surest result), otherwise from their level (threshold). Each ducked track plays from a new file; outside the ducked stretches and their ramps the sound is untouched, and the original is one undo away. It isn't live: if the speech is moved or cut afterwards, run it again. Run again on a track that still plays its ducked file, it replaces the earlier ducking (it starts from the sound before it); stack: true ducks on top instead. A track that was edited after it was ducked is ducked as it is. info: tracks, regions (stretches held down), duckedSeconds, replaced (tracks whose earlier ducking was replaced), trigger (turns or level).

| Param | Type | Description |
|---|---|---|
| `tracks` | list | **Required.** Track ids to lower. |
| `under` | list | Track ids whose speech decides. Default: every other unmuted track. Must not name a track that is in tracks. |
| `amount` | number | dB while there is speech. Default -12. |
| `threshold` | number | LUFS (momentary) over which the deciding tracks count as speech, when they have no speaker turns. Default -40. |
| `attack` | number | ms to go down. Default 150. |
| `release` | number | ms to come up. Default 600. |
| `hold` | number | ms to stay down after the speech stops, so short pauses don't pump. Default 400. |
| `lookahead` | number | ms before the speech that it starts going down. Default: the attack, so it is down when the first word comes. |
| `stack` | boolean | True to duck on top of an earlier ducking instead of replacing it. |
| `start` | seconds | Range start in seconds. With `end`, overrides the selection. |
| `end` | seconds | Range end in seconds. |

### `remove_track`

Removes a track with its clips and automation; a plugin elsewhere keyed by it loses the key. Its files are not touched. A document keeps at least one track; a locked track can't be removed. One undo step.

| Param | Type | Description |
|---|---|---|
| `track` | string | **Required.** Track id. |

### `duplicate_track`

Puts a copy of a track right under it: the same clips, level, pan, plugins, sends and automation, with ids of its own; not locked and not frozen. Returns the copy's id as ids.track. One undo step.

| Param | Type | Description |
|---|---|---|
| `track` | string | **Required.** Track id. |
| `name` | string | The copy's name. Default: the track's name and "copy". |

### `move_track`

Moves a track in the order of the lanes and the mixer: to a place (index, 0 the top) or up or down by some places (by, e.g. -1 for up). One undo step.

| Param | Type | Description |
|---|---|---|
| `track` | string | **Required.** Track id. |
| `index` | number | Its new place, 0 the top. |
| `by` | number | Places to move: negative up, positive down. |

### `set_track`

Changes one track: its gain, mute, name, pan, its place in a surround layout, or the bus it goes to.

| Param | Type | Description |
|---|---|---|
| `track` | string | **Required.** Track id. |
| `gainDB` | number | The track's gain in dB: the new value, not a change to the old one. |
| `muted` | boolean | True to mute. |
| `locked` | boolean | True to lock the track: no step may then change its clips (or remove it) until it is unlocked. Level, pan, mute and the mixer stay free. |
| `name` | string | A new name. |
| `pan` | number | −1 (left) to 1 (right), 0 the center. Stereo documents only. |
| `azimuth` | number | Documents wider than stereo: where the track's mono or stereo sound comes from, in degrees, positive to the left (0 the center, 90 the left side, ±180 behind; ITU-R BS.2051's convention). Placing a track this way uses the surround panner (pairwise vector base amplitude panning at constant power). A source of more than two channels on the track stays on its own loudspeakers. |
| `elevation` | number | Documents with height loudspeakers (7.1.4): degrees up, 0 to 90; the height layer is at 30, and above it the sound stays there. |
| `width` | number | For a stereo source: the angle between its two sides, centered on azimuth. Default 60 (at azimuth 0, exactly L and R). |
| `placed` | boolean | false takes the track out of the surround panner again: each source back on its own loudspeakers (a voice in C, a pair in L and R). |
| `field` | number | The track's files are a sound field (AmbiX) of this order, 1–3 (a file of 4, 9 or 16 channels); 0: they are not. Into loudspeakers a field is decoded (AllRAD), into mono or stereo by way of 5.1. Making a document Ambisonics marks its files of that size already. |
| `yaw` | number | A track that plays a sound field: the field turned round the listener, degrees, positive to the left. |
| `pitch` | number | The field's front lifted (positive) or lowered, degrees. |
| `roll` | number | The field's left side lifted (positive) or lowered, degrees. |
| `turned` | boolean | false takes the field's turn away (yaw, pitch and roll back to 0). |
| `output` | string | The id of the bus the track goes to, or "master" for the output. |

### `add_bus`

Adds a bus to the mixer: tracks routed to it (set_track output) are summed, given the bus's gain and pan, and passed on to the output or to another bus. The answer's `bus` is its number in `GET …/mixer`, where its id is.

| Param | Type | Description |
|---|---|---|
| `name` | string | **Required.** What the bus is called. |
| `output` | string | The id of the bus this one feeds. Default: the output. |

### `set_bus`

Changes one bus: its name, gain, pan, mute, or where it goes. A route that would send a bus back into itself is refused (reason routing_loop).

| Param | Type | Description |
|---|---|---|
| `bus` | string | **Required.** Bus id (GET …/mixer shows it). |
| `name` | string | A new name. |
| `gainDB` | number | The bus's gain in dB: the new value. |
| `pan` | number | −1 (left) to 1 (right), 0 the center. Stereo documents only. |
| `muted` | boolean | True to mute everything that goes through the bus. |
| `output` | string | The id of the bus this one feeds, or "master" for the output. |
| `azimuth` | number | In a loudspeaker layout wider than stereo: the bus's whole image turned round the listener, in degrees, positive to the left (each channel re-panned from its loudspeaker's direction plus the turn; the LFE as it is). Not in mono, stereo or Ambisonics. |
| `yaw` | number | In an Ambisonics document: the field the bus carries turned round the vertical, in degrees, positive to the left (after its fader; the same turn as a track's). |
| `pitch` | number | In an Ambisonics document: the bus's field tilted, positive lifting the front. |
| `roll` | number | In an Ambisonics document: the bus's field rolled, positive lifting the left side. |
| `turned` | boolean | false takes the turn away (the azimuth's, or in Ambisonics the field's). |

### `set_send`

Sends a copy of a track or a bus to a bus, at a level of its own: for a shared reverb, a parallel compressor, a headphone mix. One send per pair; giving it again changes it, and `remove` takes it away. After the fader by default (the copy follows the strip's level and pan); with `pre` it is taken before them. A send that would lead a bus back into itself is refused (reason routing_loop).

| Param | Type | Description |
|---|---|---|
| `from` | string | **Required.** The id of the track or bus the copy is taken from. |
| `to` | string | **Required.** The id of the bus it goes to. |
| `gainDB` | number | The send's level in dB. Default 0 for a new send. |
| `pre` | boolean | True: before the fader and pan. Default false. |
| `remove` | boolean | True takes the send away. |

### `add_vca`

Adds a VCA group: no audio goes through it; its level is added to the fader of every track and bus that belongs to it and its mute mutes them, so they move together while each keeps its own level, plugins and route. The answer's `ids.vca` is the new group's id.

| Param | Type | Description |
|---|---|---|
| `name` | string | **Required.** What the group is called. |
| `members` | list | The ids of the tracks and buses to put in it. A strip is in one VCA at most; it leaves the one it was in. |

### `set_vca`

Changes a VCA group: its name, its level, its mute, or which strips belong to it. Sends taken before the fader don't follow a VCA, as they don't follow the fader. A strip that leaves a group loses what the group added to its level.

| Param | Type | Description |
|---|---|---|
| `vca` | string | **Required.** VCA id (GET …/mixer shows it). |
| `name` | string | A new name. |
| `gainDB` | number | The group's level in dB, added to each member's own: the new value. |
| `muted` | boolean | True mutes every member. |
| `members` | list | The ids of the tracks and buses that belong to it, in place of the ones that did. |
| `add` | list | Ids of tracks and buses to put in the group. |
| `remove` | list | Ids of tracks and buses to take out of the group. |

### `remove_vca`

Takes a VCA group away and leaves the sound as it was: the group's level goes into each member's own, and members of a muted group stay muted.

| Param | Type | Description |
|---|---|---|
| `vca` | string | **Required.** VCA id. |

### `set_master`

Changes the master, which everything goes through last: its gain, and a true-peak limiter after everything else (every track, bus and plugin). With the limiter on, an export is measured as written and rendered again further under the ceiling until the file holds it; playback has one pass and aims 0.1 dB under. Plugins go on the master with `add_insert` and `track: "master"`.

| Param | Type | Description |
|---|---|---|
| `gainDB` | number | The master's gain in dB. |
| `limiter` | boolean | True puts the limiter on (with the values given, else the ones it had, else the defaults); false takes it off. |
| `ceiling` | number | The true peak to stay at or under, in dBTP, −20 to 0. Default −1. |
| `release` | number | How fast the gain comes back, in milliseconds, 1–2000. Default 100. |
| `lookahead` | number | How far ahead a peak is seen, in milliseconds, 0.5–20. Default 5. |

### `remove_bus`

Takes a bus away. Refused while tracks or buses are routed to it (reason in_use), unless `reroute` says where they go instead.

| Param | Type | Description |
|---|---|---|
| `bus` | string | **Required.** Bus id. |
| `reroute` | string | Where what was routed to the bus goes: a bus id, or "master". |

### `set_group`

Moves the gain of every track in a group (the stems of one separated track) by the same amount, so their balance stays.

| Param | Type | Description |
|---|---|---|
| `group` | string | **Required.** Group id (GET …/tracks shows it). |
| `gainDB` | number | **Required.** Change in dB, added to each track's gain. |

### `level_speakers`

Brings every speaker to the same loudness with one gain each, measured over their own turns (needs diarize first; fails with reason no_speakers otherwise). A track that is one speaker gets track gain; a track with several is split in the pauses where the speaker changes. Run loudness_preset afterwards for the mix. info: speakers, maxChangeDB, limitedByMaxGain.

| Param | Type | Description |
|---|---|---|
| `mode` | string | static: one gain per speaker (default). dynamic: rides each speaker's gain over time (3 s short-term loudness over their own speech, looking ahead so speech starts don't pump; pauses never lifted); bounces the tracks into new files. info then also has spreadBeforeLU and spreadAfterLU. One of: `static`, `dynamic`. |
| `target` | number | LUFS per speaker. Default -18. |
| `maxGain` | number | Largest change in dB, up or down. Default 12. |
| `speakers` | list | Speaker ids as strings ("0", "1"). Default: everyone. |

### `split_speakers`

One track per speaker found on a track (diarize first), named after them. Together they play exactly what the track did (overlaps go to the longer turn, pauses to the nearer speaker); the original is muted and kept unless keepOriginal is false.

| Param | Type | Description |
|---|---|---|
| `track` | string | **Required.** The track's id or name. |
| `keepOriginal` | boolean | Keep the original track, muted. Default true. |

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
| `track` | string | **Required.** The id of the track, or of the bus, the plugin goes on. |
| `plugin` | string | **Required.** Plugin id from GET /api/v1/plugins (e.g. aufx/lmtr/appl) or its exact name. |
| `position` | number | Place in the chain, 0 first. Default: last. |
| `preset` | string | A factory preset, by name. |

### `set_insert`

Changes a plugin on a track: bypass, a factory preset, or one parameter by identifier (GET …/tracks/{track}/inserts/{insert} lists them with their ranges). A value outside the range fails with reason out_of_range; nothing is clipped. Send several steps to change several parameters at once.

| Param | Type | Description |
|---|---|---|
| `track` | string | **Required.** The id of the track or bus the plugin is on. |
| `insert` | string | **Required.** Insert id (or its name when that's unique on the track). |
| `bypass` | boolean | True to bypass, false to switch back on. |
| `preset` | string | A factory preset, by name. |
| `parameter` | string | Parameter identifier, e.g. global.0, or its exact name. |
| `value` | number | The parameter's new value, in its unit. |
| `position` | number | Moves it to this place in the chain, 0 first (beyond the end: last). info has position. |
| `key` | string | A sidechain key: the id of the track or bus the plugin listens to (its signal after the fader, in step with the audio), or "none" to take the key away. Only for a plugin with a sidechain input (reason no_key_input otherwise); a key that would be fed by what it controls is refused (routing_loop). |

### `remove_insert`

Takes a plugin off a track or a bus.

| Param | Type | Description |
|---|---|---|
| `track` | string | **Required.** The id of the track or bus the plugin is on. |
| `insert` | string | **Required.** Insert id (or its name when that's unique on the track). |

### `loudness_preset`

Brings the range (the whole document without a range or selection) to a delivery target in one step. Without `limit`, it is one gain that stops where the true peak would pass the ceiling; info.limitedByPeak is then 1 and integratedAfter shows what was reached. With `limit`, the limiter holds the peaks at the ceiling so the target is reached, and the answer says what that took.

| Param | Type | Description |
|---|---|---|
| `preset` | string | **Required.** The target. One of: `apple_podcasts`, `spotify`, `youtube`, `ebu_r128`, `atsc_a85`. |
| `start` | seconds | Range start in seconds. With `end`, overrides the selection. |
| `end` | seconds | Range end in seconds. |
| `limit` | boolean | Use the limiter to reach the target when the peaks would stop the gain short of it. Default false: one gain, never over the ceiling. With it, the answer says what the limiter took (`reductionMaxDB`, `limitedSeconds`, `rangeBeforeLU`, `rangeAfterLU`). |

### `acx_match`

Brings the range (the whole document without a range or selection) within ACX's loudness and peaks, as one undo step: the RMS into −23…−18 dB (to −20 when it is outside), the sample and true peak at or under −3 dB, by the limiter at −3.5 dBTP where a gain alone can't. A file already within both is left as it is (info.unchanged 1). The noise floor is measured and said, never changed: info.noiseFloorAfter is the floor after the gain, and info.noiseFloorTooHigh 1 means it is over ACX's −60 dB, for which Reduce Noise (restore, kind denoise) is a choice of its own. Only ACX approves a file; GET …/analysis/acx checks one.

| Param | Type | Description |
|---|---|---|
| `start` | seconds | Range start in seconds. With `end`, overrides the selection. |
| `end` | seconds | Range end in seconds. |

### `add_marker`

Adds a marker, or a region when `duration` is given.

| Param | Type | Description |
|---|---|---|
| `at` | seconds | Position in seconds. Defaults to the selection start, else the playhead. |
| `name` | string | **Required.** Marker name. |
| `duration` | seconds | Region length in seconds. |

### `set_layout`

Sets the document's loudspeaker layout. Nothing is converted: every source keeps its own channels and goes into the new layout by its loudspeakers (a voice to the center, a stereo pair to L and R; a wider source folded down by ITU-R BS.775 and the steps docs/IMMERSIVE.md names). A layout wider than stereo has no stereo pan yet: pan values and pan lanes are not used in it, and pan lanes are not saved while the document is wider than stereo. Exports are in the layout. `order` says how a 7.1 or 7.1.4 file that names no loudspeakers (no channel mask, no ADM chna) is heard; a file that names them is always heard by them. info has `channels`, `fields` and `unmaskedFiles` (how many files the order is a choice for).

| Param | Type | Description |
|---|---|---|
| `layout` | string | The layout. Leave it out to change only the order. One of: `mono`, `stereo`, `5.1`, `7.1`, `7.1.4`, `ambix1`, `ambix2`, `ambix3`. |
| `order` | string | How a 7.1 or 7.1.4 file without a channel mask or ADM is heard: bs2051 (ITU-R BS.2051, the sides before the rears: L R C LFE Lss Rss Lrs Rrs; what a file opened now gets) or wav (the WAV mask's, the rears first: L R C LFE Lrs Rrs Lss Rss). Only the hearing changes, not the file. One of: `wav`, `bs2051`. |

### `set_timecode`

Gives the document the picture's timecode (SMPTE): the frame rate, and the timecode at the start of the timeline. The document then says where the playhead is in timecode (`timecode` in GET …/documents/{id}), and nothing about the sound changes. rate none takes it away. info has `startFrames`.

| Param | Type | Description |
|---|---|---|
| `rate` | string | **Required.** The picture's frame rate. The two ending in df count drop-frame (the clock keeps real time; written with a semicolon before the frames). One of: `23.976`, `24`, `25`, `29.97`, `29.97df`, `30`, `50`, `59.94`, `59.94df`, `60`, `none`. |
| `start` | string | The timecode of the timeline's first frame, as hh:mm:ss:ff (hh:mm:ss;ff for drop-frame). Default 00:00:00:00. A film's sound often starts at 01:00:00:00. |

### `remove_marker`

Removes the markers with this name, or the one marker with this id.

| Param | Type | Description |
|---|---|---|
| `name` | string | Marker name. |
| `marker` | string | Marker id (from the document's markers). |

### `split`

Splits the clips under a point in two, on every track or only on the tracks given. Nothing moves and nothing is heard differently; the halves can then be trimmed, faded or moved on their own.

| Param | Type | Description |
|---|---|---|
| `at` | seconds | Where to split, in seconds. Defaults to the playhead. |
| `tracks` | list | Track ids. Default: every track. |

### `set_marker`

Moves, renames or resizes one marker, by its id (the document's markers list them). What isn't given stays.

| Param | Type | Description |
|---|---|---|
| `marker` | string | **Required.** Marker id. |
| `at` | seconds | New position in seconds. |
| `name` | string | New name. |
| `duration` | seconds | Region length in seconds; 0 for a point. |

### `move_clip`

Moves clips on the timeline, sound and all (their words and fades go with them): `clip` to `at`, or `clip` or `clips` by `by` seconds. Refused, with nothing moved, when one would start before 0 or lie over a clip on its track that isn't moved (reason overlaps, before_start). One undo step.

| Param | Type | Description |
|---|---|---|
| `clip` | string | Clip id. |
| `clips` | list | Clip ids, moved together by `by`. |
| `at` | seconds | The new start of `clip`. |
| `by` | seconds | How far to move, in seconds; negative is earlier. |

### `set_take`

Plays another take of a stretch recorded more than once (a track's `takes` list them: each group's id, its takes with their ids and numbers, and which is chosen). The stretch is laid again from what lay under it before it was recorded, with that take over it; if the takes were moved since, they go with the chosen take's clip. Takes are recorded and deleted only in the window. One undo step.

| Param | Type | Description |
|---|---|---|
| `track` | string | **Required.** Track id. |
| `group` | string | **Required.** The takes' group id (the track's takes list). |
| `take` | string | **Required.** The take to play. |

### `set_clip`

Changes one clip by its id (the tracks' clips list them): trims its start or end on the timeline (the sound stays where it is; a clip can't reach over the next one or past its file), sets its fades and their shape, or its gain. What isn't given stays.

| Param | Type | Description |
|---|---|---|
| `clip` | string | **Required.** Clip id. |
| `start` | seconds | New start of the clip on the timeline. |
| `end` | seconds | New end of the clip on the timeline. |
| `fadeIn` | seconds | Fade-in length in seconds; 0 removes it. |
| `fadeOut` | seconds | Fade-out length in seconds; 0 removes it. |
| `shape` | string | Fade curve. One of: `equal_power`, `linear`. |
| `gainDB` | number | The clip's gain in dB (the new value). |

### `set_tempo`

Sets the tempo, and the time signature when given, from `at` on. Tempo changes move with the audio in ripple edits.

| Param | Type | Description |
|---|---|---|
| `bpm` | number | **Required.** Quarter notes per minute, 10–999. |
| `at` | seconds | Where the tempo starts. Defaults to 0, the start of the document. |
| `beats` | number | Beats per bar (1–64). Give it with `unit`; without both, the time signature in effect at `at` is kept. |
| `unit` | number | Note value of a beat: 1, 2, 4, 8, 16 or 32 (4 is a quarter note). |

### `detect_tempo`

Finds the tempo of music and sets the document's tempo map from it, so the ruler's beats fall on the music's beats. Music whose tempo changes in clear steps gets a map with a tempo per stretch, each change on a beat and a whole number of beats between changes; a tempo that glides (a ritardando) fails with reason tempo_glides and says from what to what and where, to be set by hand. Changes no audio. Only music with a beat has a tempo: for speech, noise or silence it fails with reason no_steady_tempo and nothing is changed. A tempo map that was there is replaced (one undo step; the result's warnings say so). A fast tempo can come back at half speed (174 as 87) or a slow one doubled: GET …/analysis/rhythm lists the alternatives; give multiply 2 or 0.5, or the bpm you know. Where bars begin is not detected: bar numbers on the ruler count from the first beat and say nothing about the music's bars. info: bpm (the first stretch's), firstBeat (seconds on the timeline of the first beat the grid is set from), pulse (how strongly the sound repeats at the beat, 0 to 1; the weakest stretch's), beats (how many were found), tempi (how many stretches), bridges (when there are any: beats between two stretches with a length of their own, each a one-beat change in the map), replaced (the changes of the map that was replaced, when it had more than one).

| Param | Type | Description |
|---|---|---|
| `tracks` | list | Only these tracks' sound. Default: the mix. |
| `start` | seconds | Range start in seconds. With `end`, overrides the selection. |
| `end` | seconds | Range end in seconds. |
| `multiply` | number | 0.5 or 2: the tempo found, halved or doubled. |
| `bpm` | number | The tempo, when you know it (10–999): it has to fit the beat found (or half or double it); only where the beats fall is then taken from the sound. |

### `delete_words`

Removes words from the audio by their transcript, closing the gaps (ripple). Give word ids (best: they stay valid across edits, undo and saving) or the text to find. Text must match in exactly one place, unless you pass `occurrence` or `all`. Words follow each other without gaps, so a pause sits inside a neighboring word (usually the one after it) and goes with that word. info has words and removedSeconds.

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

### `limit`

A true-peak limiter on the range (the whole document without a range or selection): the peaks of the chosen tracks together are held at or under the ceiling, with one gain for all of them so their balance stays. Bounced into a new file per track, sample for sample where the old audio was; where nothing needed limiting the audio is the same bit for bit, the original files are untouched and one undo brings them back. Refused when the peak is already under the ceiling. The answer says the ceiling used, the true peak before and after, the largest reduction and for how long it limited.

| Param | Type | Description |
|---|---|---|
| `ceiling` | number | The true peak to stay at or under, in dBTP, −20 to 0. Default −1. |
| `release` | number | How fast the gain comes back, in milliseconds, 1–2000. Default 100. |
| `lookahead` | number | How far ahead a peak is seen, in milliseconds, 0.5–20. Default 5. |
| `start` | seconds | Range start in seconds. With `end`, overrides the selection. |
| `end` | seconds | Range end in seconds. |
| `tracks` | list | Track ids to limit together. Default: every track. |

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

### `set_automation`

Writes automation: points on the timeline that a strip's level, pan or mute follows (before the first point the value is the first point's, after the last the last's). `gain`: a straight line in dB from point to point, added to the fader, which stays where it is (0 dB is no change). `pan`: a straight line from point to point, −1 left to 1 right, in the place of the fixed pan while the lane is there (stereo documents). `mute`: 1 muted, 0 heard, each held until the next point; the sound closes and opens over 5 ms beginning at the point, so it never clicks, and sends before the fader are silenced too, as by the mute button. `send` with `to` (a bus id): the level of the strip's send to that bus, in dB, added to the send's own level. `strip` may also be a VCA group's id: its gain and mute lanes are added to those of every track and bus in the group, as its fader is. The master has a gain lane only. `points` replace the whole lane; with `start` and `end` they replace only the points inside that range and nothing outside it is touched. A point lands on its own sample, whatever plugins the strip has. Edits that close up or open the whole timeline (delete, paste, removed pauses) move the points with the sound; lining up or stretching one track doesn't, and the answer then carries a warning. Refused with the name of the field: a point after the document's end or outside `start`…`end`, a value outside what the lane takes (−96 to 24 dB, −1 to 1, 0 or 1), two points at one time. info has `points`, how many the lane now has.

| Param | Type | Description |
|---|---|---|
| `strip` | string | **Required.** The id of the track, bus or VCA group, or "master". |
| `param` | string | What the lane moves. Default gain. plugin: one parameter of a plugin on the strip (`insert` and `parameter` say which), in the parameter's own unit, a straight line between points, set once every 512 frames; for now only where the plugin is an Audio Unit (another kind answers not_available). One of: `gain`, `pan`, `mute`, `send`, `plugin`, `azimuth`, `elevation`, `yaw`, `pitch`, `roll`. |
| `to` | string | For param send: the id of the bus the send goes to. The send must be there (set_send). |
| `insert` | string | For param plugin: the plugin on the strip, by its id or its name. |
| `parameter` | string | For param plugin: the parameter, by its identifier or its name (GET …/tracks/{id}/inserts/{insert} lists them with their ranges). |
| `points` | pairs | **Required.** The points: [[seconds, value], …]; the value is dB for gain (−96 to 24), −1 to 1 for pan, 1 or 0 for mute, and for a plugin's parameter a value in that parameter's own range; for azimuth degrees −360 to 360 (positive to the left, past ±180 on round behind) and for elevation 0 to 90: a track's place in a document wider than stereo, moving in a straight line between points, worked out every 512 frames and glided in between; for yaw (−360 to 360), pitch (−90 to 90) and roll (−180 to 180) degrees: a track's sound field turned (set_track field), worked out every 512 frames and glided in between along a curve through the next two. An empty list with `start` and `end` takes the points in that range away. |
| `start` | seconds | Start of the range to replace, in seconds. With `end`. |
| `end` | seconds | End of the range to replace, in seconds. With `start`. |
| `enabled` | boolean | False keeps the lane but stops it being heard; true brings it back. |

### `clear_automation`

Takes the points of one lane away: all of them, or with `start` and `end` those inside that range. One strip and one lane at a time; nothing clears a whole project. info has `removed`.

| Param | Type | Description |
|---|---|---|
| `strip` | string | **Required.** The id of the track, bus or VCA group, or "master". |
| `param` | string | **Required.** Which lane. One of: `gain`, `pan`, `mute`, `send`, `plugin`, `azimuth`, `elevation`, `yaw`, `pitch`, `roll`. |
| `to` | string | For param send: the id of the bus the send goes to. |
| `insert` | string | For param plugin: the plugin on the strip, by its id or its name. |
| `parameter` | string | For param plugin: the parameter, by its identifier or its name. |
| `start` | seconds | Start of the range to clear, in seconds. With `end`. |
| `end` | seconds | End of the range to clear, in seconds. With `start`. |

## Good to know

- Nothing is destructive: clips play from the original files, so you can always undo. `GET /api/v1/documents/{id}` shows the clips.
- Measure before and after: `analysis` gives the numbers, `waveform` shows the shape.
- An export is at the document's own sample rate and channel count (`sampleRate`, `channels`) unless you pass `sampleRate` to `export`; then the file is converted and the document stays as it is.
- To put one document's audio into another, export it as WAV and send the bytes to the other document's `…/tracks`. The clipboard steps (`copy`, `paste`) work inside one document.
- `analysis` and `export` cover the whole mix; there is no way yet to measure or export one track alone. To check a track you added, read its clip (`start`, `end`, `gainDB`) in `GET …/documents/{id}`, or compare a stretch of the mix where the other tracks are silent.
- `undo`, `redo` and `steps` answer with the document as it is afterwards, so there's no need to fetch it again. A range that reaches past the end of the document is clamped; the answer says what was used.
- Several changes are one undo step only when they go in one `steps` request. Calls with their own endpoint (adding a track, a repair, a transcription) are each a step of their own, so "undo the last change" undoes the last request, not the last task.
- Common targets: podcasts −16 LUFS (Apple) with true peak at most −1 dBTP; EBU broadcast −23 LUFS.
- The user may be editing the same document. Read it before you act on it, and keep requests small.
- `tempo.changes` in the document lists each tempo change with `at` (seconds), `bpm` and `meter` (e.g. `"3/4"`); the first is at 0. The API speaks seconds only: to work in bars and beats, compute them yourself from `tempo.changes`. A beat lasts 60 / `bpm` × 4 / unit seconds, and a new time signature starts a new bar.
- Playback is for the user to hear what you did. Don't start it unless they asked; recording can only be started by the user.
