# Mixer

![The Mixer sheet: two tracks and a bus, each with a mute box, a level slider, a pan slider and where it goes](../screens/mixer.webp)

**Audio › Mixer…** (⌥⌘X) shows every track as a strip: mute, level, pan, and where it goes. Use it to set the balance between tracks, to place a track to the left or the right, and to gather tracks on a bus.

## Level, pan and mute

- **Level** is the track's gain, from −60 to +12 dB on the slider. Let go of the slider and the change is made; one drag is one undo step.
- **Pan** places a track between left and right in a stereo document. In the centre the track is left exactly as it is. Towards one side, that side stays as it is and the other falls away, so panning never makes anything louder and can't clip. A mono document has no pan.
- **Mute** silences the strip. A muted track is left out of exports too.

## Buses

A bus gathers several tracks under one level, one pan and one mute: all the music under one fader, all the guests under another.

1. Type a name at the bottom of the sheet and click **Add Bus**.
2. On each track that should go through it, choose the bus under the track's output (where it says **Output**).
3. Set the bus's own level, pan and mute on its strip.

A bus can itself go to another bus. Jämmer won't let buses be sent round in a circle; the buses that would close a circle aren't offered. The minus button takes a bus away; what went to it then goes where the bus went.

A document can have up to 64 buses.

## What stays the same

- A document without buses, with every pan in the centre, plays and exports exactly as it did before there was a mixer, sample for sample.
- Repairs, echo, ducking and the limiter work on a track's own sound; its pan and its bus apply afterwards, as they do to everything the track plays.
- The limiter (**Audio › Limit Peaks…**) listens to the mix as the buses make it.

## Projects and older versions

A project that uses the mixer (a bus, a pan, a track sent to a bus) is saved in a newer project format. A Jämmer from before the mixer says that the project needs a newer Jämmer, instead of opening it and playing every track straight out. A project that doesn't use the mixer is saved as it always was and opens anywhere.

## Agents

An agent sees the mixer with `GET /api/v1/documents/{id}/mixer` and changes it with the steps `add_bus`, `set_bus`, `remove_bus` and `set_track` (`pan`, `output`); see [the guide](../agents.md#operations). The assistant can add a bus by name; for the rest, use the sheet.

Not there yet: sends, plugins on a bus, a master strip, solo, and delay compensation across buses. They come in that order.
