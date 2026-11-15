# Plugins

![The Plugins sheet with three Audio Units on a track, each with a switch, Edit and a bin, and the safe mode option](../screens/plugins.webp)

A track can run through Audio Unit effects (AUv2 and AUv3) after its clips and before its gain: an EQ, a compressor, a de-esser, a limiter.

## Add one

**Audio › Plugins…** (⌥⇧⌘P). Pick the track, then **Add Plugin** and the effect, grouped by manufacturer. Each plugin in the list has:

- a switch to turn it **on or off** (off is bypass: the track sounds exactly as without it),
- **Edit…**, which opens the plugin's own window (or sliders for its parameters when it has no window),
- the bin, to take it off.

Plugins run in the order listed. Each one is one undo step, and so is a change made in a plugin's window: Jämmer stores the plugin's settings in the document shortly after you stop turning a knob, and when you close the window.

## What they affect

- **Playback.** Jämmer renders a third of a second ahead, so a change in a plugin's window is heard a moment later.
- **Exports and loudness.** Exports, **Measure Loudness**, **Normalize** and the loudness presets all hear the plugins, so "compress, then normalise to −16 LUFS" works as you'd expect.
- **Timing.** Each plugin's latency (for example a limiter's look-ahead) is compensated, so a track with plugins stays in time with the others.
- **Not** the repairs, echo, spectral attenuation or drift correction: these work on the recorded audio before the plugins, and the plugins then process their result.

The original files are never touched; taking a plugin off brings the track back exactly.

## Plugins are someone else's code

A plugin runs with Jämmer's rights, and a badly behaved one can crash the app. If that happens, turn on **Safe mode** at the bottom of **Audio › Plugins…**: every plugin then runs in a separate process, and a plugin that fails stops processing (the track plays without it) instead of taking Jämmer down. Plugins from developers other than Apple always run that way, for safety: Jämmer doesn't let other developers' code load into the app itself.

A plugin that isn't installed on this Mac (a document from another computer) is listed with a warning and passes the audio through unchanged; its settings stay in the document for when it's back.

## For agents

The agent API can list the installed plugins, add and remove them, set parameters and bypass, and read a plugin's parameters with their ranges. It can't open plugin windows. See [the guide](../agents.md#plugins).
