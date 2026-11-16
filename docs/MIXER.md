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
- The export that can't be held never happens with a working limiter, so it was provoked once: a debug build started with `-masterMeasureOffsetDB 60` reads every file 60 dB hotter than it is. Through the app's API: 422, `reason: "ceiling_not_met"`, the measured peak and what to do in the message, no file and nothing left in the temporary folder. Not seen: the same words in the window after File › Export (it is the same error's text).
- After a seek the limiter's output is the unbroken run's to within 1e-3, not bit for bit: what it did before the run-in is not known to it. That is for playback; an export always runs from its own start, in one stream.
- The Plugins sheet on a bus, as a picture (a debug build opens it on a strip with `-pluginsStrip <name>`): the picker says "Speech (bus)" and the bus's plugin is listed with its switch, Edit and bin.
- `set_master` is not offered to the assistant yet.

**Step 5, 2026-11-16: VCA groups.** `Project.vcas`, `Track.vca`, `Bus.vca`. Nothing in the engine: when the plan is compiled a member's fader is its own level plus the group's and its mute is its own or the group's (`Project.heard`). Steps `add_vca` (`name`, `members`), `set_vca` (`name`, `gainDB`, `muted`, `members`, `add`, `remove`), `remove_vca`. `GET …/mixer` has `vcas`, and `vca` and `heard` on every track and bus.

- Different from the sketch: membership is set on `set_vca`, not with a `vca` parameter on `set_track` and `set_bus`. `set_bus` is an action the assistant has, and changing its description means running the evaluation sets; this keeps the groups in their own steps.
- Removing a group folds its level into each member's own (and leaves the members of a muted group muted), so the sound doesn't change.
- Tested (`VCATests`): at 0 dB bit for bit the same; −6 dB on the group is the same samples as −6 dB on each member; a bus as a member; a pre-fader send doesn't follow the group and a post-fader one does; removal keeps the samples; one group per strip; refusals change nothing; a hostile file (twins, a member of a group that isn't there, an absurd level) is mended and said. With the group's level ignored once, three of the four failed.
- In the app: a group of both tracks at −6 took the mix from −15.42 to −21.42 LUFS; one member taken out, −16.77; the group muted, only the other track (−13.92); removed again with both in it, −21.42 before and after, each track at −6 of its own. The group's Mute box found by its id and clicked: silence. The Members menu read with its ticks, and the sheet looked at as a picture: the list of strips was too short and cut the group's row off, so the list is now as tall as what is in it (up to a limit, then it scrolls).
- A strip in a group says under its row what is heard (its own level with the group's, or that the group's mute is why it is silent), read in the app and looked at as a picture. The slider stays the strip's own level.
- The VCA steps are not offered to the assistant yet.

**Solo, 2026-11-16** (taken before step 6). A listening state of the window, not of the document: `EditorSession.solo`, and the playback plan is compiled from `Project.listening(solo:)`, a copy in which every track that doesn't reach a soloed strip is muted. Exports, measurements and bounces compile from the project itself. `POST …/solo`, `solo` in `GET …/mixer` (`strips`, `heardTracks`, `affects: "listening"`), a Solo box on every strip, the window's title and an orange line in the mixer while it is on.

- Tested (`SoloTests`): one track, two, a bus reached by output, through another bus and by a send; buses are never muted by solo; a muted track stays muted; ids that are no strips count for nothing; the document is untouched.
- In the app: with the music soloed the measurement was the same (−15.42 LUFS) and the export the same file, byte for byte, as before; an edit and its undo left the solo on; an id that is no strip got 404; the window's title read "Solo: Music (listening only; exports are not affected)"; the Solo box found by its id and clicked; the sheet looked at as a picture.
- What goes to the device, measured without a sound: a test copy of the app (debug, `-silentOutput YES`, which `scripts/with-app.sh` always passes) hands the device silence and counts what it would have handed over. Three seconds played from 3.0 s, the level that went out beside the same stretch rendered offline as listened to and as the document: no solo −13.76 / −13.76 / −13.76 dB; the music soloed −14.27 / −14.27 / −13.75; the speech soloed −23.32 / −23.32 / −13.75; both soloed −13.74 / −13.74 / −13.74; everything muted, silence. (`GET …/debug/heard`, debug builds only.) That the device then really gets zeros is one line in the device callback, read and not measured.

**Step 6, 2026-11-16: sidechain keys, in debug builds only.** `Insert.key` (the id of a track or bus), `set_insert` with `key` (an id, or `"none"`), and on every listed insert `key`, `hasKeyInput` and, when the plugin has the input but can't be fed here, `keyRefusal`. Hidden from users and from release builds (`Operations.sidechain`, on only under `#if DEBUG`) until rehearsal item 7 in `docs/RELEASE.md` is done: **no effect on this Mac has a sidechain input** (all 23 installed have one input bus; counted), so no other vendor's plugin has been through it.

