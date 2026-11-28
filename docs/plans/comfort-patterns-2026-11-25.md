## Jämmer against COMFORT.md (read-only, HEAD ce38c13)

I read the code and searched it. I ran nothing. Paths are from the repository's root; ETC is App/EditorWindowController.swift and ES is App/EditorSession.swift. **Row 60 is wrong in every paid alert**: Send is the first button, so it is Return.

| # | Pattern | Status | Evidence | What to do |
|---|---|---|---|---|
| 1 | Pointer shows what a press does | wrong | no NSCursor/pointerStyle anywhere in App | Cursor from the same zones as the press |
| 2 | Visible handles | wrong | none exist | Trim/fade/selection-edge handles |
| 3 | No unexpected invisible zones | ok | AutomationLanesView.swift:485 (8 pt, only round drawn points, only with a lane shown) | |
| 4 | Context menus from the registry | fixed (partial) | TimelineView.swift:721; TranscriptView.swift:450 | Track header, mixer strip, clip |
| 5 | ⌘K reaches everything | fixed | Commands.swift | |
| 6 | Disabled says why | fixed | ETC:917 | |
| 7 | Every wait can be stopped | wrong | no cancel in the window | Stop per job in the status line |
| 8 | Typed text never lost | wrong | Omnibar.swift:109; Overdub.swift:136 | Keep drafts |
| 9 | Slider drag one step, even with a pause | wrong | PluginsView.swift:256-262 (commits 600 ms after the last change); mixer ok MixerView.swift:208 | Commit on mouse-up or window close, not a timer |
| 10 | Cancelled dialog, no steps | ok | ETC:256; RestoreSheet.swift:184 | |
| 11 | View mode never a step | ok | Commands.swift:31; ETC:25,325 | |
| 12 | Repeated arrow keys one step | wrong | AutomationLanesView.swift:688-700 (each press sends set_automation) | Merge repeated nudges into one step |
| 13 | Results after a wait are their own steps | ok | UndoSteps.swift:10; ES:419,427; Jobs.swift:279 | |
| 14 | No shortcut clashes | fixed | Commands.swift:262 | |
| 15 | A tool doesn't take another's | ok | TimelineView.swift:582 (spectral tool never takes automation points) | |
| 16 | Save/Export name and extension | wrong | ETC:832 always ".wav"; 835 swaps it silently | Follow ExportChoices.choice and remember it |
| 17 | Number fields and value fields | wrong | MixerView.swift:216 (text only); ETC:244 | Editable value field next to sliders |
| 18 | Values shown while dragging | ok | MixerView.swift:216; AutomationLanesView.swift:553 | |
| 19 | Search forgives typos/accents | wrong | CommandSearch.swift:105 (accents only) | Typo tolerance |
| 20 | No English leaking | ok | (table) | |
| 21 | Hover and pointing hand | wrong | no onHover in App | Hover on clickables |
| 22 | Drag and drop, files anywhere | wrong | no registerForDraggedTypes in App | Window-wide file drop |
| 23 | Focus doesn't jump | wrong | TimelineView.swift:580 | Don't take focus from fields |
| 24 | Reduce Motion | ok | PulsingGlow.swift:71 | |
| 25 | Panels from the menu bar | fixed | ce38c13 | |
| 26 | Delete works in every panel | wrong | MixerView (button only), HistoryPanel | Delete removes the strip/bus |
| 27 | Dialogs remember values; focus first field | wrong | ETC:244 ("4000/8000/-20"), 603 ("-1") | Remember last values; first responder |
| 28 | Meters | wrong | MixerView | Peak meters with clip light |
| 29 | Trackpad | ok | TimelineView.swift:663-675 | |
| 30 | Named, translated undo steps | ok | ES:572 | |
| 31 | One history per window | ok | ETC:1228; PictureWindow.swift:202 (document's UndoManager everywhere) | |
| 32 | Action on many is one step | ok | AutomationLanesView.swift:688; TranscriptView.swift:295; ETC:203 | |
| 33 | Cut/Copy/Paste on everything selectable | wrong | Commands.swift:124-126 (no points/area); paste goes to the playhead, not the click | Copy/paste points; "Paste here" |
| 34 | Lists by keyboard | wrong | HistoryPanel.swift:59 (List without selection) | Selectable List |
| 35 | Arrows nudge, Tab moves between | wrong | TimelineView.swift:690 (arrows = playhead; clips not nudgeable) | Nudge clips |
| 36 | Mode commands in the menu bar | wrong | AutomationLanesView.swift:630-660 (⌥Return, ⌥→, ⌥Tab only as keys) | Automation menu items |
| 37 | One context menu per object | wrong | TimelineView.swift:722 (.clip context never used; points get the timeline menu) | Menu by object under the pointer |
| 38 | Click selects, double-click/Return opens | wrong | HistoryPanel.swift:60 (single click jumps) | Select, then Return/double-click |
| 39 | Same operation, same code path | wrong | ETC:264 commits directly; the agent uses op spectral_attenuate (Commands.swift:208) | Go through perform() |
| 40 | Zoom/⌘F to the front view | ok | Commands.swift:130,152 (read-only transcript, so Replace n/a) | |
| 41 | Esc cancels gestures | wrong | TimelineView.swift:685 clears, then 634 re-sets from dragAnchor; automation drag 528 | Esc restores the pre-drag state |
| 42 | Esc closes every sheet | wrong | ETC:592 and TranscriptView.swift:369 (OK-only NSAlert); PluginsView.swift:123 and LinkedWaiting.swift:73 (defaultAction only) | Escape on OK/Done |
| 43 | Esc in a field drops the draft | ok | Omnibar.swift:167 | |
| 44 | Window keys don't steal from fields | ok | ETC:1234 (window keyDown last) | |
| 45 | Pointer never sticks | ok | nothing is set yet | |
| 46 | Painted buttons get pointer/hover/help | wrong | track headers painted | Tracking areas plus help |
| 47 | Locks visible before the attempt | wrong | ES:340-345 (frozen refused with a beep after trying) | Badge on the track; no drag |
| 48 | Forbidden drop shows during drag | n/a | no drop targets yet (see 22) | |
| 49 | Loading / empty / error distinct | wrong | PluginsView.swift:62 ("Looking…" also when none found) | Three states |
| 50 | Error has Try Again | wrong | ES:37 (status only); Jobs.swift:281 | Retry with the same choices |
| 51 | Unknown progress is indeterminate | wrong | ETC:1101 (always "n %") | Spinner when there's no progress |
| 52 | Network button reacts, one click | wrong | TranscriptView.swift:315 (model fetch, button stays enabled) | Disable and show a spinner |
| 53 | Server order / rollback | n/a | local documents | |
| 54 | Server refusal rolls back | n/a | same | |
| 55 | Receipts alike, fade by themselves | wrong | ES:37 (status stays) | Timed receipts |
| 56 | Out-of-sight change gives a notice | wrong | Jobs → session.status of that window only | Notice with a way there |
| 57 | Unsaved forms survive switches | n/a | no tabbed forms with drafts | |
| 58 | Typed field never silently filled | ok | Overdub.swift:137 (prefilled only at open) | |
| 59 | Paid results kept | ok | ES:351 (history tree keeps branches) | |
| 60 | Return never costly/destructive | **wrong** | Send is the first button, so Return: Overdub.swift:99 (Clone) and :145 (Overdub); TranscriptView.swift:344 (Berget, always enabled) and :402 (OpenAI, once ticked); Batch.swift:174; AssistantPanel.swift:391. Delete Cloned Voice Overdub.swift:174 also Return. UnknownPrice.swift:88 only greys Send when the price is unknown | Send gets keyEquivalent "", Cancel gets "\r" |
| 61 | One-time content survives Return | ok | AgentSplashView.swift:77; reopened from Help (JammerApp.swift:152) | |
| 62 | Shortcut panel focuses its field | ok | AssistantPanel.swift:509; TranscriptView.swift:303 | |
| 63 | Same newline/send key | wrong | Overdub.swift:136 (60 pt field; Return sends the paid alert) | Multi-line field, ⌘Return sends |
| 64 | Autocomplete follows pointer, says no match | wrong | Omnibar.swift:130-145 (hover doesn't move the chosen row) | Hover sets chosen |
| 65 | Double-click/⌥-click resets a slider | wrong | MixerView.swift:208,459,492 | Reset to default as a named step |
| 66 | Space plays in every player and sheet | **wrong** | RestoreSheet.swift:175 (no Space; it presses the focused button). OK in timeline, transcript, mixer, picture | Space toggles the preview |
| 67 | Persistent listening modes visible | ok | ETC:969; ES:620 | |
| 68 | Panels remember per document; Settings tab | wrong (minor) | ETC:56,75 (global); tab ok ETC:762 | Per document |
| 69 | Images retry | n/a | no remote images | |
| 70 | Save panels as sheets; folder per kind | wrong | ETC:828-835 (no directoryURL) | Folder per export kind |
| 71 | Open panel also takes Finder drops | wrong | ETC:178; PictureWindow.swift:185 | Drop targets |
| 72 | Deletes ask the same way | ok | Overdub.swift:171 | |
| 73 | Copy button for an id | ok | AgentSplashView.swift:53 | |
| 74 | Autoscroll near edge | wrong (partial) | ok TimelineView.swift:632; missing for points AutomationLanesView.swift:528 | Autoscroll point drags |
| 75 | Small objects leave room for handles | n/a | no handles yet | |
| 76 | Snap haptics | wrong | AutomationLanesView.swift:470 | NSHapticFeedbackManager at snap |
| 77 | Late result doesn't take selection or overwrite | wrong | ES:547 (commits end.project even if edited meanwhile; overlapping perform() Tasks can drop one edit), ES:558 (selection = end.selection); ETC:264 commits an old snapshot | Check project == start; leave the selection alone |

### The 8 "wrong" rows a user would notice first
1. **#2 handles**: the first fade or trim the user tries.
2. **#1 pointer**: it never changes anywhere.
3. **#22 file drop**: dropping a file on the window does nothing at the first import.
4. **#66 Space in the Restore sheet**: the first repair preview doesn't play.
5. **#60 Return in paid alerts**: Return pays. In Overdub, Return in the text field sends.
6. **#16 export name**: always ".wav", whatever format is picked.
7. **#41 Esc mid-drag**: it doesn't cancel.
8. **#12 arrow nudges**: holding ↑ on an automation point fills the undo history.
