# Mixer: buses, sends, VCA, sidechain, delay compensation, freeze

Phase 3, part 2. The sketch as the coordinator approved it on 2026-11-16, with the measurements it rests on, and what has been built of it.

## Built so far

**Step 1, 2026-11-16: buses, routing and pan.** `Bus` and `Track.pan`/`output` in the model; the engine sums each track into its bus or the output and each bus into the one it feeds (`renderRouted`), a path taken only when the project uses the mixer. Steps `add_bus`, `set_bus`, `remove_bus`, and `pan` and `output` on `set_track`; `GET …/mixer`; **Audio › Mixer…** (⌥⌘X).

- Tested (`MixerTests`): a project that uses none of it is the same file and the same samples; through a bus at 0 dB in the centre the mix is bit for bit the unrouted one; bus gains multiply through nested buses to within 1e-7; a muted bus silences what goes through it and nothing else; the same output in 512-frame blocks as in one piece; pan exact at the centre and at both ends, never over 1; loops, missing buses, a bus in use, a 65th bus and values out of range refused with their reasons; a bounce of a panned track on a bus is not panned or lowered twice; the limiter keeps the routed mix under the ceiling.
- Hostile files: twin bus ids, routes to nowhere, a loop, levels and pans outside what is possible are put right and said when the project opens; more than 64 buses is refused in words. (JSON has no NaN or infinity, so a file can't carry one.) The engine cuts a loop handed to it as well, without trusting the model.
- The saved format: a project that uses the mixer is format 2; without it, format 1 as before. The package reader refused formats newer than it knows already, so a Jämmer from before the mixer says "saved by a newer Jämmer" for a mixer project. This build reads both.
- Every operation that renders one track by itself for a bounce or an analysis (15 places) renders it without the mixer, so pan and bus are applied once, after.
- In the app: a bus through the API took the music 12 dB down (−15.4 → −19.0 LUFS for the mix), a loop and an in-use removal were refused with `routing_loop` and `in_use`, the sheet read through the accessibility API with every control named, a Mute box ticked by hand landed in the model, and three undos brought the document back to one that doesn't use the mixer.
- The assistant can add a bus by name (given to the on-device model only when the request says bus or submix); changing and removing one need an id it isn't told.

**Step 2, 2026-11-16: sends.** `Send` on tracks and buses (`to`, `gainDB`, `pre`), the step `set_send`, sends in `GET …/mixer`, a Sends menu on every strip of the sheet. The engine orders the buses so that each comes before every bus it feeds, through its output or a send.

- Tested (`MixerTests`): a send after the fader at 0 dB doubles the track to within 1e-7 and goes down with the fader; one before the fader keeps its level and isn't panned; a muted strip sends nothing; bus to bus; one send per pair, changed in place and removed; the same in blocks. Refused: a loop closed by a send or by an output, a bus to itself, a target or a source that isn't there, a level out of range, a 17th send, removing a send that isn't there. A bus taken away takes the sends to it along. In a file: sends to nowhere, twins, a loop by send, an absurd level and too many are tidied and said. The engine cuts a loop of sends by itself.
- In the app: a send of the speech to a bus at 0 dB took the mix from −15.4 to −12.0 LUFS; at −12 dB before the fader, to −14.5; a loop by send answered `routing_loop`; the sheet's Sends menus read named, and the sheet was looked at as a picture.
- A send to a bus only adds to its sum until buses hold plugins; the manual says so.

**The assistant and buses.** The document's description to the model lists the buses by name, and `set_bus` and `remove_bus` take a name, which is turned into the id. `set_send` is not offered to the assistant yet.

**Step 3, 2026-11-16: plugins on buses, and delay compensation.** `Bus.inserts`; `add_insert`, `set_insert` and `remove_insert` take a bus's id where they took a track's; the Plugins sheet chooses a track or a bus. In the engine a bus with plugins makes the plan build a `Graph` (`graph.cpp`): each bus's chain runs as a stream (what leaves is late by its latency), every path into a bus or the output is delayed to the longest one arriving there, and the graph runs ahead by the longest path through the mixer, so the mix comes out on the sample. A seek starts it afresh with a run-in. Without a plugin on any bus there is no graph and the render path is step 2's, bit for bit.

- Tested (`MixerGraphTests`, with a stand-in plugin that is a pure delay): through a bus with 0, 1, 100, 512, 777 and 4 096 frames of latency the mix is the plain mix bit for bit; nested buses (100 + 37) with a send to a third (64): an impulse arrives on its frame by both ways, and the reported delays are 137 for the track that goes straight out and 73 for the side bus; the same samples in blocks of 1, 333, 512 and 4 097 and from any place asked, back and forth; a plugin that fails lets the bus through as late as it would have been; a muted bus is silent and the rest in time. Switching the compensation off once made three of them fail.
- Tested with a real plugin (`InsertTests.busLatency`): Apple's peak limiter (look-ahead, not limiting at that level) on a bus, a second track straight out as witness: best lag 0, residue under −40 dB, the same in 512-frame blocks.
- Reported: `GET …/mixer` has `latencySamples` and `compensationSamples` on every track and bus, `inserts` on buses, `totalLatencySamples` for the document.
- Plugin settings on a bus go through the same trust check as on a track before they are loaded; a file with more than 64 plugins on a strip is cut to 64 and says so.
- A plugin that has a latency and doesn't report it can't be compensated. The manual says so.

**Step 4, 2026-11-16: the master, with the limiter last.** `Project.master` (`gainDB`, `inserts`, `limiter`); a master that does nothing is not saved and the project stays format 1. `set_master` with flat parameters (`gainDB`, `limiter` true/false, `ceiling`, `release`, `lookahead`: the step schema has no object parameters); plugins with `add_insert` and `track: "master"`. In the engine the graph ends: sum → the master's plugins → its gain → the limiter. The limiter is the one `limit` uses (`Limiter.Processor`), wrapped as a unit with a fixed latency of 4 096 + 16 + lookahead + 8 frames (4 360 at 48 kHz and 5 ms), hidden like any other.

- Tested (`MasterTests`): gain within 1e-7; a limiter with nothing to do passes the mix bit for bit and on the sample, also from the middle; one with work holds the ceiling, equals the offline limiter over the plain mix to 1e-4, is the same samples in 512-frame blocks, and after a seek the same to 1e-3; with the master at +6 the ceiling still holds; over a bus with a 300-frame plugin everything is still on the sample. Two planted faults (the latency not hidden; the limiter before the gain) made them fail.
- Exports: the file is measured as written (`EncodedWriter.measureWritten`) and written again at margins 0.1, 0.2, 0.4, 0.8, 1.5, 3 dB until it holds; otherwise `MasterCeilingError`, no file, 422 `ceiling_not_met`. The same in a batch (`BatchTests.masterLimiter`).
- In the app, a mix turned up to +11 dBTP, ceiling −3, each file also measured with ffmpeg's ebur128: WAV 24 bit −3.10 (ffmpeg −3.0), 16 bit with dither −3.10, at 44.1 kHz −3.00, MP3 128k −3.04 at margin 0.2, AAC 96k −3.10 at margin 0.8, master at +12 dB −3.10. Played through it quietly with no gaps counted. The Limiter box found by its accessibility id and clicked: the limiter went off in the model. The sheet looked at as a picture: the note about what the limiter promises was cut off by the scrolling list, so the master now sits under the list.
- Hostile files: an absurd master level is brought into range; a limiter with impossible values is left off, and said.
- Not tried: an export that can't be held (the limiter held every one), so `ceiling_not_met` has only been seen as words in a test. `set_master` is not offered to the assistant yet.

Not built: VCAs, sidechain keys, freeze, solo.

## What the render path costs today (measured 2026-11-16)

`JAMMER_MIXER_BASELINE=1 swift test --filter MixerBaselineTests`, on this Mac while two other sessions were building, one core, sources in memory, 512-frame blocks as the playback worker asks for them (10.7 ms of audio each):

| Stereo tracks | Realtime factor | A block takes, mean | worst | worst as a share of the block's time |
|---|---|---|---|---|
| 1 | 1432× | 0.007 ms | 0.015 ms | 0.1 % |
| 8 | 436× | 0.024 ms | 0.084 ms | 0.8 % |
| 32 | 136× | 0.078 ms | 0.115 ms | 1.1 % |
| 64 | 71× | 0.151 ms | 0.217 ms | 2.0 % |
| 128 | 33× | 0.322 ms | 0.508 ms | 4.8 % |

The arithmetic a mixer adds, with the vector routines the engine would use: 64 tracks through a 4 096-frame delay line each, summed into 8 buses with 2 sends per track, the buses summed to a master: **0.106 ms per block, 1.0 % of its time.**

So the mixer itself is cheap. What sets the limit is what it carries: plugins (measured for the plugin pipes in `docs/STRESS.md`) and disk. These are not promises; the mixer is measured again, with plugins on tracks and buses, before the manual says a number.

### With plugins, on tracks and buses (measured 2026-11-16)

`JAMMER_MIXER_BASELINE=1 swift test --filter MixerBaselineTests/withPlugins`: Apple's low-pass and peak limiter, in process, 512-frame blocks, one core, two runs. The Mac was busy with other sessions (load average 12 to 22), so single blocks were late at places that moved from run to run and were gone in the other run; **the medians hold, the worst figures say nothing about Jämmer and are left out.** The first block after a seek carries the run-in of every chain.

| Tracks × plugins | Buses × plugins | Units | A block takes, median (two runs) | share of its 10.7 ms | First block after a seek |
|---|---|---|---|---|---|
| 8 × 1 | 2 × 2 | 12 | 0.31 / 0.71 ms | 3–7 % | 9–19 ms |
| 16 × 2 | 4 × 2 | 40 | 0.71 / 1.15 ms | 7–11 % | 22–28 ms |
| 32 × 2 | 8 × 2 | 80 | 1.50 / 2.69 ms | 14–25 % | 45–66 ms |
| 64 × 2 | 8 × 2 | 144 | 2.97 / 5.61 ms | 28–52 % | 102–269 ms |
| 64 × 0 | 8 × 2 | 16 | 0.39 / 0.39 ms | 4 % | 5–8 ms |
| 64 × 2 | none | 128 | 3.09 / 3.39 ms | 29–32 % | 24–174 ms |

What it says: the graph and its delay lines cost next to nothing (the fifth row); the plugins are the cost, about 0.02 ms per light Apple unit per block. A third-party plugin can cost a hundred times that. **Not measured: the worst block on a quiet machine, and playback itself with these loads (drop-outs heard or counted).** Until both are, the manual gives no number of tracks or plugins.

Where it runs: in the render worker and the offline renderer, like insert chains today, never in the device callback. The worker renders ahead of the playhead, which is also what hides delay compensation from the listener.

## The model, and why old projects open unchanged

Everything new is optional in the file and has a default that means "as before":

- `Project.buses: [Bus]`, default none. A bus: `id`, `name`, `gainDB`, `pan`, `isMuted`, `inserts`, `output` (another bus, or nil for the master), `sends`.
- `Project.vcas: [VCA]`, default none: `id`, `name`, `gainDB`, `isMuted`. A VCA carries no audio; it moves the faders of its members.
- `Project.master: Master`, default gain 0, no inserts, no limiter.
- `Track` gains `pan` (default centre), `output` (default the master), `sends` (default none), `vca` (default none), `frozen` (default nil).
- A send: `to` (a bus), `gainDB`, `pre` (before the fader, default false).

A project without any of it renders through exactly the code path it does today, and a null test holds that: every existing golden render and null test stays as it is. A project from an older Jämmer has none of the fields, so it decodes to the defaults; saved again it carries the defaults, which an older Jämmer ignores (unknown keys) and plays as before. A project that uses buses, opened in an older Jämmer, would play every track straight to the output: the file gets a `needs` list ("mixer") that an older version can't know to check, so this is said in the manual rather than prevented.

Solo is not in the model. It is a listening state of the window: it changes what is heard, never what is exported, is not an undo step and is not saved. Mute is in the model, as it is today.

## Signal flow

clips → the track's inserts → pre-fader sends → fader (the track's gain plus its VCA's) and pan → post-fader sends → the track's output (a bus or the master). A bus: the sum of what is routed and sent to it → its inserts → fader and pan → its output. The master: the sum → its inserts → its fader → the limiter, when one is set, last of all → out.

- Routing can't loop: a bus may not feed itself through any chain of outputs and sends. Refused when set (422 `routing_loop`), and a project file that has one is not opened as it is (see hostile files).
- Pan is equal-power for a mono source in a stereo document and a balance for stereo; centre is exactly 1.0 on both sides, so an unpanned track is bit for bit what it is today.
- The existing `Track.group` (the stems of one separated track) stays what it is, a label; `set_group` keeps working. A VCA is the general tool.

## Delay compensation, and how it is reported

Each insert reports a latency (as today). A strip's own latency is the sum of its inserts'. At every point where signals meet (a bus input, the master), the shorter paths are delayed to the longest, send paths included. Offline renders and exports come out with the mix at time 0, as a single chain does today.

`GET …/mixer` says, for every track and bus: `latencySamples` (its own inserts), `compensationSamples` (the delay added to it so it lines up), and for the document `totalLatencySamples`. A plugin that reports no latency but has one can't be compensated; that is said in the manual, not hidden. A test per case, built like the plugin latency tests: an impulse through a strip with a known latency arrives on the sample, alone and through a bus and a send.

## Sidechain

An insert can name a key input: a track or a bus (`"key": id`). The plugin gets that signal on its second input bus (AU, CLAP and VST 3 all have the notion; a plugin without a sidechain input refuses the setting in words). The key is taken post-fader, compensated like any other path. `duck` stays the offline operation it is; a live ducker is a compressor with a key, which this makes possible with the user's own plugin. A built-in live ducker waits for automation (part 3), and existing documents with a bounced `duck` open and play unchanged then too.

## Freeze

A track or a bus rendered through its inserts into a file, and played from that file with the inserts idle: for sessions with more plugins than the Mac plays. `frozen: {file, what it was made from}`. While frozen, the strip's gain, pan, sends and mute stay live (they come after the frozen file); steps that would change what was frozen (its clips, its inserts) answer 422 `frozen` and say to unfreeze first. Unfreeze goes back to the live strip. Freeze and unfreeze are jobs (they take time) and one undo step each. The frozen file is a float file in the project's media, like a bounce.

## The limiter on the master

`limit` as built stays: a bounce, measured until the ceiling holds, before the tracks' plugins (and it says so). With the mixer the limiter also exists where it belongs, last on the master, after every bus and plugin: `set_master {"limiter": {"ceiling": −1}}`.

- In an export, the master limiter runs as the bounce does: the file is measured as written and the pass repeated with a larger margin if needed, so the promise holds for the file.
- In playback there is no second pass, so it aims 0.1 dB under the ceiling and the meter shows the true peak as it is. The manual says the guarantee is for exports.
- Its lookahead is a latency like any other and is compensated.

## What an agent can do, and what is only in the interface

Steps (the one schema: menu, ⌘K, App Intents, agent API), each one undo step:

| Step | Does |
|---|---|
| `add_bus` | `name`, `output` (bus id, default master). Answers the new bus's id |
| `set_bus` | `bus`, and any of `name`, `gainDB`, `pan`, `muted`, `output` |
| `remove_bus` | `bus`; refused while anything is routed or sent to it, unless `reroute` names where those go |
| `set_track` (exists) | gains `pan`, `output`, `vca` |
| `set_send` | `from` (track or bus), `to` (bus), `gainDB`, `pre`; `remove: true` takes it away |
| `add_vca`, `set_vca`, `remove_vca` | `name`; `gainDB`, `muted`; members are set with `set_track`/`set_bus` `vca` |
| `set_master` | `gainDB`, `limiter` (`{ceiling, release, lookahead}` or null) |
| `set_insert` (exists) | gains `key` (sidechain source), and works on a bus and the master as on a track |

Endpoints: `GET …/mixer` (the whole structure with levels, routing, latencies, and what is frozen); `POST …/tracks/{id}/freeze`, `…/unfreeze`, the same for buses (jobs); `POST …/solo` `{"strips": [ids]}` (listening state: not a step, not undoable, not saved; the answer says it doesn't change exports).

Only in the interface: the mixer panel with its faders and meters, dragging to route, plugin windows. Everything they do goes through the steps above, so nothing can be done by hand that an agent can't do, except listen.

The assistant: the new actions are given to the on-device model only when the request names them (bus, send, pan, VCA, master, freeze, in Swedish and English), and the evaluation sets are run when they are added, as the rule from 2026-11-16 says.

## Hostile and broken files

Checked when a project is opened, like the rest of `ProjectSafety`: a routing loop; an output, send, VCA or key that names something that isn't there; gains and pans outside their ranges, or not numbers; more than 64 buses, 16 sends on a strip or 32 VCAs; a frozen file outside the project's media or of another length or format than the strip. Each is refused or repaired in words, with a generator in the test suite per case.

## Order of building

Each step ends with a document that works, tests that null against today's render where nothing new is used, the manual and the site.

1. Model, bus summing and pan in the engine, `GET …/mixer`, `add_bus`, `set_bus`, `remove_bus`, `set_track` output and pan. Null tests against today.
2. Sends, pre and post.
3. Delay compensation across buses and sends, and its reporting.
4. Master: gain, inserts, the limiter last.
5. VCAs.
6. Sidechain keys.
7. Freeze.
8. The mixer panel grows with each step; measured again with plugins on tracks and buses before any figure goes in the manual.