- The engine: a unit can have a key input (an Audio Unit pulls it on its second input bus; a processor gets it as an argument). A chain delivers a key to a unit as late as the units before it make the audio. With a key in the plan every strip is a node in the mixer graph, in an order where a key's source comes before its listener; the tracks' chains then run as streams, a listening track's own audio is taken as much earlier as its key is late, and a key edge has a delay line like any other path. The key is taken after the source's fader and pan; a muted source is a silent key. A plan without a key takes the paths it took before.
- Tested with a stand-in of known arithmetic (`MixerKeyTests`: where the key isn't silent the audio is a quarter, then late by the unit's latency): a steady level gated by a click on another track is a quarter on exactly that frame, with the gate's latency at 0, 100 and 777, behind other units in the chain, with a late plugin on the key's own track, with the key taken from a bus with a late plugin, with a bus as the listener, and with a key that has to wait for late audio; the same samples in blocks of 1, 333, 512 and 4 097 and after seeks; without a key the plan is the plain mix bit for bit. Four planted faults, each caught: the key not delayed with the chain, the key's delay line off (this one needed a test that didn't exist yet), the listening track not taken early, and an off-by-one in the Audio Unit's key feed.
- Tested through an Audio Unit (`KeyedAUTests`): a unit of our own with two input buses, registered in the test process only, nothing installed. It is seen to have the input, a key reaches it on the frame, also behind Apple's limiter; saved and opened the key is still there.
- Loops: a key from a strip that the listener feeds (by output, send or another key) is refused where it is set (`routing_loop`), and so is a route or a send that would close a loop through an existing key; a file that has one is mended and says so; the engine drops what would loop without trusting any of that. Removing a bus clears the keys taken from it.
- Refused in words: a plugin without the input (`no_key_input`, seen in the app with AUDynamicsProcessor), an Audio Unit that runs in a process of its own (Safe Mode, or macOS refusing to load it in-process), a plugin on the master. CLAP plugins say they have no key input; that path isn't built.
- Cost, measured (`MixerBaselineTests/withAKey`, load average 10 to 17, medians of two rounds): 16 tracks × 2 plugins with 4 buses × 2: 0.89 and 0.93 ms per block without a key, 0.63 and 0.59 ms with one. 64 tracks × 2 with 8 buses × 2: 3.35 and 3.23 ms without, 1.65 and 1.74 ms with. The graph path is the cheaper one: the tracks' own pulling chains pay for their per-sample queues. (Not acted on: moving every plan to the graph would change the path of every project with a plugin.)
- **Another vendor's plugin, 2026-11-16** (`ThirdPartyKeyTests`, run only when given the plugin by path; see `docs/LICENSES.md`, "Used in tests only"): a compressor with an external side-chain, built from its source by itself and not installed. Jämmer sees its sidechain input. A quiet tone through it, with a loud burst on another track from 1.0 to 2.0 s: with nothing keyed the tone is −23.01 dB before and during; keyed from the burst track it is −23.01 dB before, −23.02 dB in the tenth of a second just before the burst, −83.20 dB during, and −23.01 dB a second after; with the plugin told to listen to its own input the burst changes nothing; keyed from a bus the burst goes through, behind Apple's limiter on that bus, −23.01 / −23.02 / −83.20 dB again. So the key arrives, on time, and only when the plugin is set to use it.
- **The same plugin in the app, 2026-11-16**: a debug build started with `-registerAudioUnit <path>` loads the component in its own process (nothing installed). The compressor on the music track, set to its external side-chain: the music alone, where the speech talks, measured −14.0 LUFS with no key and −19.12 LUFS keyed from the speech track, and −14.0 again with the key taken away; three seconds played keyed went out at −20.23 dB, the same as rendered, with no gaps counted; the mix exported. The Plugins sheet has a Key menu on a plugin that has the input (only in builds with sidechain keys): read with its tick on the speech track, and looked at as a picture.
- Soloing a keyed track, or exporting or measuring it alone, keeps its key: the key's track goes on playing into a muted bus instead of being muted (a muted track is a silent key). Found while planning the pass above; before it, soloing a ducked track would have un-ducked it. Tested (`KeyedAUTests.soloKeepsTheKey`).
- Not verified: Safe Mode's refusal as it appears in the app (a plugin registered in the process can't be loaded outside it, so the case needs an installed plugin); CLAP. Sidechain keys stay in debug builds only until that is decided.

