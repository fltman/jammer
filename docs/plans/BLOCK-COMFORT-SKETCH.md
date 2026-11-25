# Sketch: the next block (comfort, full screen, tool palette, menus, track headers, agent coverage)

For the coordinator before anything is built (2026-11-25). The sweep behind it is `docs/plans/comfort-sweep-2026-11-25.md` (seven read-only agents, every finding with file and line). Nothing here is built yet. No release until all of it is in place (Anders, 2026-11-25).

## 1. What a user notices first (the merged list)

Sorted by how soon a user notices it. Each line is a group of findings; the sweep file has the places in the code.

### High: noticed within minutes

| # | What | Where it shows | Comfort point |
|---|---|---|---|
| H1 | **No context menus anywhere.** Right-click on waveform, clip, track, marker, word, automation point or mixer strip does nothing (the transcript gives only NSTextView's text menu). Build them from the same command registry as the menu bar: names, shortcuts, enabled state. | everywhere | 8, 21 |
| H2 | **The pointer never changes.** No cursor rects in the timeline, lanes or spectrogram: no ↔ on edges, no hand on points, no crosshair or brush circle for spectral tools. | timeline, lanes, spectrogram | 1 |
| H3 | **Nothing can be grabbed.** Selection edges (1 pt, only ⇧-click), clip trim, fade corners, spectral areas, markers: none has a handle or hit area. Fades come only from the menu. | timeline, spectrogram | 2 |
| H4 | **⌘K is a separate hand-made list** (~28 of 133 menu items, its own shortcuts that already differ from the menus, no enabled state). Build it from the same registry. | omnibar, palette | 13, 21 |
| H5 | **Disabled commands never say why** (menus, ⌘K). The registry gives each command a reason; the menu shows it as a tooltip, ⌘K as the row's detail. | menus, ⌘K | 13 |
| H6 | **Jobs can't be stopped from the window**: transcription, repairs, batch, export, model downloads, Overdub, assistant planning. Each gets a Stop beside its progress that stops only that job. | status bar, panels, Settings | 9, 12 |
| H7 | **The mixer has no level meters** (no peak, no clip light) and no Track menu: rename, reorder, delete or duplicate a track only through the agent. | mixer, menus | NEW |
| H8 | **Track name plates are pictures**, not controls: no select, rename, reorder, mute/solo badges. (Merges with section 5.) | timeline | NEW, 8 |
| H9 | **Transcript can't be searched or corrected in place**, though the manual promises "read, search and correct"; Remove Filler Words is reachable only through the assistant. Edit › Delete/Cut are grey while words are selected. | transcript | 20, NEW |
| H10 | **Audio files can't be dropped on the window.** | timeline | 5 |
| H11 | **Typed text is lost**: the omnibar overwrites the assistant's draft; a request that can't go (no model, no key, network) is cleared from the field. Clone Voice loses the typed name, Overdub the edited text. | assistant, Overdub | 11 |
| H12 | **Focus jumps to the timeline** every time the window becomes key, so Space after ⌘-Tab plays instead of typing. | assistant | NEW |
| H13 | **Search forgives neither accents nor typos** ("begransa", "gain -1" with an ASCII minus). | ⌘K | 20 |
| H14 | **Export proposes .wav whatever format is remembered**, so a .mp3 can be overwritten without the panel asking. | Export | 17 |

### Medium: noticed in a working session

- **Esc doesn't cancel a drag** (selection, automation point, spectral drawing); autoscroll stops when the mouse stops; no snapping or snap line for the selection.
- **Undo names are vague**: "Undo Change Track", "Undo Assistant", "Undo Loudness Preset" instead of the chosen command ("Undo Gain +1 dB", "Undo Mute Dialogue").
- **No value fields**: faders, pan, sends (five presets only), Restore sliders, spectral dialogs. No ⌥-click reset, no −∞, pan/VCA/master heard only on release.
- **Markers can't be clicked, moved, renamed or deleted**; no next/previous marker.
- **Keyboard can't select** (⇧-arrows), no focus ring on the timeline or transcript.
- **Shortcut clashes**: ⌥⌘M (Minimize All) is Add Marker; ⌘= doesn't zoom on a US keyboard; ⌘E takes Use Selection for Find.
- **Spectral**: the current tool can't be seen or picked from a menu; the area points to a track by index (wrong track after undo or reorder); edits made during a spectral job are lost; heal errors show in English in a Swedish window.
- **Transcript**: stale highlighted words can be deleted after deselecting on the timeline; follow-scrolling fights the reader; the engine choice isn't remembered; the "working on this Mac" text shows for OpenAI and Berget jobs.
- **Small windows**: History outlives its document, Storage scans on the main thread, Settings › Remove deletes a large model without asking, Batch forgets folder and format.
- **Mouse-wheel zoom** barely moves (1 % per notch); no overview bar for long files.

### Low: polish

Tooltips missing on several icon buttons (Send, level, Mute, Output, bypass) and the Transcribe button; ellipses on items that open a window without asking anything; Show History never becomes Hide History; no ⌘? Help item; Duplicate on ⇧⌘S without Save As; empty timeline has no hint; the reading-progress text overlaps the track name; animations without fades; a Settings window that isn't the standard pane style.

### Already good (kept as is)

View modes are not undo steps; a drag is one named step in the lanes; pinch and modifier-scroll zoom around the pointer; paid routes ask and are fully localized; standard shortcuts ⌘H, ⌘M, ⌃⌘F are right; menu titles come from the catalogue in both languages and are checked against the running app.

## 2. Full screen and focus mode

- The window already gets View › Enter Full Screen (⌃⌘F) and the green button from macOS. To check and fix: the editor's layout uses the extra height (the transcript and lanes get it, not empty space), the mixer and picture windows behave as separate full-screen spaces or stay floating, and sheets, popovers, the omnibar and the model sheet open on the full-screen window.
- **Focus mode** (View › Focus Mode, ⌃⌘⇧F is free; Swedish: Visa › Fokusläge): hides the assistant and transcript panels and the tool palette, keeps the timeline and the omnibar. A view mode, never an undo step; remembered per window.

## 3. Tool palette

Same pattern as Glimmer's: a narrow vertical palette at the left edge of the timeline, icons with help tags (name and key, both languages), the current tool highlighted, single-letter keys while the timeline has the keys, and the pointer showing the tool (H2). Proposed tools:

| Tool | Key | What it does |
|---|---|---|
| Selection | A | Select a range; drag edges to adjust (H3). The default. |
| Split | S | Click splits the clip at that point (one step). |
| Trim | T | Drag clip edges; ⌥ trims without rippling. |
| Fade | F | Drag from a clip corner to make a fade; drag the curve to change its shape. |
| Gain | G | Drag up/down on a clip or selection to change its gain, value shown while dragging. |
| Spectral box / lasso / brush | B / L / P | As today, now visible and in View › Spectrogram Tool. |
| Zoom | Z | Click zooms in around the point, ⌥-click out, drag zooms to a range. |
| Hand | H | Drag to pan; Space held does the same temporarily. |

Which of these Anders wants is asked in the session's window, one question at a time.

## 4. Menus, current and proposed

Today: Jämmer 8 items, File 18, Edit 6, **Audio 75**, Transport 2, View 21, Help 3 (`Config/menus-en.txt`). Proposed, following Apple's order (App, File, Edit, View, the app's own menus, Window, Help) and the siblings. No item disappears; every move is listed.

