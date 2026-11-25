# Comfort sweep of Jämmer's interface, 2026-11-25

Seven read-only agents, one per part of the interface, against SIBLINGS "Komfort: det man märker när det saknas" (21 points). Numbers in brackets are the list's points; NEW is something the list doesn't name. Nothing was changed.


## Spectrogram and its tools

- [1] No tool pointer anywhere in the spectrogram. TimelineOverlay sets no cursor rects, tracking areas or NSCursor calls (App/TimelineView.swift:341-710). Box, lasso and brush all show the arrow, and the brush's 10 pt radius is never shown before you paint. High. Fix: in area mode, use the crosshair for box and lasso and a circle cursor sized to `brushPixels` for the brush.

- [2] A drawn area has no handles and can't be adjusted. `drawArea()` only strokes the outline (TimelineView.swift:550-577). `mouseDown` always starts a new drawing (585-591), so a box can't be resized at its edges or corners or moved. A slightly wrong box has to be redrawn. High. Fix: draw corner and edge handles with 8 pt hit areas, use resize and open/closed-hand cursors, and drag to adjust.

- [5] Esc doesn't cancel a drawing in progress. Esc clears `spectralArea` (683), but `drawing` stays set, and the next `mouseDragged` rebuilds the area (618-623). There is no auto-scroll at the edges while drawing (the selection drag has it at 630), and nothing snaps to the selection or playhead. Medium. Fix: clear `drawing` on Esc and add edge auto-scroll to the drawing path.

- [9/12] Heal and Attenuate Area show no progress and can't be stopped. `editArea` runs `spectral_edit` with no "working" status, no progress and no cancel (EditorSession.swift:178-181). Even the older Attenuate Frequencies only sets a status text (EditorWindowController.swift:258). Medium. Fix: show a cancellable progress item in the status bar and block a second run while one is going.

- [NEW] Edits made during a spectral job are lost. Both paths take a snapshot, compute, then commit over the current project: `run` at EditorSession.swift:529-545, and Attenuate Frequencies captures `p` at EditorWindowController.swift:256 and commits `q` at :262. Moving a clip while it renders silently undoes that move. Medium. Fix: refuse to commit if `project` changed since the snapshot, or lock editing during the job.

- [NEW] The heal error is English in Swedish. On failure `editArea` shows `f.error` (EditorSession.swift:180), while `perform` uses `failed.keyed.map(L10n.message)` (EditorSession.swift:586). So "Heal is for short sounds (up to 0.5 s)…" (SpectralEdit.swift:84) is not translated, and it is not passed through `say(..., .error)` either. Medium. Fix: use the keyed message and `say(..., .error)`.

- [13] Heal Area doesn't say why it fails until it runs. Validation only checks that an area exists (EditorWindowController.swift:911-912). An area longer than 0.5 s (`Spectral.healLimit`, SpectralEdit.swift:117) leaves the item enabled, and it fails only after the job. A disabled item also gives no reason. Medium. Fix: disable Heal when the area is longer than `healLimit`, with that reason shown in the menu and ⌘K.

- [NEW] You can't see or pick the current tool. Tools are chosen only with B, L and P while the overlay has focus (TimelineView.swift:685-687), and the only sign is a status line that the next drag overwrites (EditorSession.swift:161). There is no menu item, toolbar segment or checkmark, and the keys do nothing when focus is elsewhere. Medium-high. Fix: add View › Spectrogram Tool › Box/Lasso/Brush items with checkmarks and B/L/P, plus an icon segment with help tags in both languages.

- [8/21] There is no context menu in the timeline or spectrogram. No `menu(for:)` or `rightMouseDown` exists (grep over TimelineView.swift and EditorWindowController.swift). Right-clicking an area should offer Heal Area, Attenuate Area…, Clear Area and the tools. High. Fix: build the menu from the same items and validation as the Audio menu.

- [NEW] The area points to a track by index and is never cleared on document changes. `SpectralArea.track` is an Int (EditorSession.swift:158), and it is cleared only at EditorSession.swift:180 and TimelineView.swift:641/645/683. After deleting or reordering tracks, or after undo, Heal can act on the wrong track. Medium. Fix: store the track's UUID and clear the area when that track goes away.

- [19/NEW] Nothing shows time or frequency under the pointer, and there is no frequency scale. There is no `mouseMoved` on the overlay and no Hz labels are drawn (TimelineView.swift:394-495). While dragging, values appear only in the status bar (EditorSession.swift:161). Medium. Fix: draw a Hz scale at the lane edge, and show "1.42 s · 2.1 kHz" by the pointer on hover and while dragging.

- [18] The dialog fields are bare text fields. Attenuate Area takes dB in a plain NSTextField with no unit, stepper or arrow keys (EditorWindowController.swift:280-283). Edit Spectrum Numerically uses five plain fields with no number formatter (298-303), so empty input silently becomes 0. Its Change field also stays active for Heal, which ignores it (320). Low-medium. Fix: use NumberFormatter fields with steppers, ↑/↓ and ⇧ steps and a "dB" label, and disable Change when Heal is chosen.

- [NEW] Edit Spectrum Numerically replaces your drawn area. It writes `spectralArea` before running (EditorWindowController.swift:318). If heal fails, a typed box is left where the drawn area was. Low. Fix: run the typed box without storing it as the area.

- [NEW] The area is gone after you apply it. On success `spectralArea = nil` (EditorSession.swift:180). Undoing and trying another amount means redrawing. Low. Fix: keep the area after applying (or restore it on Undo).

- [9] The spectrogram renders with no sign of activity. On an edit or zoom, the old image is stretched (`contentsGravity = .resize`, SpectrogramView.swift:19) until the detached render finishes (45-51), with no spinner. Low. Fix: show a small progress indicator while a render is pending.

- [10] The area appears and disappears instantly, with no fade (TimelineView.swift:547, 683). Low. Fix: use a short fade that is skipped under Reduce Motion.

