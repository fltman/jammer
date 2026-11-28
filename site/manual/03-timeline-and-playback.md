# Timeline and playback

## The window

- **Transport bar** (top): play/stop, the playhead time, the total length, the playhead in bars, beats and ticks, zoom buttons and the playback volume.
- **Tool palette** (left of the timeline): the tools that decide what the mouse does there, with the current one lit. Hover a tool for its name and letter. **View › Show Tool Palette** shows or hides it; see [Editing](04-editing.md#handles-and-tools).
- **Track headers** (left of the lanes): each track's name, **M** (mute), **S** (solo, only for listening), **R** (arm to record, see [Recording](25-recording.md)), the lock, its level in dB and a peak meter, and, when the lane is tall enough, a level and a pan slider. A slider is one undo step when you let go; double-click it or ⌥-click it to put it back to its default, ⌥-drag it to move it a tenth as far, and click the value beside it to type one (Return sets it, Esc leaves it as it was). On a track too low for all of this, the header is one row: the name and M, S and R; the rest is in the mixer. The meter shows the track's peak after its fader as the sound plays, holds it a moment and falls back; its light turns red when the track reaches full scale (0 dBFS) and stays red until you click it. Double-click a header to rename the track. The **Track** menu acts on the track you last clicked: Rename, Mute, Solo, **Lock Track**, **Duplicate Track** (a copy right under it, with its plugins and automation), **Move Track Up** and **Down**, and **Delete Track** (one undo step; a document keeps at least one track). A **locked** track keeps its clips where they are: an edit that would change them (or delete the track) is refused and says which track is locked; its level, pan and mute stay free.
- **Timeline**: a ruler with times, and one lane per track. Stereo tracks show left above right. Clip edges are thin vertical lines; fades are drawn as a slanted line. A lane shows how its track is heard: a muted track is dimmed and says "Muted", one that is silent because another track is soloed says "Not heard: another is soloed", a soloed track has a yellow bar at its left edge, and a frozen one says "Frozen".
- **Context menus**: right-click (or Control-click) the timeline, a clip, a marker's flag, a track header, a mixer strip, a spectral area or a word in the transcript for the commands that apply there, with the same names and checks as the menu bar. With VoiceOver, each clip is an element of its own, named with its times and track: VO-Space selects it, VO-Shift-M opens its menu. A command that can't run says why, there and in the menu bar, as its help tag.
- **Panels**: the transcript, the assistant and the tool palette are remembered per document: a saved document opens with the panels it had; a new one with those you chose last.
- **Focus mode** (**View › Focus Mode**, ⌃⇧⌘F) hides the transcript, the assistant and the tool palette and keeps the timeline; choose it again to bring them back. The window's green button, or ⌃⌘F, gives it the whole screen.
- **Status bar** (bottom): the selection's start, end and length, each running job, export or command that takes more than half a second, with its progress and a stop button (**Edit › Stop Job** stops the newest; what is stopped changes nothing, and a stopped export writes no file), a red **0 dBFS at …** when the mix reaches full scale somewhere on the timeline (worked out in the background a moment after each change, without playing; click it to go there), messages from the last command, missing files, the tempo and time signature at the playhead, and the sample rate and channel layout.

## Tempo and time signature

Every project has a tempo map. It starts at 120 BPM in 4/4, and for speech you can ignore it. For music, choose **Transport › Set Tempo…** (or click the tempo in the status bar). Enter the tempo in quarter notes per minute and the time signature. Tick **From the playhead** to make it a change at the playhead instead of the tempo for the whole project.

**Transport › Detect Tempo** finds the tempo of music for you and sets the ruler's beats on the music's beats. It works on the selection, or on the whole document, and Undo brings the old tempo back.

- Music with one steady beat gets one tempo.
- Music whose tempo changes in steps (a song that goes from 120 to 90 BPM and on to 140) gets a tempo map: a tempo for each stretch, each change on a beat, with a whole number of beats between changes so the bars stay whole. The status line lists them ("Tempo map: 3 tempi, 120 (0:00), 90 (0:16), 140 (0:32) BPM from where each begins."). It reads up to ten minutes of the sound for this. A tempo map that was there is replaced, in one undo step. A stretch shorter than about 8 seconds isn't found.
- A tempo that glides (a ritardando) is refused, saying from about what to what and between when, so that you can set it by hand. For speech, noise or silence it says "no steady tempo was found" and changes nothing.
- A fast tempo can come back at half speed (174 as 87), and a slow one doubled. If the number looks wrong by a factor of two, set it with **Set Tempo…**; an agent can ask for the other one directly.
- It finds beats, not bars: bar numbers count from the first beat, which need not be where the music's bars begin.
- Tried on click and drum tracks at known tempi (found within 0.1 BPM, the first beat within 20 ms), one synthesised song, and made-up tempo changes in steps; not yet on recordings of played music, where it may decline. A played change that eases in over a bar or two may be taken for a glide and refused.

- The tempo stays the same until the next change. Gradual tempo changes aren't supported yet.
- A new time signature starts a new bar. If the bar before it isn't finished, it still counts as a bar.
- Tempo changes are tied to the audio: when you delete or insert, they move with what follows. If you delete a range that contains a change, the tempo that was playing at the end of the range carries on from the cut.
- Bar.beat.tick in the transport bar counts bars and beats from 1. A beat has 960 ticks.
- Undo covers tempo changes like any other edit.

## Moving around

| Do this | To |
|---|---|
| Swipe sideways on a trackpad, or ⇧ + scroll | Move along the timeline |
| Drag the scroller along the bottom of the timeline | Move along the timeline (click beside its knob for a page) |
| Scroll up or down, or swipe up or down | Scroll the tracks, when they don't all fit |
| ⌘ + scroll, or pinch | Zoom around the pointer |
| ⌥ + scroll | Make the tracks taller or shorter |
| ⌘+ / ⌘− | Zoom in / out |
| ⌘0 | Zoom to fit the whole project |
| ⌥⌘E | Zoom to the selection |
| ⌃⌘+ / ⌃⌘− | Taller / shorter tracks (**View › Taller Tracks, Shorter Tracks**) |
| ⌃⌘0 | Fit the tracks to the window (**View › Fit Tracks**) |
| ⌥↑ / ⌥↓ | Select the track above / below, scrolled into view (**Track › Previous Track, Next Track**; with automation shown, these keys move between lanes) |
| ⌃⌘F | Full screen |

You can zoom in until single samples are wider than a pixel.

A lane is at least 48 points high (times the track height). When the tracks don't fit, they scroll, their headers with them, while the ruler and the rows for buses, groups and the master stay where they are. A track you select, give the keyboard to or add is scrolled into view. While the tracks are scrolled, a row at the bottom says how many tracks out of view the selection reaches into ("▼ 3 tracks below"), since Delete and Cut take them too; click it to go to the nearest. The track height and the scroll are kept with the document, and are never an undo step.

The first time a recording is shown, each track says what its waveform is doing: "Waiting to read waveform…" while its files wait their turn (two are read at a time), then "Reading waveform… 42 %". The window answers all the while, and the overview is cached afterwards.

## Selecting

| Do this | To |
|---|---|
| Drag in a lane | Select a range (the view scrolls if you drag to the edge) |
| Shift-click | Extend the selection to the click |
| Double-click a clip | Select the whole clip |
| Click without dragging | Clear the selection and move the playhead there |
| ⌘A | Select everything |
| Esc | Clear the selection |

Edits act on all tracks at once, like a waveform editor.

## Playing

| Key | Action |
|---|---|
| Space (or ⌥⌘P) | Play / stop |
| Return | Playhead to the start |
| ← / → | Playhead back / forward one second |
| Home / End | Playhead to the start / end |
| Click the ruler, or drag in it | Move the playhead (also while playing) |

Playback starts at the selection if there is one, otherwise at the playhead, and stops at the end. If you edit while playing, you hear the change straight away. The volume slider in the transport bar only affects playback in Jämmer, not exports.

While it plays, the timeline follows the playhead a page at a time, at most twice a second (once a second with Reduce Motion), so the picture never flickers. Zoomed in so far that following would need more pages than that, the view stays where it is and says **Following paused at this zoom**; zoom out, or stop, and it follows again.

Jämmer plays through the Mac's current output device and follows it when you switch in Control Center or System Settings. If the device runs at another sample rate than the project, Jämmer converts while it plays and leaves the device's setting alone. Exports are always at the project's rate and aren't affected.

## Spectrogram

**View › Show Spectrogram** (⌥⌘S) shows each track as a spectrogram instead of a waveform: time across, frequency up (50 Hz to 16 kHz on a log scale), brightness for level. It's computed for what's on screen, so zoom in to ten minutes or less. Selecting works as in the waveform. **Repair › Attenuate Frequencies…** lowers a frequency band (for example a whistle or a hiss) inside the selection by the number of decibels you give; it renders into a new file like the other repairs, so one undo brings back the original.
