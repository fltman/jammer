# Swedish in Jämmer: plan, word list and what is built (2026-11-17)

The rule is the series' (the-apps/SIBLINGS.md, "Språk"): English and Swedish in the interface, the texts in a string catalogue, no text a user sees written straight in the code; the agent API's exact words and what a model itself writes are not translated; the catalogue check tells `%1$@` from `%@`; every state is looked at as a picture in both languages. Sites and manuals stay English first.

## Built 2026-11-17 (block C): the Swedish is in, behind a start argument

Jämmer still starts in English whatever the Mac's language is; Swedish only with `-language sv` (`JAMMER_LANG=sv scripts/with-app.sh …`), until Anders has seen it. `scripts/test-language-switch.sh` (in the pre-commit check) starts the debug build without a window on a Mac said to be Swedish, Swedish and English, German and English, and gets English each time, and Swedish only with the argument.

- **The catalogue:** 888 texts, each with English and Swedish; the pre-commit check runs `check-strings.py --require sv`. Every file of the app whose texts are all in the catalogue is on `scripts/l10n-moved.txt` (the check fails on a text written in such a file).
- **Counts** by the catalogue's plural forms (34): no sentence is made by adding a letter.
- **Values are text:** `L10n.text` takes strings, so the compiler refuses a number handed to a `%@`; the check refuses a number placeholder anywhere but in a count.
- **The operations' titles** (menus, ⌘K, the assistant's plan, the undo names) by name, `L10n.operation(name)` → `op.<name>.title`; the check holds each entry's English to the schema's title, so the window and the API name an operation the same way. The API's `title` stays English.
- **The packages' typed errors** (21 types, 69 sentences) carry a key and their values (`KeyedMessage`); a failed step hands the key to the window, which says it in its language, while the API says the English words as before. The check holds each key's English to the error's own `errorDescription`.
- **The assistant's conversation** (its notes, what it reports after running a plan, its measurements) is in the language of the question, as the held-back note already was: a Swedish question gets Swedish lines in an English window. Short questions whose language can't be told get the window's.
- **The GUI scripts** find menus and texts by key (`scripts/l10n.sh`); the accessibility audit runs in either language. Run 2026-11-17 in both: 13 states each, all filled, no control without a name, nothing crashed.
- **Numbers follow the Mac's region** (Anders, 2026-11-17), in either language, as macOS does: a Swedish region writes 0,3 and a US region 0.3, through `L10n.number`. The switch test checks both. Not changed: the time readouts (0:07.480) and the fields where a time is typed, which are read back with a point.
- **Seen as pictures in both languages** (2026-11-17): the document window, the mixer, Plugins, Duck Under Speech, Repair, the command palette. Everything fits; the mixer is cut on the right in both languages when its window has been made narrow, because its description line doesn't wrap (a layout fault of the mixer, not of the language).

**Still English in a Swedish window** (each is a message made where it is thrown, from parts, in the packages):
- a failed step whose reason is written in the step itself rather than by a typed error (about 140 in `JammerAgent/Operations.swift`; most can only be reached through the API, since the menus send valid steps);
- the cases of typed errors that carry a message made at the throw (`badValue(String)`, `PluginError.failed`, the limiter's three, export's `unsupported`, `AudioFileError`);
- reports built in the packages: the ACX report's lines, Separate Stems' summary, the spectral area's status, a plugin host's own words when it dies;
- the API's own answers and anything a model writes, as the rule says.