What is already good:
- Pinch and ⌘/⌥-scroll zoom around the pointer (TimelineView.swift:662-674), a superseded spectrogram render is cancelled (SpectrogramView.swift:44), and the "zoom in" empty state says what to do, in both languages.
- Drawing an area is view state, not an undo step. Each heal or attenuate is one named undo step ("Heal Area" / "Läk område"), and the area summary and VoiceOver text are localized (TimelineView.swift:369).
- The manual (site/manual/13-restoration.md:31-41) and the shortcut table cover B/L/P, Esc and the numeric fallback.


## Waveform and timeline

- [1] No pointer changes anywhere in the timeline. `TimelineOverlay` has no `resetCursorRects`, tracking area or `NSCursor` call (`App/TimelineView.swift:340-710`). `AutomationLanesView` has a tracking area for its value label but never sets a cursor (`App/AutomationLanesView.swift:604-622`). So there is no resizeLeftRight on selection or clip edges, no open/closed hand on automation points, no crosshair for the spectral box, lasso and brush tools. High. Fix: add cursor rects for the ruler, the edges and the points, and push the hand cursors in mouseDown/mouseUp.
- [2] Selection edges can't be grabbed. A plain click within 1 pt of an edge starts a new selection (`TimelineView.swift:609-611`); only ⇧-click moves the nearest edge (`:605-608`). The edges are 1 pt lines with no handle or hover state (`:462-469`). High. Fix: hit-test ±4 pt around each edge on mouseDown and drag that edge, with a small handle shown on hover.
- [2/NEW] No clip trim, clip move or fade handles. Clip edges and fades are only drawn (`TimelineView.swift:435-443`), and the manual confirms fades come only from the menu (`site/manual/04-editing.md:23`). `drawFade` always draws a straight line, even for the equal-power curve (`:497-506`). High. Fix: add fade-corner handles (8 pt hit area) and edge trim on clips, each committed as one named step on mouseUp.
- [5] Selection drag doesn't snap. Snapping exists only for automation points (`AutomationLanesView.swift:469-477`, `:535`), and even there no snap line is drawn. The selection drag uses the raw frame (`TimelineView.swift:631-633`). Medium. Fix: reuse `snapped()` for selection and edge drags, draw a vertical line at the snap target, and keep ⌃ to bypass.
- [5] Esc doesn't cancel a drag. During an automation-point drag, Esc only clears `selected` (`AutomationLanesView.swift:728-731`); `drag` survives and mouseUp still commits it (`:589-590`). During a selection drag, Esc clears the selection (`TimelineView.swift:684`) but the next mouseDragged puts it back. Medium. Fix: when a drag is in progress, Esc restores `d.origin` or the previous selection and ends the drag.
- [5/NEW] Autoscroll at the window edge only runs while the mouse moves. It scrolls only inside `mouseDragged` (`TimelineView.swift:630`), so holding the pointer still past the edge stops the scroll. Medium. Fix: run a timer during the drag, or use `autoscroll(with:)` with a periodic event.
- [5/NEW] Files can't be dropped on the window. There is no `registerForDraggedTypes` anywhere in `App/*.swift`, so an audio file dropped on the timeline does nothing. High. Fix: accept file URLs on `TimelineView`, show an insertion line at the drop point, and import there.
- [8/21] No context menu in the timeline or the lanes. There is no `menu(for:)` or `rightMouseDown` in `TimelineView.swift` or `AutomationLanesView.swift`, so Cut/Copy/Delete/Fade/Add Marker/Zoom to Selection only appear in the menu bar. High. Fix: build the menu from the same items `validateMenuItem` checks (`EditorWindowController.swift:904-980`).
- [NEW] Markers can't be touched. They are drawn as flags (`TimelineView.swift:472-486`), but clicking a flag doesn't select it or move the playhead there, and they can't be dragged, renamed or deleted. There is also no next/previous marker key. The only marker action is Add (`EditorWindowController.swift:672-674`). Medium. Fix: hit-test the flags so a click jumps there and a drag moves the marker; add double-click to rename, a context menu with Delete, and ⌥←/⌥→ for previous/next marker.
- [6] ⌘/⌥-scroll zoom barely works on a mouse wheel. The factor is `pow(1.01, scrollingDeltaY)` with no scaling for line-based deltas (`TimelineView.swift:665`), so one notch zooms about 1 %. Pinch and trackpad zoom around the pointer correctly (`:672-674`). Medium for mouse users. Fix: multiply the delta by about 10 when `!hasPreciseScrollingDeltas`, as the pan does at `:669`.
- [6/NEW] No scroller or overview bar. Nothing shows where the view sits in a long file, and there is nothing to grab and drag (`TimelineView.swift:137-146`). Smart zoom (`smartMagnify`, a two-finger double-tap) is not handled either. Medium. Fix: add a thin overview strip or an `NSScroller` bound to `viewport`.
- [3] No focus ring on the timeline. `TimelineOverlay` becomes first responder (`TimelineView.swift:382-383`) but never draws a focus ring (`focusRingMaskBounds`/`drawFocusRingMask`), so with Full Keyboard Access you can't see that the timeline has the keys. Automation points also don't highlight on hover (`AutomationLanesView.swift:333-345`). Medium. Fix: implement the focus ring mask over the bounds, and enlarge or brighten the point under the pointer.
- [15/18/NEW] The keyboard can't select. ←/→ only move the playhead 1 s (`TimelineView.swift:689-690`). There is no ⇧←/→ to extend the selection, no ⌥ for a finer step, and no keys to set the selection start or end at the playhead. Automation points have full key control (`AutomationLanesView.swift:690-701`); the selection should match. Medium. Fix: ⇧-arrows extend from the playhead, ⌥-arrows step 10 ms, and two keys set the start and end at the playhead.
- [19/18] The selection's values are only shown in the status bar. While dragging, the start, end and length appear there (`EditorWindowController.swift:1053-1054`), far from the pointer, and they can't be typed. Low. Fix: draw a length/time label at the pointer during the drag, and make the status text editable fields.
- [NEW] The waveform-progress text is drawn over the track name. The name plate is drawn at `y+22` (`TimelineView.swift:454`) and "Reading … %" at `y+24` in the same x position (`:457`), so they overlap on files over 10 minutes. Low. Fix: draw the progress below the plate (around y+44) or in the empty lane centre.
- [16] ⌘E for Zoom to Selection takes the standard "Use Selection for Find" shortcut (`Config/menus-en.txt:114`). Low. Fix: use ⌥⌘E or ⌘F-free alternatives, keeping ⌘E if the app has no find.
- [9] An empty document has no empty-state hint. No empty-state text exists in the timeline (`TimelineView.swift:394-495`). Low. Fix: when `project.length == 0`, draw "Drop audio here or choose File › Import Tracks… (⇧⌘I)".

