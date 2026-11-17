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
- Not verified: Safe Mode's refusal as it appears in the app (a plugin registered in the process can't be loaded outside it, so the case needs an installed plugin); CLAP. Sidechain keys stayed in debug builds only until it was decided: on 2026-11-17 Anders decided that they are on in Release, with this written in the manual.

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

**Every plan through the graph (2026-11-16): shown equal, switched on, and the older paths removed; in that order, as it happened.** First, with it still off: `PlanCompiler.graphForAll` (and `allInGraph:` on `compile`; `JAMMER_GRAPH_FOR_ALL=1` in a debug build's or a test run's environment) sends every plan through the mixer graph, as plans with a key already go. It is off: the older paths (the plain renderer, `renderRouted`, tracks' chains pulling for themselves) are what runs, until the worst block has been measured on a quiet Mac.

- The same samples: `GraphEquivalenceTests` renders 21 kinds of project both ways, whole and after seeks, and the graph in 512-frame blocks against itself: all bit for bit (plain; track gains; clip gain and fades; a muted track; clips moved, cut, crossing, and starting in another order than their tracks; pan; a bus; nested buses with sends before and after the fader; a VCA group; master gain; the master limiter idle and working; Apple's plugins on one track, on every track, on a bus, on tracks and buses with a send; a plugin with latency between tracks without; a soloed track; mono).
- It wasn't so at first. Six kinds differed in the last bit (at most 6e-8, −145 dB) for two reasons, both about the order of arithmetic, both now the old order: the strips were summed in the order the graph happened to find them (now: tracks in their order, then buses in theirs, and a key changes that only as far as it must); and the plain renderer sums the clips of tracks without plugins in the order of their starts, with the track's gain folded into the clip's, before the tracks with plugins (the graph now does exactly that for a plan that uses nothing of the mixer).
- The whole test suite, 425 tests, passes with `JAMMER_GRAPH_FOR_ALL=1`.
- Cost, medians and means on a Mac that was not quiet (load 8): without plugins the same within what could be told apart (64 stereo tracks 0.195 against 0.192 ms a block, mean); with plugins about half (64 tracks × 2 plugins and 8 buses × 2: median 2.67 against 1.33 ms; 64 × 2 without buses: 2.61 against 1.20 ms). The worst block is not measured.
- What changes for an agent when it is switched on: `totalLatencySamples` then includes the tracks' own plugins (they are no longer made up for inside each track), and a track's `compensationSamples` is the wait added to it for that reason. The mix is on the sample either way.
- **The worst block, measured on a quiet Mac, 2026-11-16** (load 3.90 at the start and 2.68 at the end, in a window Anders gave; one run; 936 blocks of 512 frames, Apple's low-pass and limiter; `scratch quiet-measure.sh`, the figures from `MixerBaselineTests/withPlugins`). No block was over its 10.7 ms by either way.

  | Tracks × plugins, buses × plugins | older paths: median / worst | graph: median / worst | first block after a seek, older / graph |
  |---|---|---|---|
  | 8 × 1, 2 × 2 | 0.308 / 0.386 ms | 0.121 / 0.322 ms | 9.2 / 2.5 ms |
  | 16 × 2, 4 × 2 | 0.692 / 0.754 | 0.317 / 0.362 | 20.9 / 7.0 |
  | 32 × 2, 8 × 2 | 1.399 / 3.373 | 0.626 / 0.681 | 41.8 / 13.9 |
  | 64 × 2, 8 × 2 (144 units) | 2.639 / 3.028 | 1.152 / 3.017 | 80.5 / 26.5 |
  | 64 × 0, 8 × 2 | 0.339 / 0.379 | 0.339 / 0.372 | 4.9 / 4.9 |
  | 64 × 2, no buses | 2.599 / 8.273 | 1.004 / 1.077 | 20.6 / 21.6 |

  The graph's worst block is no worse in any row, and its median is the same or about half. The older paths also had single blocks far over their median (8.3 ms against a median of 2.6 with 64 × 2 and no buses; 3.4 against 1.4 with 32 × 2), which the graph did not: a reason for the move beside the cost. The heaviest case takes 3.0 ms of 10.7, 28 % of the block's time, with these light plugins. A third-party plugin can cost many times more; this says what Jämmer's own part costs.
- **Playback in the app, the same window** (the paths as they shipped then): 32 tracks × 2 plugins into 8 buses × 2, twice 20 s with the output silent: no gaps counted either time, and what went to the device measured −8.27 dB, the same as the render.
- So both conditions hold: the same samples, and a worst block that is no worse. The graph is switched on for every plan from this commit on (`PlanCompiler.graphForAll` is true; `JAMMER_GRAPH_FOR_ALL=0` in a debug build's or a test run's environment goes back to the older paths while they exist). With it on: the whole suite green (and green again with `JAMMER_GRAPH_FOR_ALL=0`); playback in the app of the same 32 × 2 into 8 × 2, twice 20 s, on a Mac that was busy this time (load 14): no gaps counted, −8.27 dB out and −8.27 dB rendered, the figure the older paths gave.
- **The real projects on this Mac** (`RealProjectTests`, run when given paths; each read from a copy): seven saved packages from earlier tests, one of them with a history, and Flimmer's export sample built into a project (4 tracks, 6 clips): 11 states, 2 175 000 frames each way, whole and after a seek, all bit for bit. They are thin (mostly one track and one clip, one plugin among them, no buses; two are silent because their audio is refused): the 21 kinds in the suite carry the proof, these show that nothing unexpected sits in saved files. Anders's nine unsaved documents were not read.
- **What stays possible after the removal.** The commit before it is tagged `before-graph-only` (local). The 21 kinds' renders by the older paths are kept as digests in `GraphEquivalenceTests` (the ones with Apple's plugins are held to only on the macOS build they were made on), so the suite goes on saying "the same as what shipped before". And `RealProjectTests` can write a reference (`JAMMER_REAL_WRITE=<file>`, at the tag: digests of the older paths' renders) and hold a later build to it (`JAMMER_REAL_CHECK=<file>`); the reference for the eleven states above is `docs/references/real-projects-before-graph-only.json`. A document that turns up later is tried by checking out the tag, writing its reference there, and checking it on the present build.
- **Removed, in a commit of its own (2026-11-16):** `renderRouted`, the plain loop in `Renderer::render`, and the chains' own pulling (`Chain::process`, its queue and its own run-in). `jm_plan_finalize` always makes a graph and `Renderer::render` always goes through it; the switch (`graphForAll`, `JAMMER_GRAPH_FOR_ALL`, `jm_plan_set_all_in_graph`) is gone with them. After the removal: all 21 digests from the older paths still match, the eleven states of the real projects match the reference written at the tag, and the whole suite is green. To take the step back: revert that one commit.

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

## Automation, step 1 built (2026-11-16): gain lanes on tracks, buses and the master, in debug builds

Built as the sketch below says, with what was decided on it: the lane is added to the fader; lanes follow edits that close or open the whole timeline and nothing else; no drawing yet, and so **off in Release** (`Operations.automation`, on in debug builds only) until lanes are shown and drawn. A project that has lanes is played as saved by any build that can open format 3.

- **Model** (`JammerCore/Automation.swift`): `Project.automation`, lanes keyed by strip and what they move; only `gain` is played, the other names are refused ("isn't built yet"). Format 3 when there is a live lane; a file marked with a format the build doesn't know is refused in words (tested with one marked 4; a build from before today knows up to 2 and refuses 3 by the same check).
- **Engine** (`Curve` in `internal.hpp`, `graph.cpp`): `jm_plan_set_gain_curve`. The level is applied in pieces that lie on the timeline's own grid, at most 64 frames and shorter where the line is steep (never more than half a dB of line in a piece), each computed from its own two ends. Measured (`AutomationTests`): off the dB line by at most 0.003 dB at any speed tried, from 120 dB/s to a 40 dB jump in 2 frames (0.0007 dB at 160 dB/s); the biggest step from one sample to the next in a 160 dB/s fade is 0.003 dB, where one value per 512-frame block would step 1.7 dB. Rendered in blocks of 1, 63, 64, 500, 512 or 4 099 frames, or after a seek: the same samples, bit for bit. (The first version computed a piece from wherever a call began, and a seek gave other last bits; and with pieces of always 64 frames a 14 400 dB/s fade was 3.9 dB off the line. Both found by the tests, both gone.)
- **Where it is read:** at the strip's own place on the timeline: with a plugin of 1, 100, 512 or 777 frames' latency before the fader on a track, on a bus, and before the master's, the automated render is bit for bit the one without the plugin. A send before the fader doesn't follow the lane; one after it does.
- **Without a lane** nothing is different: the 21 digests and the null tests hold. A track with a lane leaves the plain summing loop and goes through its own strip; a lane of 0 dB everywhere gives the same samples.
- **Edits:** `Project.delete` (with ripple) and `insertGap` are the two places where every track moves at once, and where markers and the tempo map already follow; the lanes follow there too (`closing`, `opening`): later points move with the sound, points in what was removed go, and a point is added on each side wherever the level would otherwise have changed. Rendered, a project with a lane and a stretch cut out is the old render with that stretch taken out, to within 2·10⁻⁴ (the line is the same; its pieces fall elsewhere). Lining up or stretching one track (`align_tracks`, `correct_drift`) moves its sound under a lane that stays: the step is done and its result carries `warnings` ("The automation on Guest stays where it is on the timeline (2 points)…"), and the app says the same in the status line. There is no dragging of single clips in the window today.
- **Freezing:** a strip's own lanes are after its frozen file and can be changed while it is frozen; the lanes of what feeds it are in what the freeze was made from, so changing one makes it stale. A lane that is switched off is in neither. Tested both ways.
- **Steps:** `set_automation` (`strip`, `points` as `[[seconds, dB], …]`, `start`/`end`, `enabled`, `param` = gain) and `clear_automation` (`strip` and `param` required; one lane of one strip, nothing clears a project). Checked against the document before anything runs, 400 with the field's name: a point after the end ("points[1] is at 9999 s, after the document's end (25.075646 s)"), a value outside −96…24, a point outside `start`…`end`, a strip that isn't there, an unknown name. `GET …/mixer` has `automation` on every strip; `GET …/automation?strip=&at=` answers the lane's value, the fader with its VCA, and both together. Not the assistant's.
- **In the window:** the mixer sheet has a line under a strip (and under the master) whose level is automated: "Automation: 4 points on the level, −12.0 dB to +0.0 dB, added to the fader". Seen as a picture.
- **Seen in the app (debug copy):** a lane on the music taking it down 12 dB changed the measured loudness from −15.42 to −18.18 LUFS, a −3 dB lane on the master to −21.18; the level at a time read back; a delete that closes the timeline moved the lane's points; three undos brought back −15.42.
- **Hostile files** (`ProjectSafety`, before the mixer is looked at): a lane for a strip that isn't there, of a kind not played, a twin, or without usable points is left out; points out of order, doubled, outside the timeline or not levels are put right; more than 10 000 points are cut to that. Each said in words; tested.
- **Cost** (64 stereo tracks, one core, a 512-frame block of 10.7 ms; best of three passes, on a machine whose load was 6 to 20 at the time, so the worst-block figures are not worth writing down): no lanes 0.22 ms on average; a lane that stands still on every track 0.53 ms; a lane that moves all the time on every track and on the master 0.87 ms. A track with a lane no longer goes through the plain summing loop, which is most of the difference. To be measured again in a quiet window with the worst block.
- **Not built:** sends and VCA lanes (step 3); lanes shown and drawn (4); written from the fader (5); plugin parameters (6).

**Step 2, 2026-11-17: an automated mute and an automated pan** (tracks and buses; the master has a level only). Debug builds, like step 1.
- **Mute** (`param` mute, values 1 muted and 0 heard, each held until the next point). The mute button has no ramp to borrow: it changes the whole plan between two blocks. A point in the middle of a sound needs one, so the compiler writes a mute lane as an amplitude line (`Project.muteCurve`): at every change a straight ramp of 5 ms (`Automation.muteRamp`, 240 frames at 48 kHz) beginning at the point. Measured: the biggest step between two samples is 0.0042 of full level (1/240), where a mute without a ramp steps 1.0; heard up to the point, half-way after 2.5 ms, silent after 5 ms, silent until the next point. A change that comes before the ramp before it has ended starts from where that ramp had got to (tested with points 60 frames apart). It silences sends before the fader too, as the button does. The button and the VCA group still mute whatever the lane says.
- **Pan** (`param` pan, −1 to 1, a straight line between points, stereo documents). It uses the fixed pan's law and takes the slider's place while the lane is there and on; the slider is back when the lane is cleared or switched off. A constant lane gives exactly the fixed pan's samples; a sweep from hard left to hard right is within 0.00008 of full level of the law everywhere, with one side exactly silent at each end, and moves by at most 0.0004 between two samples. The pieces are shorter where the pan moves fast (never more than a fiftieth of the way across in one).
- Both land where they were drawn behind a plugin with latency, and give the same samples in blocks of 1, 63, 512 and 4 099 frames and after a seek, bit for bit, together with a gain lane on the same strip.
- **Steps:** `set_automation` and `clear_automation` take `param` gain, pan or mute; refused before anything runs with the field's name: a pan outside −1…1, a mute that is neither 1 nor 0, pan or mute on the master, pan in a mono document. `GET …/automation?param=` answers each lane's value, and `muted` is true when the button, the group or the lane silences the strip at that time. The mixer sheet's line names each lane ("4 points on the level, …; 2 points on the pan, in the slider's place; 3 points on the mute").
- **Hostile files:** a mute lane's values become 1 or 0 and its shape hold; a pan is brought into range; pan or mute on the master, and pan in a mono project, are left out. Tested.

**Step 3, 2026-11-17: a send's level, and a VCA group's lanes.** Debug builds.
- **A send** (`param` send with `to`, the bus it goes to; dB, added to the send's own level). The engine has a curve per send (`jm_plan_set_send_curve`), read on the timeline of the strip the send is taken from. A lane of 0 dB gives the same samples; a constant −6 on a send at −6 is the send at −12 to within 10⁻⁶; a send before the fader has its lane and doesn't follow the fader's. The lane needs its send (refused otherwise, "make the send first"), is saved with its bus, and is gone when the send is removed. A send's lane into a frozen bus makes the bus stale.
- **A VCA group** (`strip` is the group's id; `gain` and `mute`, nothing else). How the lanes are added: nothing new in the engine. When the plan is compiled a member's level curve is its own lane plus the group's, **a sum in dB at the points of both** (two straight lines in dB add to a straight line between those points, so the sum is exact), and a member is muted when its own mute lane or the group's says so, with one ramp at each change. Tested as asked: a group lane and a member's own lane give the same samples, bit for bit, as writing the summed values on each member by hand; the same for the group's mute. A strip outside the group is untouched. `level(of:at:)` and `GET …/automation` have the group's lane in what they answer for a member; the mixer answer has `automation` on each VCA; the sheet has a line under the group ("… (for every strip in the group)"). A group's lanes are in what a frozen bus downstream was made from. Removing the group takes its lanes with it.
- **Steps:** refused before anything runs, with the field's name: `to` missing with send, a send that isn't there, `to` with another param, pan or send on a VCA group.
- **Hostile files:** a send lane whose send isn't there, and pan or send on a VCA group, are left out.
- **Still not built:** snapping to the tempo grid (the rest of 4); written from the fader (5); plugin parameters (6). And not measured in a quiet window: the cost per block.

## Automation, step 4, first half built (2026-11-17): lanes shown in the timeline, in debug builds

**View › Automation** chooses which kind of lane is drawn over the tracks (Level Lanes, Pan Lanes, Mute Lanes, Hide Lanes), one kind at a time for every track that has one.

- **What is drawn is what the engine is given.** `Project.shownLane(_:of:)` (`JammerCore/AutomationDisplay.swift`) returns the curve from the same calls the plan compiler makes (`gainCurve`, `panCurve`, `muteCurve`, `sendCurve`), not a second reading of the points. So a member of a VCA group has the group's lane in its line (and a member with no lane of its own shows the group's, and says whose it is), and an automated mute shows its 5 ms ramps. A test renders the project and holds the sound to the shown line plus the fader within 0.003 dB at every sample, and the mute and the pan to theirs.
- **What comes on top is said, not drawn in.** The fader (with the group's fader) is in the lane's caption: "Level lane with the lane of Voices in it, added to the fader (−3.0 dB)". A pan lane says it stands in the slider's place and that left is up.
- **A lane that is switched off** is drawn dashed and grey from its own points, and says "switched off, not heard": nothing of it is claimed to play.
- **The scale** for a level is not straight in dB (`Automation.height(of:_:)` and its inverse): 0 dB at 0.7 of the row's height, −24 dB at 0.3, the rest down to −96 dB in what is left. The line is therefore read from the curve every second point across the window, not drawn straight between corners. A thin line marks 0 dB (or the centre).
- **A mute** is a red wash over the stretch that is muted, as deep as the mute is at each place, with the line on top.
- **Corners** are dots where they can be told apart (8 points or more between them); a dense lane is a line only.
- **VoiceOver:** the timeline has a group "Automation" with one element a lane ("Level automation of Music", with the caption, how many points it has and how many are in view) and under it the points in view, at most 200, each "Point 3 of 5" with its time and value ("0:05.000, −3.0 dB"; "Muted"/"Heard"; "40 % left"). Measured with a lane of 10 000 points and two others: the whole window's tree, 252 lines, read in 0.13 s. With every point in the tree it would be 10 000 elements; the limit is why it isn't.
- **The mixer sheet:** a strip whose pan a lane steers has its pan slider grey, "Automated" beside it, and a help text that says why and what to do.
- **Texts** are in the string catalogue from the start (the view's file is on the list of fully moved files).
- **The caption** sits on a plate on the line of the track's name, after it; the name has a plate too, so both are read whatever the waveform does under them.
- **Not in this half:** buses, VCA groups and the master have no row in the timeline, so their lanes are still only the mixer sheet's line; send lanes are not drawn. Seen as pictures: level (own lane with a group's, a plain one through the scale's knee, one switched off), mute, pan, a 10 000-point lane far out and far in, the mixer with the grey slider.

### The second half, first part built (2026-11-17): a track's lane drawn by hand, in debug builds

Built from the sketch as the coordinator changed it. Every change is one `set_automation` (the whole lane) or `clear_automation` step: one undo step, with the step's own checks.

- **Focus.** One lane has it: the shown kind on the track last clicked or stepped to (a bar at the row's left edge, a thicker line, larger points). A track with no lane of that kind shows a faint line where a first point would go and says how to add one.
- **The points are the lane's own.** On a member of a VCA group the heard line (own plus group) stays drawn thick, and the own lane is drawn thin beside it with the points on it: what is dragged is what is stored, what is heard is still shown.
- **Adding.** ⌥-click in the row: a point at the pointer's time. Within 6 points of the line it takes the line's value (nothing heard changes); elsewhere it takes the pointer's height. ⌥Return: a point at the playhead at the line's value. A mute's new point is the other state from there on. **Without ⌥ nothing in the timeline has changed**: a click places the playhead, a drag selects, and a double click selects the clip under the pointer as before (the sketch's double click for a point is gone: it would have taken that over).
- **Dragging** a point moves time and value; one undo step for the whole drag, sent when the button is let go. ⇧ holds the time, ⌘ holds the value. A mute's point moves sideways only, and a click on it flips it.
- **Neighbours.** A point stops one frame short of the point on either side (`AutomationLane.placed`); nothing passes and nothing is swallowed.
- **Snapping** while dragging: to the playhead, markers, the track's clip edges and the selection's ends within 6 points; to 0 dB (or the centre) within 4 points; ⌃ turns both off.
- **The value at the pointer:** a label with the time and the lane's value while the pointer is on the focused line and while a point is dragged; for a level also what is heard with the group's lane and the fader. The status line says the same for the point just selected, added or moved ("Point 2 of 5: 0:09.558, −8.9 dB"), and VoiceOver is told it.
- **The last point.** Delete on a lane's last point removes the lane without asking; the status line says "Level lane removed from Music"; one undo brings it back.

| Keys (the timeline has the focus, lanes are shown) | |
|---|---|
| ⌥↓, ⌥↑ | The lane of the next or the previous track |
| ⌥→, ⌥← | Select the next or the previous point; the playhead goes there |
| ⌥Return | A point at the playhead, at the line's value there |
| ↑, ↓ (a point selected) | 0.5 dB up or down; a pan 5 % (↑ is left); a mute flips |
| ⇧↑, ⇧↓ | 0.1 dB; a pan 1 % |
| ⌥⇧↑, ⌥⇧↓ | 3 dB; a pan 25 % |
| ⌥⇧→, ⌥⇧← | The point 10 ms later or earlier |
| ⌘⌥→, ⌘⌥← | The point one frame later or earlier |
| ⇧→, ⇧← | Select the next point after the selected ones too, or the one before them |
| ⌥Tab (send lanes) | The strip's next send |
| Delete | Remove the selected points (the one before them is selected next) |
| Escape | Nothing selected; the keys are the timeline's again |

None of them uses ⌃ with ⌥ (VoiceOver's own keys). ↑, ↓, Delete and Escape are only taken while a point is selected; ⌥ with an arrow or Return had no meaning in the timeline before, and no menu item of Jämmer's uses ⌘⌥ with an arrow. The table goes into the manual the day automation is in a Release build (the manual only describes what a user has).

**Tried by script** (`safepointer` drag, click with ⌥, doubleclick; keys through System Events; 34 checks, all as expected): points are found by accessibility id, the row's scale is worked out from two points whose values are known, and each result is read back from `GET …/mixer` and compared with what the drag should give by the scale's inverse. A drag (time within 1.5 points, value within a point's worth); one undo for the whole drag; a drag past a neighbour (lands one frame after it); ⇧ and ⌘ drags; ⌥-click on the line (the line's own value to 0.001 dB) and off it; a drop 4 points from a marker (lands on it); a double click (no point; the clip is selected); a group member (own point moves, the group's lane untouched); the keys alone from no lane to three points, every step size, and back to none with the status line's sentence and one undo; a mute point flipped and dragged sideways. Seen as pictures: a dragged point, added points, a group member with both lines, the keys' selected point, a mute lane.

**Rows for buses, VCA groups and the master (built the same day).** View › Automation › Buses, Groups and Master opens thin rows under the tracks (44 points each, at most half the timeline; they take height from the tracks only while open), one for every strip that can have a lane of the shown kind: buses always, groups for level and mute, the master for level. The same view as over the tracks (`AutomationLanesView` with `rows: .strips`), so adding, dragging, the keys and VoiceOver are the same; a click elsewhere in a row places the playhead. ⌥↓ from the last track goes into the first row and ⌥↑ back. A group's row shows its own lane as written (it is heard in its members' lines, where it is said), and its label doesn't claim a "heard" level. Tried: a group's point dragged in its row, ⌥-click in the master's row (a lane on the master), ⌥↓ from the last track and ⌥Return in a bus's row (a lane on the bus), ⌥↑ back; seen as a picture.

**The label** is also shown at the selected point, so a point stepped to with the keys says its time and value where it is (and that is how the label was seen as a picture). **The status line** gives what was just done its whole width; the selection's text gives way first.

**Several points at once (built the same day).** ⇧-click adds a point to the selected ones or takes it out; a ⌥⇧-drag across the row selects the points in that stretch; ⇧→ and ⇧← take in one more with the keys. A drag of one of them, the arrow keys and Delete then work on all of them, as one piece (`AutomationLane.moving(_:byFrames:byValue:limit:)`): the piece stops when any of its points is a frame short of a neighbour that isn't moving, at an end of the timeline, or when one of its values reaches the edge of what the lane may have, so the distances and the shape are kept. A click on one of several, without moving, selects that one alone. The status line says how many ("3 points selected", "2 points moved"). Tried by script, 13 checks: two points dragged together (same time, same value, the others untouched, one undo), the piece dragged far (stops a frame before the next point, keeps its length), a ⌥⇧-drag selecting three, ↓ on the three, ⇧→ twice and a 10 ms step, Delete on three and one undo; seen as a picture.

**Send lanes (built the same day).** View › Automation › Send Lanes shows, on every track (and in the rows below, every bus) that has a send, the lane of one of its sends: the first, or the one chosen with ⌥Tab, which goes to the strip's next send. The caption says which bus the send goes to, the send's own level that the lane is added to, and "send 1 of 2, ⌥Tab for the next" when there is more than one. A strip without a send says so and takes no point. Everything else is as for a level. Tried by script (8 checks): ⌥Return on the shown send, ⌥Tab and ⌥Return on the other (the first untouched), ↓, Delete to an empty lane with its sentence, a drag, a track without a send (nothing is made), a bus's send in its row; seen as pictures.

**Not built, and not tried:** snapping to the tempo grid. Not seen: the label under the point in a thin row (moved there after the last picture, where it covered the row's caption). **Not tried:** VoiceOver itself reading the announcements (the tree and the announcement call were checked, not the speech; on Anders's list for his own half-minute try). ⌃ against snapping was tried with safepointer's new `--ctrl` (dropped 4 points from a marker, it stays where the pointer was).

**Release.** Automation stays out of Release until both halves have been seen as pictures by the coordinator and in the app by Anders.

## Automation, step 5, sketched (2026-11-17, nothing built): a lane written from the fader while the sound plays

What it is for: riding a level by ear. The user plays, moves a strip's fader, and what the hand did is a lane afterwards.

**What stands in the way today, and has to be decided first.**
1. *The mixer is a sheet.* It lies over the window it belongs to; the timeline can't be reached while it is open, and a fader in it is sent when it is let go, as one step. Nothing is heard while it is dragged. Writing from a fader needs a mixer that can stay open beside the timeline while the sound plays. Proposed: the mixer becomes a window of its own (a panel that belongs to its document and can stay open beside it; Jämmer has none like it today, the Plugins sheet is a sheet too), with the same content; Audio › Mixer… opens it. The sheet goes. *This is a change of interface on its own and is asked about below.*
2. *A fader isn't heard while it moves.* A new plan is made when the value is sent. Proposed, in the engine: a live trim per strip, `jm_engine_set_live_gain(engine, kind, index, db, active)`, an atomic the audio thread reads once a block and ramps to over the block (no allocation, no lock: the rule on the audio thread holds, and the guard is proved by a planted violation as before). While a strip's trim is active, it stands in the lane's place for that strip; when it is let go the lane is back. With the trim at the lane's own value the sound is the same samples as without it (a null test).

**Modes, one per strip, in the mixer window:** Read (as today), Touch, Latch. No mode that writes without a hand on the control.
- **Touch:** writing begins when the fader is taken hold of during playback and ends when it is let go; from there the level glides back to what the lane had, over 250 ms, so there is no jump.
- **Latch:** writing begins the same way and goes on at the last value after the fader is let go, until playback stops.
- Not playing, a fader does what it does today in every mode (it sets the fader, which the lane is added to).
- A mode is not saved in the document: a project never opens armed. Every strip is in Read when a document opens, and goes back to Read when the mixer window closes.
- A strip in Touch or Latch says so wherever it is seen: its mode menu in the mixer, a mark on its row's caption in the timeline ("Touch"), and for VoiceOver in the strip's value.

**What is written.** The lane is what is added to the fader, so the fader's rest position stays where it is and the hand's movement away from it is the lane: lane value = where the control is held − the fader. While playing with a lane, the control shows the fader plus the lane (it moves by itself, as a motor fader does); taking hold of it starts from where it is.
- **In time:** each movement is placed at the frame that was being *heard* when the hand moved (the engine's position less the output's latency), not the frame being computed.
- **Only the stretch that was ridden changes:** from the frame the control was taken to the frame writing ended (let go plus the glide, or the stop). The lane outside it is not touched, and a point at each end holds it to what it was there (`set_automation` with `start` and `end`, which already leaves the outside alone).
- **Thinned:** movements are taken every 10 ms and then thinned so that the written line is nowhere more than 0.1 dB from what the hand did (a line-simplification in dB); a slow ride over a minute is tens of points, not thousands. If a pass would still pass the lane's limit of 10 000 points, it is thinned further and the status line says so.
- **One pass is one undo step**, made when writing ends, through `set_automation` like every other change to a lane. The status line says what was written ("Wrote 14 points on Music, 0:12.4 to 0:31.0"), and VoiceOver is told.
- **What can be ridden in this step:** the level of a track, a bus, a VCA group and the master. Proposed for the same step if it is cheap once the level works: the pan slider (a pan lane), the Mute box (a mute point where it is clicked during playback) and a send's level. Otherwise each is its own later part.

**With the keys alone.** In the mixer window, with a strip's level in focus and the strip in Touch or Latch: holding ↑ or ↓ while the sound plays rides the level (0.5 dB a repeat, ⇧ 0.1 dB); letting go of the key is letting go of the fader.

**An agent.** Nothing new in the API: an agent writes a lane with `set_automation`, which says exactly what it wants. The modes are interface state and are not offered to an agent (an agent may start playback only in a visible window and never start a recording; a write mode is of that kind).

**Tests.**
- The pass as a pure function in the core (`Automation.written(pass:into:from:to:glide:tolerance:)`): the lane outside the stretch is the same points; inside, the written line is within the tolerance of the hand's at every frame; Touch ends in a glide back to the old lane, Latch holds to the stop; a pass of nothing changes nothing; the point limit.
- The engine's live trim: bit for bit the lane's own sound when it stands at the lane's value; a constant trim is the same as that fader; switched on and off in the middle of a block without a click (the ramp).
- In the app, by script: play, drag a fader with `safepointer drag` (0.4 s), stop; read the lane back: points only inside the stretch that was ridden, the value at its end the one the drag ended on, one undo takes the pass away. Touch and Latch each; the keys alone; a strip left in Read is not written. Pictures of the mixer window with a strip in Touch and of the lane afterwards.

**Release:** with the rest of automation, when it has been seen.

**Questions to the coordinator before anything is built:**
1. The mixer as a window of its own instead of a sheet: yes? (Without it there is nowhere to ride a fader from while listening.)
2. Modes not saved in the document, and back to Read when the mixer window closes: yes?
3. The glide (250 ms) and the thinning (0.1 dB): as fixed values, or as settings?
4. Pan, mute and sends in this step when they come cheap, or level only?

## Automation (the sketch of 2026-11-16 that the above was built from)

What it is: a level, a pan or a mute that changes over the timeline, on a track, a bus, a VCA group or the master, and the level of a send. Plugin parameters are a later step of their own (they need a way to name a parameter that holds across AU, VST 3 and CLAP and across the helper process).

**Model.** `Automation` on a strip: lanes keyed by what they move (`gain`, `pan`, `mute`, `send:<bus id>`), each a list of points `(frame, value)` in timeline frames, sorted, at most one per frame. Between points the value goes in a straight line (in dB for levels, so a fade sounds even), or holds until the next point (`hold`, the only shape for mute). Before the first point and after the last, the value is that point's. A lane **adds to the fader** (the fader is the trim): 0 dB everywhere is nothing, and a strip without lanes is exactly as today. Pan lanes replace the pan while they exist. A VCA's gain lane adds to its members', worked out when the plan is compiled like the VCA's level is now (two straight-line curves in dB add to a straight-line curve over the union of their points), so nothing new in the engine for VCAs.

**When the timeline is edited.** A lane belongs to its strip and is in timeline time, like the faders of a console, not to a clip. So that an edit doesn't leave every later point in the wrong place: an edit that moves later material on a track (a rippling delete, removed pauses and filler words, inserted silence, an inserting paste) moves that track's points after the edit by the same amount, and takes away the points inside what was removed; the value just before and just after the removed stretch is kept by a point on each side, so the level doesn't jump to somewhere it never was. A bus's, a VCA's and the master's lanes move only when every track that reaches them moved by the same amount there (a delete across the whole document); otherwise they stay and the mixer sheet says that tracks under an automated bus were edited. Moving or trimming one clip leaves the lane alone in the first version; "automation follows the clip" is a later option, off by default. All of it is one value change on `Project` with the edit, so undo takes both back.

**Modes.** First version: a lane is read, or switched off (`enabled: false`, kept but not heard). Writing from the faders comes in step 5, and then as touch (writes while the fader is held, goes back to the lane on release) and latch (keeps the last value until stop); no "write" mode that overwrites everything it plays past.

**Engine.** A strip's gain is today one number per plan. With a lane it becomes a list of breakpoints handed to the plan (`jm_plan_set_strip_gain_curve(plan, strip, frames, gains, count)`, same for pan); the graph applies it in pieces of at most 64 frames, ramping linearly in amplitude between values taken from the dB line, at the strip's own time (the cursor minus how late the strip is, so automation lands where it was drawn whatever plugins are before it). A point lands on its own frame (the pieces are cut at the points), so it is sample-accurate in time; in level it is the dB line to within what a 64-frame straight piece differs from it, which for a fade of 1000 dB/s is about 0.03 dB and for anything slower much less (to be measured and written here, not assumed). The alternative, one value per 512-frame block, would be cheaper and is what is heard as zipper noise: a staircase 94 times a second, audible on a steady tone under any fade. No allocation or lock on the audio thread: the curve is part of the immutable plan. Without a curve the code path is the one that exists, bit for bit; the null tests and the 21 digests hold that.

**Projects.** A project with a lane is format 3 and says so to an older Jämmer; without lanes it is saved as before. `ProjectSafety`: at most 10 000 points in a lane and 64 lanes on a strip, values in the parameter's range and finite, points sorted and inside ±24 h, a send lane only for a send that exists; each refused or repaired in words, with a generator per case.

**Steps** (the one schema; each one undo step; unknown names refused):

| Step | Does |
|---|---|
| `set_automation` | `strip` (track, bus or VCA id, or "master"), `param` (`gain`, `pan`, `mute`, or `send` with `to`), `points` (`[[seconds, value], …]`). Replaces the lane; with `start` and `end`, only the points inside that range. `shape`: `linear` (default) or `hold`. |
| `clear_automation` | `strip`, `param` (left out: every lane of the strip), optionally `start`, `end`. |

`GET …/mixer` gains `automation` on every strip: `[{param, to?, shape, points}]`. `GET …/documents/{id}/automation?strip=&param=&at=` answers the value at a time and the strip's whole level there (fader, VCA and lane together), so that an agent can check what it wrote without rendering.

**Interface, in later steps:** lanes under a track in the timeline with points to drag; then writing a lane from fader moves during playback (touch and latch). The first step has no drawing: lanes come from the steps, and the mixer sheet says that a strip has automation.

**The assistant:** not given these at first (`stepsNotForAssistant`); "fade the music down between 10 and 20 s" is a later evaluation set of its own.

**Freezing and bouncing.** A frozen strip's file is what comes out of its plugins, before its fader, so its own gain, pan and mute lanes stay live and can be changed while it is frozen. What goes into it is another matter: the digest a freeze is made from covers the lanes of everything that feeds the strip (tracks into a frozen bus, sends to it, the source of a key), so changing one of those makes the frozen file stale as changing a clip does. Export, bounce, stems and batch render the same plan as playback, so they have the automation without anything of their own; the master's limiter loop measures the written file as before.

**What an agent gets.** It writes points (with `rationale`, like every step), reads lanes and asks for the value at a time. It never records a movement: touch and latch exist only in the interface, and no step starts playback to write a lane.

**Plugin parameters: later, not in the first version.** They need a name for a parameter that holds across AU, VST 3 and CLAP and across the helper process, values in the plugin's own units, and a way to hand changes to the plugin inside a block; each is its own piece of work and none is needed for level, pan, mute and sends.

**What it leaves alone:** clip gain and fades; `duck` (which bounces a file today; it could write a lane instead, as a later change with its own comparison).

**Order:** 1 gain lanes on tracks, buses and the master, engine and steps, null tests. 2 pan and mute. 3 sends and VCAs. 4 lanes shown and drawn. 5 written from the fader. 6 plugin parameters.

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
