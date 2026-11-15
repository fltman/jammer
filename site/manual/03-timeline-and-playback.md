# Timeline and playback

## The window

- **Transport bar** (top): play/stop, the playhead time, the total length, zoom buttons and the playback volume.
- **Timeline**: a ruler with times, and one lane per track. Stereo tracks show left above right. Clip edges are thin vertical lines; fades are drawn as a slanted line.
- **Status bar** (bottom): the selection's start, end and length, messages from the last command, missing files, and the sample rate and channel layout.

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

Jämmer plays through the Mac's current output device and follows it when you switch in Control Centre or System Settings.
