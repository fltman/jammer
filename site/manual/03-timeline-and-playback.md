# Timeline and playback

## The window

- **Transport bar** (top): play/stop, the playhead time, the total length, the playhead in bars, beats and ticks, zoom buttons and the playback volume.
- **Tool palette** (left of the timeline): the tools that decide what the mouse does there, with the current one lit. Hover a tool for its name and letter. **View › Show Tool Palette** shows or hides it; see [Editing](04-editing.md#handles-and-tools).
- **Timeline**: a ruler with times, and one lane per track. Stereo tracks show left above right. Clip edges are thin vertical lines; fades are drawn as a slanted line.
- **Context menus**: right-click (or Control-click) the timeline, a spectral area or a word in the transcript for the commands that apply there, with the same names and checks as the menu bar. A command that can't run says why, there and in the menu bar, as its help tag.
- **Focus mode** (**View › Focus Mode**, ⌃⇧⌘F) hides the transcript, the assistant and the tool palette and keeps the timeline; choose it again to bring them back. The window's green button, or ⌃⌘F, gives it the whole screen.
- **Status bar** (bottom): the selection's start, end and length, each running job, export or command that takes more than half a second, with its progress and a stop button (**Edit › Stop Job** stops the newest; what is stopped changes nothing, and a stopped export writes no file), messages from the last command, missing files, the tempo and time signature at the playhead, and the sample rate and channel layout.

## Tempo and time signature

Every project has a tempo map. It starts at 120 BPM in 4/4, and for speech you can ignore it. For music, choose **Transport › Set Tempo…** (or click the tempo in the status bar). Enter the tempo in quarter notes per minute and the time signature. Tick **From the playhead** to make it a change at the playhead instead of the tempo for the whole project.

**Transport › Detect Tempo** finds the tempo of music for you and sets the ruler's beats on the music's beats. It works on the selection, or on the whole document (it listens to up to two minutes), and Undo brings the old tempo back.

- It answers only for music with one steady beat. For speech, noise or silence, and for music whose tempo changes, it says "no steady tempo was found" and changes nothing.
- A fast tempo can come back at half speed (174 as 87), and a slow one doubled. If the number looks wrong by a factor of two, set it with **Set Tempo…**; an agent can ask for the other one directly.
- It finds beats, not bars: bar numbers count from the first beat, which need not be where the music's bars begin.
- Tried on click and drum tracks at known tempi (found within 0.1 BPM, the first beat within 20 ms) and one synthesised song; not yet on recordings of played music, where it may decline.

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

Jämmer plays through the Mac's current output device and follows it when you switch in Control Center or System Settings. If the device runs at another sample rate than the project, Jämmer converts while it plays and leaves the device's setting alone. Exports are always at the project's rate and aren't affected.

## Spectrogram

**View › Show Spectrogram** (⌥⌘S) shows each track as a spectrogram instead of a waveform: time across, frequency up (50 Hz to 16 kHz on a log scale), brightness for level. It's computed for what's on screen, so zoom in to ten minutes or less. Selecting works as in the waveform. **Repair › Attenuate Frequencies…** lowers a frequency band (for example a whistle or a hiss) inside the selection by the number of decibels you give; it renders into a new file like the other repairs, so one undo brings back the original.
