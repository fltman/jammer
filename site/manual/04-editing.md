# Editing

Every edit is non-destructive: clips play from your files, and edits change only the project. Every command can be undone with ⌘Z and redone with ⇧⌘Z.

## Cut, copy, paste and delete

| Command | Shortcut | What it does |
|---|---|---|
| **Edit › Cut** | ⌘X | Copies the selection and removes it; what follows moves left |
| **Edit › Copy** | ⌘C | Copies the selection |
| **Edit › Paste** | ⌘V | Inserts what you copied at the selection start (or the playhead) and pushes the rest right |
| **Edit › Delete** | Delete | Removes the selection; what follows moves left |
| **Audio › Silence** | ⇧⌘L | Replaces the selection with silence without moving anything |
| **Audio › Crop to Selection** | ⌘T | Keeps only the selection |
| **Audio › Insert 1 Second of Silence** | | Opens a one-second gap at the playhead |

You can copy in one project and paste in another.

Markers inside a deleted range are removed; markers after it move with the audio.

## Fades

**Audio › Fade In** (⌥⌘I) and **Audio › Fade Out** (⌥⌘O) fade over the selection. A fade in starts at the selection start, a fade out ends at the selection end, and the clip is split there if needed. The curve is equal-power, which sounds even to the ear.

The selection must lie inside one clip per track. If it crosses a clip edge, Jämmer says so and changes nothing; fade each clip separately.

## Gain

**Audio › Gain +1 dB** (⌘]) and **Audio › Gain −1 dB** (⌘[) change the level of the selection, or of everything when nothing is selected. The command palette also has ±6 dB.

Gain at exactly 0 dB leaves the samples bit-exact.

## Markers

**Audio › Add Marker** (⌥⌘M) adds a marker at the selection start, or at the playhead. Markers appear as yellow flags with their names and are saved in exported WAV files as cue points.

## Clips

Every edit that cuts through audio splits it into clips. You see clip edges as thin lines in the lanes. Double-click a clip to select it.