**Step 7, 2026-11-16: freeze.** `Track.frozen` and `Bus.frozen` (`Frozen`: the file's source, where it starts, its length, and a digest of what it was made from). Nothing underneath changes: the strip keeps its clips and plugins, and `Project.played()`, which the plan compiler goes through, plays the file instead. Endpoints `POST …/freeze` (a job) and `POST …/unfreeze` (at once), each `{"strip": id}`; `frozen` on every strip in `GET …/mixer`; a Frozen box on every strip.

- Different from the sketch: one path for tracks and buses with the strip in the body (the registry has one call per operation), and unfreezing is not a job (it takes no time).
- What is frozen is the strip as it sounds in the mix, before its own fader: rendered from a copy of the project in which everything else still runs but ends in a muted bus, so a plugin that listens to another track, and a bus's inputs, are in the file.
- A frozen bus plays its file in place of everything that fed it. Strips that reach the output only through frozen buses are not worked out at all (muted, no plugins); a track that also has another way out still plays for that.
- What a file was made from can't change under it: after every step, and in the window's own commit, the frozen strips' digests are compared, and a change is refused (`frozen`, with the strip's name). The digest covers a track's clips and plugins and whatever its plugins listen to (after that strip's fader); for a bus its plugins and everything that arrives, with levels, pans, mutes and sends. The frozen strip's own fader, pan, mute, sends and route are not in it.
- Tested (`FreezeTests`, with Apple's plugins): a frozen track against live, under −90 dB (and the same after its fader, pan, a pre-fader send and its mute are changed); thawed, the project equals what it was; a frozen bus against live; the track that only fed it is muted when played and the one with a send still plays; a level, a clip or a new route upstream of a frozen bus is a violation and a track that never reached it isn't; a keyed track is frozen with what it heard, and moving or fading the key's track is a violation. With the plugins left running on top of the file once, two of the tests failed.
- In the app: a speech track with two plugins and a bus with one, both frozen: −15.41 LUFS before and after, and **the export the same file byte for byte**; `gain` on a range and a plugin on a track feeding the frozen bus got 422 `frozen` with the strip's name; the frozen track's own level changed the mix as it should; frozen twice got `already_frozen`; three seconds played frozen went out at −13.75 dB, the same as rendered; the Frozen box found by its id and clicked thawed the track; unfreezing something that isn't frozen got `not_frozen`. The sheet looked at as a picture.
- Disk: the freeze checks for room first. The file is one of the project's sources while the strip is frozen, so it is saved into the project's package with the rest and leaves the project when the strip is thawed. Nothing removes files from the media folder by itself, ever; since 2026-11-16 **File › Storage…** shows what is there and lets the user move what no project uses to the Trash (see `docs/CHANGES.md` and the manual's Storage chapter).
- A file that carries a freeze whose file is missing, or whose strip is no longer what the file was made from, opens with that strip live, and says so.
- The freeze endpoints are not offered to the assistant yet.

**Every plan through the graph: shown equal, not switched on yet (2026-11-16).** `PlanCompiler.graphForAll` (and `allInGraph:` on `compile`; `JAMMER_GRAPH_FOR_ALL=1` in a debug build's or a test run's environment) sends every plan through the mixer graph, as plans with a key already go. It is off: the older paths (the plain renderer, `renderRouted`, tracks' chains pulling for themselves) are what runs, until the worst block has been measured on a quiet Mac.

- The same samples: `GraphEquivalenceTests` renders 21 kinds of project both ways, whole and after seeks, and the graph in 512-frame blocks against itself: all bit for bit (plain; track gains; clip gain and fades; a muted track; clips moved, cut, crossing, and starting in another order than their tracks; pan; a bus; nested buses with sends before and after the fader; a VCA group; master gain; the master limiter idle and working; Apple's plugins on one track, on every track, on a bus, on tracks and buses with a send; a plugin with latency between tracks without; a soloed track; mono).
- It wasn't so at first. Six kinds differed in the last bit (at most 6e-8, −145 dB) for two reasons, both about the order of arithmetic, both now the old order: the strips were summed in the order the graph happened to find them (now: tracks in their order, then buses in theirs, and a key changes that only as far as it must); and the plain renderer sums the clips of tracks without plugins in the order of their starts, with the track's gain folded into the clip's, before the tracks with plugins (the graph now does exactly that for a plan that uses nothing of the mixer).
- The whole test suite, 425 tests, passes with `JAMMER_GRAPH_FOR_ALL=1`.
- Cost, medians and means on a Mac that was not quiet (load 8): without plugins the same within what could be told apart (64 stereo tracks 0.195 against 0.192 ms a block, mean); with plugins about half (64 tracks × 2 plugins and 8 buses × 2: median 2.67 against 1.33 ms; 64 × 2 without buses: 2.61 against 1.20 ms). The worst block is not measured.
- What changes for an agent when it is switched on: `totalLatencySamples` then includes the tracks' own plugins (they are no longer made up for inside each track), and a track's `compensationSamples` is the wait added to it for that reason. The mix is on the sample either way.
- To do before the older paths are removed: the worst block on a quiet Mac, both ways; then switch on, run everything again, and delete `renderRouted`, the plain loop in `Renderer::render` and `Chain::process`.

**Still to do in the mixer:** move every plan to the graph (agreed 2026-11-16, with its conditions), the measurements that wait for a quiet Mac, sidechain in the app, the assistant's actions with their evaluation.

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
