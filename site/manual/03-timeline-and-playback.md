# Timeline and playback

## The window

- **Transport bar** (top): play/stop, the playhead time, the total length, the playhead in bars, beats and ticks, zoom buttons and the playback volume.
- **Timeline**: a ruler with times, and one lane per track. Stereo tracks show left above right. Clip edges are thin vertical lines; fades are drawn as a slanted line.
- **Status bar** (bottom): the selection's start, end and length, messages from the last command, missing files, the tempo and time signature at the playhead, and the sample rate and channel layout.

## Tempo and time signature

Every project has a tempo map. It starts at 120 BPM in 4/4, and for speech you can ignore it. For music, choose **Audio › Set Tempo…** (or click the tempo in the status bar). Enter the tempo in quarter notes per minute and the time signature. Tick **From the playhead** to make it a change at the playhead instead of the tempo for the whole project.

- The tempo stays the same until the next change. Gradual tempo changes aren't supported yet.
- A new time signature starts a new bar. If the bar before it isn't finished, it still counts as a bar.
- Tempo changes are tied to the audio: when you delete or insert, they move with what follows. If you delete a range that contains a change, the tempo that was playing at the end of the range carries on from the cut.
- Bar.beat.tick in the transport bar counts bars and beats from 1. A beat has 960 ticks.
- Undo covers tempo changes like any other edit.

## Moving around

| Do this | To |
|---|---|
| Scroll (or swipe sideways on a trackpad) | Move along the timeline |
| ⌘ or ⌥ + scroll, or pinch | Zoom around the pointer |
| ⌘+ / ⌘− | Zoom in / out |
| ⌘0 | Zoom to fit the whole project |
| ⌘E | Zoom to the selection |
| ⌃⌘F | Full screen |

You can zoom in until single samples are wider than a pixel. Long recordings show "Reading waveform…" the first time while Jämmer builds the overview; it's cached afterwards.

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

Jämmer plays through the Mac's current output device and follows it when you switch in Control Centre or System Settings. If the device runs at another sample rate than the project, Jämmer converts while it plays and leaves the device's setting alone. Exports are always at the project's rate and aren't affected.