Already good: the selection, zoom and spectrogram toggle are not undo steps, an automation drag is one named step on mouseUp (`AutomationLanesView.swift:589-590`), and menu edits are named through `L10n.operation` (`EditorSession.swift:571`). Pinch and modifier-scroll zoom around the pointer. Point hit areas are 8 pt (`:487`), and the value label follows the drag. The zoom and transport buttons have bilingual tooltips that include the shortcut.


## Transcript

- [12/9] No way to stop a transcription. The panel shows only a progress bar (`App/TranscriptView.swift:146-148`) and the status bar shows only text (`App/EditorWindowController.swift:1058-1060`). The only caller of `JobRegistry.cancel` is the agent API (`App/AgentServer.swift:285`). A long local or paid job can't be stopped. High. Fix: add a Stop button next to the progress bar that cancels only this document's transcribe job, and make Esc trigger it.

- [20/NEW] No search in the transcript. There is no Find item in the Edit menu (`Config/menus-en.txt:27-32`), and no `usesFindBar` or `isIncrementalSearchingEnabled` is set anywhere in App. The engine tooltip and the manual both promise "read, search and correct" (`App/Localizable.xcstrings` key `transcript.engine.openai.help`, `site/manual/12-transcripts.md:38`). High. Fix: set `textView.usesFindBar = true`, add Edit › Find (⌘F, ⌘G), and match ignoring case and accents.

- [NEW] Words can't be corrected in the panel. The `correct_word` operation exists ("Rätta ord"), but the text view is read-only (`App/TranscriptView.swift:89`) and the only way to correct is the assistant or the agent API. The same goes for renaming a speaker from its label. High for a text editor. Fix: double-click a word (or press Return) to edit it in place, as one undo step "Correct Word".

- [NEW/8] No menu item or command for filler words. `remove_fillers` can only be reached through the assistant (`App/AssistantPanel.swift:259`). It is not in the Edit or Audio menus (`App/JammerApp.swift:251-262`), not in `MenuPresets` (`App/JammerApp.swift:16-30`) and not in the palette (`App/CommandPalette.swift:18-60`). The manual doesn't mention it either. High. Fix: add "Remove Filler Words" to the Audio menu, the palette and the transcript's context menu, and highlight fillers in the text.

- [8/21] The transcript's context menu is NSTextView's default one: Spelling, Font, Speech and so on. `TranscriptTextView` (`App/TranscriptView.swift:406-421`) has no `menu(for:)`, so Delete Words, Play from Here, Copy, Cut, Correct and Export are not in it. Medium. Fix: override `menu(for:)` and build it from the same items as the menu bar.

- [NEW] Edit-menu commands go to the wrong place when the transcript has focus. Edit › Delete and Cut use `TimelineOverlay` selectors (`App/JammerApp.swift:255-258`). NSTextView answers them first and disables them because the view is read-only. So only the Delete key deletes words, and the menu is greyed out. Medium. Fix: implement `delete:` and `cut:` in `TranscriptTextView`, routed to `deleteSelectedWords` or to the session's cut.

- [NEW] The highlighted words can be stale, and Delete then removes words that are no longer selected. `mirrorSelection` returns early when `session.selection` is nil (`App/TranscriptView.swift:251`). Deselect on the timeline and the words stay highlighted; press ⌫ in the transcript and they are deleted. Selecting only spaces also leaves the old timeline selection in place (`:283-284`). Medium-high. Fix: clear the text selection when the session selection is nil or contains no words.

- [3] Keyboard focus can't be seen. The text view draws no background and no focus ring (`App/TranscriptView.swift:91, 97-99`). Space and ⌫ act differently in the transcript and on the timeline, and the user can't tell which one has focus. Medium. Fix: set `scroll.focusRingType = .exterior` or draw an accent border while the text view is first responder.

- [2] The panel can't be resized. Its height is fixed at 0.45 of the timeline inside an NSStackView (`App/EditorWindowController.swift:53-56`), so there is no divider to drag. Medium. Fix: use an NSSplitView with a resizeUpDown divider and remember its position.

- [NEW] Autoscroll fights the reader. `scrollRangeToVisible` runs on every new word during playback (`App/TranscriptView.swift:236`), so the view snaps back while the user scrolls to read ahead. Medium. Fix: pause follow-scrolling after the user scrolls and resume when playback restarts or after a few seconds.

- [9] The empty state can be wrong. "Transcribing on this Mac…" also shows for OpenAI and Berget jobs (`App/TranscriptView.swift:154`), which contradicts the upload the user just confirmed. When transcripts exist but nothing plays (every clip cut, or the tracks muted), it says "No transcript yet… click Transcribe" while the button reads "Transcribe Again" (`:150-162`). Medium. Fix: base the working text on the job's engine, and add a "Nothing audible has a transcript" state.

- [NEW] The text-only notice is never shown. The `transcript.textOnly` string exists but nothing uses it. The panel only reacts when a word is clicked (`App/TranscriptView.swift:274-276`), so OpenAI and Berget users find out late that they can't edit by word. Low-medium. Fix: show it as a one-line banner above the text when the transcript is text-only.

- [NEW] The engine choice isn't remembered and isn't matched to the language. Language is saved (`App/TranscriptView.swift:300`), but the engine always resets to "On this Mac" (`:24-26, 68-83`). Pianissimo and Berget allow any of 10 languages and only fail after Transcribe is clicked. Medium. Fix: save the engine in UserDefaults and disable languages the chosen engine can't handle, with a tooltip saying why.