| Proposed (English) | Proposed (Swedish) | Comes from |
|---|---|---|
| **Jämmer**: unchanged | **Jämmer** | Jämmer |
| **File**: New, Open…, Open Recent, Close, Close All, Save, Save As… (⇧⌘S), Duplicate (⌥⇧⌘S), Revert to Saved · Import Tracks… (⇧⌘I), Import Timeline… · Export Audio… (⇧⌘E), Export Transcript…, Export Timeline… · Send to Flimmer… · Collect Audio and Save, Linked Files Waiting…, Batch… (⌥⌘B), Storage | **Arkiv** (same items) | File; Save As added; Duplicate moves to ⌥⇧⌘S; ellipsis added to Export Transcript |
| **Edit**: Undo, Redo, Cut, Copy, Paste, Delete (⌫), Select All, **Deselect All** (⇧⌘A) · **Find in Transcript** (⌘F), Find Next (⌘G) · **Correct Word…**, **Remove Filler Words** · Omnibar (⌘K) | **Redigera**: … Avmarkera allt, Sök i utskriften, Sök nästa, Rätta ord…, Ta bort utfyllnadsord | Edit; new items are operations that today exist only for the agent |
| **View**: Show/Hide Transcript (⌥⌘T), Assistant (⌥⌘A), History (⌥⌘Y), Tool Palette · Show Spectrogram (⌥⌘S), Spectrogram Tool ▸ Box/Lasso/Brush · Automation ▸ … · Zoom In (⌘+ and ⌘=), Zoom Out, Zoom to Fit, Zoom to Selection (⌥⌘E) · Focus Mode, Enter Full Screen (⌃⌘F) | **Visa**: … Verktygspalett, Spektrogramverktyg, Fokusläge, Helskärm | View; Zoom to Selection leaves ⌘E (Find's) |
| **Track** (new): New Track, Rename Track…, Duplicate Track, Delete Track, Move Up, Move Down · Mute, Solo, Lock · Layout ▸ … · Mixer… (⌥⌘X), Plugins… (⌥⇧⌘P) | **Spår**: Nytt spår, Byt namn…, Duplicera, Radera, Flytta upp/ner, Tysta, Solo, Lås, Högtalaruppställning, Mixer, Insticksprogram | Audio › Layout, Mixer, Plugins; the rest new (operations exist: set_track, add/remove) |
| **Audio** (editing the sound): Fade In, Fade Out, Silence, Crop to Selection, Insert Silence, Gain ±1 dB · Normalize ▸ …, Loudness Preset ▸ …, Loudness Preset With Limiter ▸ …, Limit Peaks…, Duck Under Speech…, Level Speakers ▸ … · Measure Loudness (⌥⌘L), Check Against ACX… · Separate Stems ▸ … | **Ljud** (same items) | Audio (the editing and loudness part) |
| **Repair** (new): Remove Hum…, Repair Clipping…, Remove Clicks…, Reduce Noise…, Reduce Reverb…, Remove Bleed ▸ … · Attenuate Frequencies…, Attenuate Area…, Heal Area, Edit Spectrum Numerically… | **Reparera** | Audio (the restoration and spectral part) |
| **Speech** (new): **Transcribe** (the panel's button as a command), Transcribe Voice Tracks, Find Speakers ▸ …, Split Speakers onto Tracks, Split and Transcribe Speakers, Save Speaker as Voice Profile… · Clone Voice…, Overdub…, Delete Cloned Voice… | **Tal**: Skriv ut, … | Audio (speech part) |
| **Transport**: Play/Stop (Space shown), Go to Start (↩), **Go to End**, **Next Marker** (⌥→), **Previous Marker** (⌥←) · Add Marker (M on the timeline, ⇧⌘M in the menu), Set Tempo…, Detect Tempo · Listen on Headphones, Follow Head Movements, Center Head | **Uppspelning** | Transport + Audio (markers, tempo, listening); Add Marker leaves ⌥⌘M (Minimize All) |
| **Window**: macOS's own, plus Picture… | **Fönster** | Audio › Picture |
| **Help**: **Jämmer Help** (⌘?, the manual in the window's language), Agent Access…, Open the Agent Guide, Jämmer Website | **Hjälp**: Jämmer-hjälp, … | Help |

Context menus (H1) take their items from the same registry: a clip (Cut, Copy, Delete, Split, Fade In/Out, Gain, Rename source), a track (the Track menu's items), a marker (Rename, Delete, Select to Next), a word (Correct, Delete, Play from Here, Remove Filler Words), a spectral area (Heal, Attenuate, Clear, tools), a mixer strip (Track menu + Output, Sends, Plugins).

## 5. Settings in the track header

A real header view at the start of each lane, replacing the painted plate: name (double-click to rename), level (a small fader with a value field, ⌥-click 0 dB), mute, solo (⌥-click exclusive), pan, and lock (Jämmer has no recording, so no arm; lock stops edits to that track). Each change is one named undo step, saved in the document, reachable through `set_track` in the API (lock is a new parameter) and labelled for VoiceOver ("Dialogue, level −3 dB, muted"). Cloned-voice badge and frozen state stay on the plate.

## 6. The agent's coverage

- One command registry for the menu bar, the context menus, ⌘K and the tool palette: each entry has its title, keys, validation with a reason, and the **operation** it corresponds to (today only 19 of the menu's items go through `op(...)`; the other ~75 are selectors).
- A report generated from it (`docs/AGENT-COVERAGE.md` and a section in the agent guide): every menu item, tool, button and setting with its operation, or the reason it has none.
- A test that fails a command without an operation unless it is on an explicit list of exceptions with the reason (consent and payment sheets, file panels, window arrangement, Quit). The agent guide and the assistant's tools stay generated from the same registry.

## 7. Order and questions

Order: the registry first (it carries H1, H4, H5, the menus and the coverage), then handles and pointers (H2, H3, palette), stop buttons (H6), track headers and mixer (H7, H8, section 5), the transcript (H9), then the medium and low lists. Each step with tests where they can be written (a view sets the right pointer for its zones; every command has an operation; Esc ends a drag without a step).

Questions for Anders, one at a time in the session's window: which tools in the palette; whether the new Track, Repair and Speech menus are wanted or the Audio menu should stay one menu with sections; level meters in the mixer (post-fader peak with a clip light) as proposed.