These move as they are rewritten into typed errors; matching on English words (the earlier plan's second way) is not used.

## The foundation, built 2026-11-17 (before the Swedish)

- **The catalogue:** `App/Localizable.xcstrings`, English as the source, built into the app by Xcode (the project is generated again by the pre-commit check, so a new file can't be left out).
- **The lookup:** `L10n.text(key, values…)` and `L10n.count(key, n)` (`App/L10n.swift`).
- **The pattern, on the three hard kinds**, in the mixer sheet's automation lines: a count through the catalogue's plural forms ("1 point", "2 points": seen in the app from the compiled catalogue), a phrase with two values as `%1$@` and `%2$@`, and sentences that used to be glued from halves as whole entries with the other part as a value ("%@ (for every strip in the group)"). Eleven keys.
- **The check** (`scripts/check-strings.py`, in the pre-commit check, after its own self-test): every key has English; one text never mixes `%1$@` and `%@`, and numbers its placeholders when it has more than one; a translation has the source's placeholders written the same way (`%1$@` is not `%@`); a count has the forms `one` and `other` with exactly one number and nothing else; every key the code asks for exists, counts are asked for as counts, and no key is unused; and a file listed in `scripts/l10n-moved.txt` has no text for the user written in its code. The self-test plants twelve kinds of fault and fails unless each is caught. `--require sv` adds "every key has Swedish" the day the words are chosen.
- **The test copy's language** is set on its start line (`JAMMER_LANG=sv scripts/with-app.sh …`, English otherwise), never from the Mac's settings. `scripts/l10n.sh <key> [en|sv]` prints a key's text for GUI scripts.
- (What was not done here was done the same day: see the section above.)

## How much there is (counted roughly in the code, 2026-11-17)

| Where | Texts | Of them built with values | Translated? |
|---|---|---|---|
| The app (`App/`, 28 files): menus, sheets, panels, status line, alerts, tooltips, accessibility labels | about 790 | about 140 | yes |
| Operation titles, which the menus and ⌘K take from the one schema (`Operations`) | about 75 | none | yes, as titles in the window; the API's `title` stays English |
| Errors, refusals and notes written in the packages and shown in the app (`JammerCore` about 280 literals, `JammerPlugins` 30, speech, stems and the rest about 60) | about 370 | about 150 | yes, where the app shows them |
| The assistant's own canned sentences (the clarifying question, the refusals, "held back", "left out") | about 20 | a few | yes; today they are written twice in the code, by hand |
| The agent API: operation and parameter descriptions, error messages, the guide (`JammerAgent`, about 570 literals) | | | no |
| The assistant's instructions to a model, and what a model writes | | | no |

So about 1 250 texts to translate, about 300 of them with values in them.

## The parts that need thought

1. **Texts built from parts.** Three kinds, each with its own answer:
   - A value in a sentence ("Limited: true peak now %.2f dBTP, at most %.1f dB taken off, over %.1f s."): one catalogue entry with numbered placeholders, so that Swedish can put them in another order.
   - A plural ("1 point" / "4 points", "was" / "were"): written today as `count == 1 ? "" : "s"` in about 60 places. Each becomes one entry with the catalogue's plural variations; none is built by adding a letter.
   - A sentence glued from halves (a base text plus " The plugins on the tracks and buses come after it."; a list joined with "; "): each half is a whole sentence of its own in the catalogue, and the join stays in code. Where the halves aren't whole sentences today (about 15 places, most in the status line and the mixer's "heard" line), the text is rewritten so that they are.
2. **The packages' messages.** The packages are also what the agent API answers with, and those words must not change. So the packages keep writing English, and each message that the app shows gets a catalogue entry whose key is the message's fixed words with its values as placeholders. The app finds the entry for a message by its fixed words (Glimmer's way) and fills in the values from the message itself; a message with no entry is shown in English, and a debug build logs it, so that a new message can't hide untranslated. A test walks every error type the packages can throw (they are enums with `errorDescription`) and fails if one has no entry.
   The better way where it is cheap: errors that already carry their values as an enum's associated values (`Mixer.Failure`, `Automation.Failure`, `FreezeError`, `DuckError`, `EditError`, about 25 types) get a `key` and `arguments` beside `errorDescription`, and the app formats from those; no matching on words. Matching on words is then only for the texts that are built as free strings (the project-safety notes, the plugin scanner's verdicts).
3. **The operation titles.** `Operations` stays English (it is the API). The app has a catalogue entry per operation name (`op.limit.title`), and the menu, ⌘K and the undo names ("Undo Limit") take the title from there. A test fails when an operation has no entry.
4. **The assistant.** Its canned sentences move into the catalogue and choose their language as now, from the request (a Swedish question gets a Swedish answer in an English interface, which is what the rule on the model's language already says). The words that trigger actions (`onDeviceWhenNamed`, the mute and freeze words) are not interface text and stay where they are.
5. **How the GUI scripts find things.** Today the scripts press menus by their English titles (about 70 lines) and read texts by their English words (about 40). After this:
   - controls are found by accessibility id (20 have one today; every control a script touches gets one, the rule that already stands);
   - menus are pressed by a key, not a title: a small tool beside the scripts (`scripts/l10n.sh <key> [sv|en]`) prints the catalogue's text for a key in the language the test copy was started in, and `menu` in the scripts' library takes keys;
   - the test copy's language is set on its start line (`-AppleLanguages "(sv)"`), never from the Mac's settings, so both languages can be run on one Mac;
   - what a script *reads* to check a result is a value or an id, not a sentence, wherever that can be.
6. **The check on the catalogue** (in the pre-commit check): every key has both languages; the placeholders of a translation are the same set as the source's, with `%1$@` and `%@` told apart and never mixed in one entry; no entry's Swedish is identical to its English unless it is on a short list of words that are the same (dB, LUFS, OK, Master); and no user-facing text literal is left in `App/` (a list of the calls that take one, grepped for a literal argument).
7. **Pictures.** Each sheet, panel and menu is photographed in both languages (the test copy's own windows, as now). Swedish words are longer: the mixer sheet's fixed widths (150 for a name, 72 for a level) and the status line are where I expect it to show.

## Order

1. The catalogue, the check, `-AppleLanguages` in the start script and `l10n.sh`; one sheet moved over (the mixer) as the pattern, seen in both languages.
2. The menus and operation titles.
3. The rest of the app, file by file, each seen in both languages.
4. The packages' messages: the typed errors first, then the free strings by matching.
5. The assistant's own sentences.
6. The manual gets a line on languages; the site stays English.

## Word list for Anders (second round, 2026-11-17; nothing is used until he has seen it, then it is locked)

Anders chose the English word in all four open cases (Sidechain, Lookahead, Bounce, Loudness), and the series rule now says: a term of the trade that is said in English in a Swedish studio stays English in the Swedish interface. The list was gone through again in that light. **Changed** marks a row that differs from the first round; the old proposal stands struck in the last column. Words that really are said in Swedish are kept.

How an English term is written in Swedish text: unchanged, with a capital only where Swedish would have one (the start of a label or menu item: "Sidechain", "Release"; inside a sentence: "sidechain", "release"). It is not given Swedish verb endings: the menu says "Bounce", a sentence says "gör en bounce", never "bouncea". Units and standard names are never translated (dB, LUFS, dBTP, Hz, BPM, EBU R 128).

| English | Swedish | Note |
|---|---|---|
| track | spår | |
| clip | klipp | |
| bus | buss | |
| send | **send (en send, flera sends)** | **Changed.** ~~sändning~~: "send" is what is said at a desk |
| master | master | |
| fader | **fader** | **Changed.** ~~regel~~: "fader" is what is said |
| level | nivå | |
| pan | panorering ("Pan": Panorera; centre: Mitten) | kept: "panorera" is said in Swedish |
| mute | tysta ("Muted": Tystad) | kept |
| solo | solo | |
| strip (a track, a bus, the master or a VCA group in the mixer) | kanal | added 2026-11-17: what is said at a desk ("kanalremsa" is the full form; "remsa" alone sounds translated) |
| VCA group | VCA-grupp | |
| plugin | plugin (en plugin, flera pluginer) | |
| insert | the word isn't shown; a plugin on a strip is just "plugin" | |
| sidechain | **sidechain** | **Changed** (Anders). ~~sidokedja~~ |
| key (of a sidechain) | **key ("Key")** | **Changed.** ~~nyckel~~, which also collides with API-nyckel |
| threshold | tröskel | kept |
| limiter | limiter (en limiter) | |
| ceiling | tak | kept |
| attack, release, hold | **attack, release, hold** | **Changed.** ~~släpptid~~ |
| lookahead | **lookahead** | **Changed** (Anders). ~~framförhållning~~ |
| compressor, gate | kompressor, gate | |
| freeze, frozen, unfreeze | frysa, fryst, tina | kept |
| bounce | **bounce ("Bounce"; "gör en bounce")** | **Changed** (Anders). ~~studsa~~ |
| automation, lane, point | automation, bana, punkt | |
| latency, delay compensation | latens, fördröjningskompensation | |
| loudness | **loudness ("Loudness")** | **Changed** (Anders). ~~hörnivå~~ |
| true peak | **true peak ("True Peak")** | **Changed.** ~~sann toppnivå~~: the standard's own name, like LUFS |
| normalize | normalisera | |
| fade in, fade out | tona in, tona ut | kept |
| crossfade | övertoning | kept; "crossfade" is also said. One for Anders to look at |
| gain | **gain** | **Changed.** ~~förstärkning~~ |
| noise, hum, click | brus, brum, klick | kept |
| clipping | överstyrning | kept: it is the Swedish word and it is said |
| reverb | **reverb** | **Changed.** ~~efterklang~~: "reverb" is what is said; "efterklang" is the room's, in acoustics |
| repair (Restore) | reparera | |
| de-bleed | ta bort överhörning | |
| duck (under speech) | ducka (under tal) | kept: it is already the English word with the ending everyone uses |
| stem, stems | **stem, stems** | **Changed.** ~~stam, stammar~~ |
| transcript, transcribe | transkription, transkribera | |
| speaker (in a conversation) | talare | |
| filler word | utfyllnadsord | |
| marker, region | markör, område | |
| selection, playhead | markering, spelhuvud | |
| tempo, beat, bar, time signature | tempo, slag, takt, taktart | |
| sample rate, bit depth | samplingsfrekvens, bitdjup | |
| export, batch | exportera, batch (Batchkörning) | |
| undo, redo | ångra, gör om | |
| Safe Mode (plugins) | säkert läge | |
| scan (for plugins) | söka efter pluginer | |
| storage, Trash | lagring, papperskorgen | |
| assistant | assistent | |
| agent (API) | agent | |
| on this Mac / on device | på den här Macen | |
| Requested by Flimmer | Begärt av Flimmer | the API's words stay English in both languages |
| timeline (a file of one) | tidslinje | added 2026-11-17 (block F); already used in "Tidslinjen kunde inte importeras" |
| frame rate, fps | bildfrekvens, bilder/s | added 2026-11-17 (block F), for Anders to look at |
| drop-frame | drop-frame | added 2026-11-17 (block F): the trade's English term, as the rule says |
| edit decision list, EDL | redigeringslista, EDL | added 2026-11-17 (block F), for Anders to look at |

## Rules added 2026-11-17 (the series', to be followed when the work gets there)

- **One language at a time until the move is whole.** Jämmer starts wholly in English whatever language the Mac has, until the Swedish is finished and Anders has seen it. Swedish only with a start argument, and a test keeps the switch off.
- **Title Case** on English buttons and menu items.
- **No logic hangs on a text the user sees** (a status line, a title, a message, a default name). Searched 2026-11-17 in the app and the packages: one place did (the Send to Flimmer sheet told a warning by the line's first word) and now goes by a count. `scripts/check-strings.py` fails on a comparison of such a text with a literal (`==`, `hasPrefix`, `hasSuffix`, `contains` on a status, title, message, label or line); a line that compares with something that only looks like a text says so (`// not a shown text: …`). What the check can't see: a comparison through a variable, and the GUI scripts, which still find menus and read results by their English words (about 70 and 40 lines; they move to keys and ids with the texts).
- **The English is American**, as Apple's (Color, Center, Gray, Canceled). Changed 2026-11-17 where the window had the British form ("Centre" in the mixer and the lanes, "Cancelled" in the assistant); `scripts/check-strings.py` fails on the British forms in the catalogue's English and in texts in the app's code. Later the same day, on the coordinator's word: the agent API's descriptions and guide, the manual and the FAQ too, and two names in the API (`analysedSeconds` is now `analyzedSeconds`; a stopped job's status is `canceled`), which the check now reads as well. Comments are left as they are. Flimmer's own job word "cancelled" is still understood where Jämmer reads Flimmer's jobs.
- **Apple's words in the menus**, both languages: Radera/Delete where the thing is gone, Ta bort/Remove where it only leaves a list, Göm/Hide.