- [4/13] Missing help tags and reasons. The Transcribe button and the language picker have no tooltip (`App/TranscriptView.swift:55-60`). A plain "Transcribe" command exists in neither the menu nor the palette, only the voice-track variants (`App/CommandPalette.swift:45`). Export Transcript is disabled without saying why (`App/EditorWindowController.swift:946`). ⌫ with nothing selected only beeps (`App/TranscriptView.swift:291`). Low-medium. Fix: add tooltips, an Audio › Transcribe command, and disabled reasons.

- [17/NEW] Export details. The format always starts at TXT and isn't remembered (`App/EditorWindowController.swift:1203`). The menu title has no ellipsis even though it opens a panel ("Export Transcript", `Config/menus-en.txt:21`). Only the whole transcript or one track can be exported, not the selection. Low. Fix: remember the format, use the title "Export Transcript…", and add a "Selection only" option.

- [NEW] Unsure words explain nothing on hover. The dotted underline (`App/TranscriptView.swift:212-216`) has no tooltip with confidence or time, and words don't react to hover. Low. Fix: add a `.toolTip` attribute with the time and confidence, and a faint hover highlight.

- [NEW] The text size is fixed at 14 pt with no ⌘+ / ⌘− (`App/TranscriptView.swift:93, 197`). Low. Fix: add View › Bigger/Smaller for the transcript and respect the system text size.

What is already good:
- Each deletion is one named undo step ("Delete Words", `App/EditorSession.swift:571`), and a transcription is one step ("Transcribe", `:421`).
- Word selection mirrors the timeline, Space plays, and ⌥⌘T has a dynamic Show/Hide title.
- Paid routes ask before sending, check whether the sources changed, and are fully localized. Export proposes the document's name and keeps the file extension in sync with the format.


## Track headers and mixer

- [NEW] The mixer has no level meters — No strip, bus or master shows signal level, peak hold or clipping. The only level shown is the fader's dB as text (`App/MixerView.swift:475`). A search of `App/` finds only `LoudnessMeter`, which is used for offline measuring. High: a mixer without meters is the first thing a mix engineer notices. Fix: add a post-fader peak/RMS meter with a clip light to each `MixerStrip`, `VCAStrip` and `MasterStrip`.

- [NEW/8] Track name plates are only painted, not controls — The plate is text drawn in `draw()` (`App/TimelineView.swift:445-454`). Clicking a lane only makes a time selection (`:579-613`). There is no track selection, no click to select, no double-click to rename, no drag to reorder, no hover state and no context menu. High. Fix: make the plate a real header view with selection, rename, a reorder drag that shows a drop line, and a context menu.

- [NEW/21] There is no Track menu — `Config/menus-en.txt` has no New, Rename, Delete, Duplicate or Move Up/Down track. Renaming exists only as the `name` parameter of `set_track` (`Packages/JammerKit/Sources/JammerAgent/Operations.swift:1174`), so in practice only the agent or assistant can do it. Track and bus names in the mixer are static `Text` (`MixerView.swift:441`, `:202`). High. Fix: add a Track menu from the operations registry and share it with the plate and strip context menus.

- [8/21] The mixer has no context menus — There is no `.contextMenu` in `MixerView.swift` or `PluginsView.swift`. Right-clicking a strip does nothing. Medium. Fix: give each strip a context menu with Rename, Mute, Solo, Freeze, Output, Sends and Plugins, taken from the shared registry.

- [NEW] The timeline doesn't show mute, solo or freeze — A lane and its plate look the same whether the track is muted, soloed or frozen (`TimelineView.swift:433-454`). Solo is mentioned only in the window subtitle (`EditorWindowController.swift:132`). Medium. Fix: dim muted lanes and add M/S/❄ badges on the plate.

- [18] Faders and sends have no value fields — Level, pan, VCA, master and ceiling are sliders next to read-only `Text` (`MixerView.swift:475`, `:503`, `:216`, `:260`, `:275`). Send levels are limited to five presets in a menu (`:574-576`). Medium. Fix: make the dB/pan labels editable number fields with arrow keys (⇧ for bigger steps), and give sends a slider plus a field.

- [NEW] No reset or fine control on faders — Double-click or ⌥-click does not return to 0 dB / centre. There is no fine drag, no −∞ (the range stops at −60, `:459`), and the scale is linear in dB. Medium. Fix: ⌥-click resets, ⌘-drag is fine, and the bottom of the range is −∞.

- [15] Arrow keys on sliders may never be saved (needs checking) — The value is committed only in `onEditingChanged(false)` (`MixerView.swift:208-211`, `:459-470`, `:492-496`). If keyboard or VoiceOver changes on the macOS `Slider` don't fire that callback, the change is never sent. If they do, each key press becomes its own undo step. Medium. Fix: commit keyboard changes through a debounced single step.

- [19] The surround and field panners don't show their value while dragging — The labels read the committed `place` / `rotation`, not the `azimuth` / `yaw` being dragged (`MixerView.swift:546`, `:520`, `:544`, `:518`). Medium. Fix: build the label text from the live `azimuth` / `yaw` state.

- [NEW] Pan, VCA and master changes are heard only on release — Only the track fader rides live (`faderMoved`, `MixerView.swift:471`). During playback, pan, VCA level, master level and ceiling apply on mouse-up (`:495`, `:210`, `:254`, `:269`). Medium. Fix: route these through live gain/pan the same way the fader does.

- [7] Undo names are vague — Mute, level, pan, output and rename all go through `perform`, which uses the operation title (`App/EditorSession.swift:571`). The menu then says "Undo Change Track" or "Undo Change Bus". Medium. Fix: pass names like "Mute Dialogue" or "Set Level of Dialogue" (localised) from `MixerStrip`.

- [NEW] Inserts can't be reordered and presets aren't offered — The plugin `List` has no `onMove` (`App/PluginsView.swift:50-58`), even though `add_insert` accepts a position. `set_insert` supports `preset` (`Operations.swift:1682`), but there is no preset menu. Medium. Fix: add drag-to-reorder with a drop line (one undo step) and a Presets menu on each row.

