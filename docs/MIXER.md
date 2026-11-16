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

Not built: sends, delay compensation across buses, the master strip and its limiter, VCAs, sidechain keys, freeze, solo, plugins on buses.

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