- [NEW] Inserts live in a modal sheet, apart from the mixer — `showPlugins` opens a sheet over the document (`EditorWindowController.swift:478-489`). It blocks Space/play, and the mixer window shows no insert slots. Medium. Fix: put an insert column in `MixerStrip` that opens the same list, and make it non-modal.

- [NEW] Generic plugin sliders are rebuilt on every change — `.id("\(p.keyPath)-\(tick)")`, with `tick += 1` in the setter (`PluginsView.swift:289`, `:297`), replaces the slider in the middle of a drag. The thumb likely stops following the pointer. Medium (only for AUs without their own view). Fix: drop the `tick` from `.id` and use a parameter observer to refresh.

- [9] The plugin menu says "Looking for plugins…" for ever — It shows whenever `catalogue.isEmpty`, also after a scan that found nothing (`PluginsView.swift:62`). Low. Fix: keep a separate "loaded" state and say "No effects installed — Scan" when the list is empty.

- [13] The disabled Edit button doesn't say why — `PluginsView.swift:170-172` disables it when the instance is nil (safe mode or failed) and gives no tooltip. Low. Fix: add `.help` with the reason (safe mode / not loaded).

- [4] Tooltips are missing or empty — The pan slider passes `.help("")` when it isn't automated (`MixerView.swift:499`, `:505`). The level fader, Mute, Output, Sends and the bypass switch (`PluginsView.swift:136-142`) have no tooltip. Low. Fix: add localised help to each, including shortcuts where they exist.

- [NEW] Solo has no exclusive mode — It is a checkbox only (`MixerView.swift:447`). ⌥-click to solo only this strip, or to clear all, is missing. Low-medium. Fix: on ⌥-click call `setSolo([id])`, or clear all.

- [2] Lanes can't be resized — Lane height is window height divided by the number of tracks (`TimelineView.swift:432`). There is no divider handle or resize cursor. Medium with many tracks. Fix: add a divider handle per lane with a `resizeUpDown` cursor and a minimum height.

- [NEW] "Done" with Return in a non-modal window — `keyboardShortcut(.defaultAction)` (`MixerView.swift:133`) means Return closes the mixer from a checkbox or slider, and Esc closes it too (`EditorWindowController.swift:1186`). Low. Fix: remove the Done button and rely on the close button and ⌘W.

- [NEW] Window titles go stale — The mixer title (`EditorWindowController.swift:502`) and plugin window titles (`PluginsView.swift:195`) are set once. They don't follow Save As or a track rename. Low. Fix: observe the names and update the titles.

What is already good:
- Fader drags are one undo step and show their value while moving. Solo is correctly not an undo step and is always shown.
- The mixer is its own window that remembers its frame and shares the document's undo (`EditorWindowController.swift:496-520`). Empty states say what to do, and accessibility labels are thorough.
- Pinch and ⌘-scroll zoom around the pointer (`TimelineView.swift:662-674`), and plugin edits are debounced into one undo step.


## Assistant, omnibar and palette

- [11] Omnibar overwrites the assistant draft. `askFromOmnibar` sets `assistant.input = text` and then calls `send()`, so any half-written text in the assistant field is replaced and lost. If the assistant is busy, `send()` returns early and the omnibar text just sits in the field. App/EditorWindowController.swift:740-741, AssistantPanel.swift:168. Medium. Fix: pass the request into `send(goal:)` without touching `input`, and keep a queue while busy.
- [11] A request that isn't sent is cleared from the field. `send()` clears `input` before it checks for a chosen model, a key, the paid question or a network error, and each of those ends with only a note. The text survives only as a user bubble that can't be re-sent. AssistantPanel.swift:169, 177-184, 216-217. Medium. Fix: clear `input` only after the request is accepted, or put the text back on failure, cancel or no model.
- [11] There is no queue. While busy, Return does nothing (`guard !busy`) and the Send button is disabled, with no message and no queue. AssistantPanel.swift:168, 513. Low. Fix: queue the next request with a "Queued" line, or at least set `.help` to "Waiting for the current answer".
- [12] Planning can't be stopped. The `Task` in `send()` is never stored, there is no Stop button, and Esc does nothing. A slow cloud or Ollama model leaves only a spinner. A running plan (`confirmPending`, `run`) can't be stopped either, apart from cancelling its job elsewhere. AssistantPanel.swift:173, 242, 496. High. Fix: keep the task, turn Send into Stop (⌘. / Esc) while busy, cancel only that task and add a "Stopped" note.
- [12] Esc doesn't stop the omnibar's "deciding". `cancel()` clears the query, but the router task still runs and then calls `run(shown[i])` or `send(typed)`, so the command runs after the user backed out. Omnibar.swift:84-88, 108-111, 166. Medium. Fix: store the task, cancel it in `cancel()`, and check `Task.isCancelled` before acting.
- [9] Progress is a bare spinner. `ProgressView()` has no label ("Thinking with OpenRouter…") and no elapsed time. A plan's job only shows in the Jobs panel, and `runJob` polls without saying which step is running. AssistantPanel.swift:496, 353-356. Medium. Fix: a labelled progress row with the source or step name and a Stop button.
- [13] Disabled commands aren't shown as disabled, and nothing says why. The palette lists every command and runs it with `NSApp.sendAction`, which skips `validateMenuItem`. Zoom to Selection with no selection or Export Transcript with no words just closes the bar and nothing happens (TimelineView.swift:130, EditorWindowController.swift:785). The menu itself also only returns `false`, with no reason. CommandPalette.swift:7-13, 22, 47; EditorWindowController.swift:904-958. High. Fix: give `PaletteCommand` `enabled` and `whyNot` values from the same validation, grey the row out and show the reason as its detail.
- [21] The palette is a hand-made list of about 28 entries, not the menu registry of 133 lines. Cut, Paste, Split, Save, Zoom In, Show Spectrogram, Show History, Loudness Preset, Separate Stems, Duck… and Batch are missing. Typing "spectrogram" or "cut" falls through to the assistant. CommandPalette.swift:18-63 vs Config/menus-en.txt. High. Fix: build the entries from the main menu (title, path, key equivalent, validation).
- [4/21] Palette shortcuts don't match the menus. Play shows "Space" but the menu has ⌥⌘P. Go to Start shows "↩" but the menu has none. Fade In and Fade Out (⌥⌘I/⌥⌘O), Silence (⇧⌘L), Crop (⌘T) and Gain ±1 (⌘Ä/⌘Ö) show no shortcut, because presets get `""`. CommandPalette.swift:19-20, 60; menus-en.txt:33-38, 108-109. Medium. Fix: read each item's `keyEquivalent` from its menu item.
- [20] Search doesn't forgive accents or typos. `score` only lowercases and needs the letters in order. "mat loudness" doesn't find "Mät loudness", "begransa" doesn't find "Begränsa toppar…", and "fdae" or "fadde" find nothing. ASCII "-" never matches the "−" (U+2212) in "Gain −1 dB" and "Normalize to −16 LUFS", so "gain -1" misses. Only `route` folds accents. CommandSearch.swift:22-24, 105. High for Swedish users. Fix: fold both sides (`.caseInsensitive`, `.diacriticInsensitive`, `.widthInsensitive`, and − to -), and allow one edit or transposition per word.
- [20] There are no keywords or synonyms, and no matching across languages. Search covers title and group only, so "normalisera" or "lufs" in Swedish doesn't reach "Loudness Preset", and "undo" doesn't find "Ångra". CommandSearch.swift:87-90. Low. Fix: add keywords per entry (op name and English title).
- [7] Assistant undo steps are all named "Undo Assistant". `session.run(steps, action: L10n.text("assistant.title"))` gives one generic name. Also, a plan with a job in between makes several undo steps, which contradicts the intro's "everything is one undo step". AssistantPanel.swift:268, 295-297; intro string. Medium. Fix: "Assistant: Fade In" or "Assistant: 3 changes", and adjust the intro text.
- [4] Tooltips are missing or don't say the shortcut. The Send button has no `.help`. The gear's tooltip is just "Model", and no tooltip names ⌥⌘A. Omnibar rows have none. AssistantPanel.swift:438-440, 511-513. Medium. Fix: `.help("Send (Return)")`, `.help("Assistant Model…")`, Stop with ⌘.
- [3] Omnibar rows have no hover state. Only the ↑/↓ selection is highlighted, even though they are plain-style buttons. Omnibar.swift:124-142. Medium. Fix: an `.onHover` highlight that also moves `chosen`.
- NEW: Focus is taken from the assistant or omnibar every time the window becomes key. `windowDidBecomeKey` always gives the timeline first responder. Typing in the assistant, ⌘-Tabbing to copy something, then coming back and pressing Space starts playback instead of typing. EditorWindowController.swift:150-157 (a workaround for AssistantPanel.swift:519 `.onAppear { focused = true }`). High. Fix: drop the `onAppear` focus, and restore the previous first responder rather than forcing the timeline.
- NEW: Esc doesn't cancel a pending plan. Run and Cancel have no `.keyboardShortcut(.cancelAction)`. Sending a new request also silently replaces the pending plan. AssistantPanel.swift:482-489, 212. Medium. Fix: Esc goes to Cancel, and a new request first cancels the plan with a note.
- NEW: The plan card and the spinner may be off-screen. It only scrolls when `messages.count` changes, not when `pending` or `busy` changes. AssistantPanel.swift:500. Medium. Fix: also scroll on `pending` and `busy`.
- NEW: There is no recall of earlier requests (↑ in an empty field), no Clear Conversation, and no context menu (Copy, Ask Again) on messages. AssistantPanel.swift:451-464. Low. Fix: ↑ to recall, plus a context menu with Copy, Ask Again and Clear.
- NEW: The Send button's check doesn't match `send()`. It trims `.whitespaces` while `send()` trims `.whitespacesAndNewlines`, so newline-only text enables Send, which then does nothing. AssistantPanel.swift:513 vs 167. Low. Fix: use the same trim.

Already good: messages and the omnibar are labelled for VoiceOver, and the omnibar shows its keys (↩/⌘↩/esc) next to the field. An alarming plan has an orange outline and Return defaults to Cancel. The paid question goes in a sheet, a source without a chosen model gives a clear note, and the omnibar ranks by how often you use a command, with an "Ask the assistant" row as fallback.


## Dialogs, sheets and settings

- [12] **No way to stop a running repair or batch job in the window**: after Restore › Apply, the status bar shows "Repairing 34 %" with no Stop button (App/EditorWindowController.swift:1058). The batch window only shows a spinner (App/Batch.swift:258). `JobRegistry.cancel` (App/Jobs.swift:41) is only called from the agent API (App/AgentServer.swift:285), and Config/menus-en.txt has no Stop item. High. Fix: add a Stop button next to the job's progress and in the batch window, and a matching "Stop [job]" menu item, all calling `JobRegistry.cancel`.
- [9/12] **Model downloads can't be cancelled**: a download of several hundred MB shows only a bare `ProgressView`, with no Cancel and no percentage or byte count (App/SettingsWindow.swift:170-171). The task isn't kept (App/SettingsWindow.swift:119). High. Fix: keep the task, show "x of y MB", and add a Cancel button in that row.
- [17/NEW] **Export proposes ".wav" whatever format is remembered**: the name is always `session.name + ".wav"` (App/EditorWindowController.swift:830), but the format is remembered (App/EditorWindowController.swift:1126). The extension is then swapped after the panel closes (App/EditorWindowController.swift:835). So the panel's "Replace?" check is about X.wav, while X.mp3 is written and overwritten without asking. High. Fix: start with the remembered format's extension and update the name field when the format changes, as `TimelineFormatChooser` does.
- [11/13] **Clone Voice: Send is enabled before the form is complete, and the typed name is lost**: Send is enabled while "Whose voice" is still "Choose…" and "adult" is unticked (App/Overdub.swift:99-102). It then fails with `notAttested` or `notAdult` (Packages/JammerKit/Sources/JammerSpeech/OverdubService.swift:18-19) after the alert has closed, so the name is gone. A missing ElevenLabs key is also only reported after the form is filled (App/Overdub.swift:15). Medium. Fix: keep Send disabled with a reason line until the form is valid, and check for the key before showing the alert.
- [11] **Overdub: edited replacement text is lost on failure**: on a network error, a 401 or similar, the text typed in the alert is discarded, and the next attempt starts again from the transcript words (App/Overdub.swift:137, 158-159). Medium. Fix: keep the last unsent text for that selection and pre-fill it.
- [12] **Clone and Overdub requests can't be stopped**: the `Task` is never stored and the status line only says "working" (App/Overdub.swift:68, 121, 154). Medium. Fix: store the task and offer Stop in the status line.
- [NEW] **Overdub and Clone alerts don't focus their text field**: no `initialFirstResponder` is set (App/Overdub.swift:96-104, 142-150), while Set Tempo does it (App/EditorWindowController.swift:705). The overdub text is also a single-line `NSTextField` drawn 60 pt tall (App/Overdub.swift:136). Medium. Fix: set `initialFirstResponder` and use a wrapping field.
- [18] **Restore sliders have no editable value field**: Amount and Sensitivity show their value only as a read-only label (App/RestoreSheet.swift:141-144, 162-165). Medium. Fix: replace the label with a small number field that takes arrow keys (⇧ for bigger steps).
- [9/12] **Restore preview: no progress, can't be stopped, can be started twice**: while up to 30 s renders, the button still says "Preview" and nothing shows progress. A second click starts a second render (App/RestoreSheet.swift:56-68, 171-172). Medium. Fix: show "Rendering…" with a Stop button and store the task.
- [NEW] **History window outlives its document**: closing the document closes Mixer and Picture but not History (App/EditorWindowController.swift:160, 523). The `windows` dictionary also keeps the closed session alive (App/HistoryPanel.swift:9, 21), so clicking a step jumps in a closed document. Medium. Fix: close and remove the panel in `windowWillClose`.
- [9] **History panel has no empty state and doesn't follow the current step**: with no history the list is simply blank (App/HistoryPanel.swift:40, 59). It never scrolls to the current step, and its title doesn't change after Save As (App/HistoryPanel.swift:16). Low. Fix: add an empty-state line, use `ScrollViewReader` to scroll to the current step, and update the title.
- [NEW] **Settings › Models › Remove deletes a large download without asking**: one click deletes it, with no confirmation and no undo (App/SettingsWindow.swift:173). Remove Key works the same way (App/UnknownPrice.swift:114, 125). Medium. Fix: ask first, saying the size that will have to be downloaded again.
- [9] **Storage scans on the main thread with no progress**: on open it reads every recent package and decodes its full history synchronously (App/Storage.swift:182, 13-19). There is no Refresh button, Esc doesn't close the window (plain `NSWindow`, App/Storage.swift:87), and file rows have no Show in Finder or context menu (App/Storage.swift:163-176). Medium. Fix: scan in the background with a spinner, add Refresh, use `EscClosingWindow`, and add Reveal in Finder per row.
- [17] **Batch window forgets the output folder, format and recipe**: output starts as `nil` and the format as MP3 every launch (App/Batch.swift:139-141). Only a count of chosen files is shown, not the files (App/Batch.swift:241). Files can't be dropped on the window. Medium. Fix: keep these in UserDefaults (the folder as a bookmark), list the files, and accept dropped files.
- [17] **Transcript and timeline export formats aren't remembered**: they always start at TXT and OTIO (App/EditorWindowController.swift:792, 878). No save panel sets `directoryURL`, so all panels share the system's single last folder. Low. Fix: remember the format and folder for each kind of export.
- [9/12] **Audio export can't be cancelled and shows progress only as text**: progress appears as a percentage in the status line and the task isn't kept (App/EditorWindowController.swift:844-848). Medium. Fix: show a progress bar with a Stop button.
- [11] **A typed API key can be lost**: the ElevenLabs key field is cleared and marked saved without checking that the Keychain write worked (App/UnknownPrice.swift:168-170). Berget does check (App/UnknownPrice.swift:162). Low. Fix: check `Keychain.get` before clearing the field.
- [NEW] **Settings window is not a standard Mac settings window**: tabs are a SwiftUI `TabView` rather than toolbar panes, the title stays "Settings" instead of the pane name, and the frame isn't autosaved (App/SettingsWindow.swift:24-30, 232). Agents › Add uses an app-modal `runModal` (App/SettingsWindow.swift:220). Low. Fix: use a toolbar-style tab view, set the title to the pane name, and use `beginSheetModal`.
- [3] **Custom neon buttons lack Mac button behaviour**: `NeonButtonStyle` has no hover state and no visible focus ring. The splash's default Close button doesn't look like a default button (App/AgentSplashView.swift:89-98, 75-77). Low. Fix: draw a focus ring (`focusable` plus a focus-state overlay) and a hover tint.
- [NEW] **Voice-profile consent rows are not a real radio group**: they are plain-style buttons, so arrow keys don't move between them (App/VoiceProfiles.swift:138-151). Changing the speaker doesn't refresh the proposed name (App/VoiceProfiles.swift:128). Low. Fix: support arrow keys and refresh the name when the speaker changes.
- [NEW] **Flimmer sheet: Return does nothing once sending is done**: in the done stage, Close only has `.cancelAction` (App/FlimmerSendSheet.swift:242), although the log comment says Return closes it. Low. Fix: make Close the default action in that stage.
- [NEW] **Picture window keeps no film aspect**: there is no `contentAspectRatio`, so resizing leaves black bars (App/EditorWindowController.swift:548-563). Choose Film… is app-modal (App/PictureWindow.swift:189). Low. Fix: set the aspect ratio from the film and use a sheet.

Already good: cancelling Restore, Model download or Voice Profile leaves no undo steps; Flimmer's Cancel stops render and upload and cleans up on the server; Picture and Mixer windows autosave their frames. The splash glow respects Reduce Motion (App/PulsingGlow.swift:71) and the voice-profile name field gets focus. Export remembers the audio format and offers selection-only export.


## Menus and context menus

- [21 / 8] **There are no context menus anywhere.** No Swift file in App/ has `menu(for:)`, `rightMouseDown`, `.contextMenu` or an `NSMenu` outside `buildMenu()` (JammerApp.swift:192-391). Right-clicking the waveform, a clip, a track, a marker, an automation point or a mixer strip does nothing. In the transcript, right-click gives only NSTextView's text menu (Copy, Look Up, Services), with no word commands. High. Fix: build context menus from the same `item`/`op` factory as `buildMenu`, so names, shortcuts and `validateMenuItem` are shared.

- [21 / 13] **⌘K is a separate, much shorter list.** CommandPalette.swift:18-63 has about 16 hand-written commands plus `MenuPresets` (JammerApp.swift:15-30), which repeats the Audio menu's ops (JammerApp.swift:264-276) and adds Gain ±6 dB, which the menu doesn't have. ⌘K can't find Find Speakers, Separate Stems, Add Marker, Duck, Show Spectrogram, Import Tracks, Save or the loudness presets. Its shortcuts are typed in by hand ("↩", Space, "⌥⌘L"), so they can drift from the menu, and `PaletteCommand` has no enabled state or reason. Fade In with no selection shows up, runs, and fails with a beep. High. Fix: build the palette by walking `NSApp.mainMenu` (or one shared command registry), reading `keyEquivalent` and the validation result.

- [13] **Disabled menu items never say why.** `validateMenuItem` (EditorWindowController.swift:904-983) returns false and never sets a tooltip or explanation. Examples: Heal or Attenuate Area needs the spectrogram and an area (911-913); Send to Flimmer (944); Binaural needs more than two channels (957); Clone Voice needs a selection and a transcript (964); the transcribe items go grey while a job runs (948). High. Fix: have validation return a reason, put it in `item.toolTip`, and show it greyed in ⌘K.

- [16] **⌥⌘M clashes with the system.** ⌥⌘M is Minimize All, but here it is Add Marker (JammerApp.swift:289). A Mac user pressing it adds a marker to the document instead. Medium. Fix: move Add Marker to M on the timeline, or to ⌃M or ⇧⌘M.

- [16] **⌘= doesn't zoom in on a US keyboard.** Zoom In is bound to "+" (JammerApp.swift:364). On a US layout that needs ⇧, and ⌘= does nothing. Medium for English users. Fix: add a hidden alternate item bound to ⌘=.

- [7] **Undo names don't match the command that was chosen.** `perform` names the step `L10n.operation(op)` (EditorSession.swift:571). "Gain +1 dB" becomes "Undo Change Gain", any loudness preset becomes "Undo Loudness Preset", and "Normalize to −16 LUFS" becomes "Undo Normalize". Medium. Fix: pass the menu item's title (or the preset's title) as the action name.

- [8 / NEW] **Edit › Delete and Cut are grey while words are selected.** In the transcript, ⌫ deletes the selected words (TranscriptView.swift:410), but the menu items send `delete:`/`cut:` to the read-only NSTextView, which disables them (JammerApp.swift:255-258). Medium. Fix: have TranscriptTextView handle `delete:`, `cut:` and `copy:` itself, routed to `deleteSelectedWords`.

- [NEW] **Markers can't be touched.** They are only drawn (TimelineView.swift:472-486); `mouseDown` (579) never checks for a marker. `remove_marker` (Operations.swift:375) has no menu item, and there is no Next/Previous Marker. Medium. Fix: add Transport › Next/Previous Marker and a marker context menu (Rename, Delete, Select Region).

- [NEW] **Several operations exist only for the agent.** No menu or ⌘K entry calls `correct_word` (Operations.swift:393), `deselect` (206), `go_to_timecode` (213), `set_timecode` (371) or `remove_tempo_change` (409). A Mac user expects Edit › Deselect All (⇧⌘A) in particular. Medium. Fix: add them to the menus and to the word and selection context menus.

- [NEW] **The Transport menu is thin.** It has only Play and Go to Start (JammerApp.swift:340-344). Return, Home, End and the arrow keys work (TimelineView.swift:682-690), but no menu item lists them: Go to Start shows no shortcut, and Go to End doesn't exist. Low. Fix: add Go to End and nudge items, and show the real keys.

- [NEW] **No Help item.** The Help menu (JammerApp.swift:384-388) has no "Jämmer Help" on ⌘? pointing to site/manual, although the manual exists. Medium. Fix: add a ⌘? item that opens the manual in the user's language.

- [NEW] **File menu differs from Mac habits.** JammerDocument doesn't override `autosavesInPlace`, so it is off, yet ⇧⌘S is Duplicate and there is no Save As… (JammerApp.swift:237-238). Low. Fix: use Save As… on ⇧⌘S, or turn on autosave in place and add Rename and Move To.

- [NEW] **Ellipses on items that just open a window.** Mixer…, Plugins…, Picture…, Storage… and Batch… (JammerApp.swift:247-249, 319-321) ask for nothing more. Low. Fix: drop the "…".

- [NEW] **Small toggle and shortcut gaps.**
  - Show History never changes to Hide History; `validateMenuItem` doesn't handle it.
  - Show Assistant switches between three titles (929), which reads oddly.
  - Edit › Delete shows no ⌫ (JammerApp.swift:258).

  Low. Fix: give every view toggle a Show/Hide pair and show ⌫ on Delete.

- [14] **Done well:** view modes (spectrogram, lanes, binaural) are not undo steps. Clearing the selection is not one either: `run` commits only when the project actually changed (EditorSession.swift:545).

**Already good:**
- The standard Mac shortcuts are right: ⌘H, ⌥⌘H, ⌘M and ⌃⌘F (Full Screen), nothing uses ⌘`, and Window and Help are set as `windowsMenu` and `helpMenu`.
- Toggle items change title or tick correctly (Play/Stop, Spectrogram/Waveform, transcript, layout, automation lanes). Undo and redo follow the history tree and each change is one step with a name (`separateStep`), and Save is renamed "Save Back to…" for linked documents.
- Menu titles all come from L10n in both languages. Config/menus-en.txt is checked against the running app (scripts/ax-audit.sh:101-114).
