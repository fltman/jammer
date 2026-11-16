# Swedish in Jämmer: plan and word list (2026-11-17, nothing built)

The rule is the series' (the-apps/SIBLINGS.md, "Språk"): English and Swedish in the interface, the texts in a string catalogue, no text a user sees written straight in the code; the agent API's exact words and what a model itself writes are not translated; the catalogue check tells `%1$@` from `%@`; every state is looked at as a picture in both languages. Sites and manuals stay English first.

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

## Word list for Anders (proposed; nothing is used until he has seen it)

Where studio Swedish has a word that people who work with sound actually say, that word. Where they say the English one, the English one, written as Swedish (no capital, Swedish endings). Units and standard names are never translated (dB, LUFS, dBTP, Hz, BPM, EBU R 128).

| English | Swedish (proposed) | Alternative, and why not |
|---|---|---|
| track | spår | |
| clip | klipp | |
| bus | buss | |
| send | sändning ("Sends": Sändningar) | "send" is also said; "sändning" reads as Swedish in a menu |
| master | master | "huvudutgång" is longer and nobody says it |
| fader, level | regel, nivå ("Level": Nivå) | "fader" is said too; "regel" is the Swedish word on a mixing desk |
| pan | panorering ("Pan": Panorera; centre: Mitten) | "pan" |
| mute | tysta ("Muted": Tystad) | "mute" |
| solo | solo | |
| VCA group | VCA-grupp | |
| plugin | plugin (en plugin, flera pluginer) | "insticksprogram" is correct and nobody says it |
| insert | plugin on a strip is just "plugin"; the word insert isn't shown | |
| sidechain, key | sidokedja; nyckel ("Key": Nyckel) | "sidechain" is what most say; "sidokedja" is in Swedish manuals. Anders to choose |
| threshold | tröskel | |
| limiter | limiter (en limiter) | "begränsare" is correct and rare |
| ceiling | tak | |
| release | släpptid | "release" |
| lookahead | framförhållning | "lookahead"; unsure, Anders to choose |
| compressor, gate | kompressor, gate | "grind" is not said |
| freeze, frozen, unfreeze | frysa, fryst, tina | |
| bounce | studsa ("Bounce": Studsa ner) | "bounce"; "studsa" is said in Swedish studios, but Anders to choose |
| automation, lane, point | automation, bana, punkt | |
| latency, delay compensation | latens, fördröjningskompensation | |
| loudness | hörnivå ("Loudness": Hörnivå) | "loudness" is what the EBU's Swedish texts also use; "ljudstyrka" means something looser. Anders to choose between hörnivå and loudness |
| true peak | sann toppnivå (true peak) | the English in brackets the first time on a sheet |
| normalize | normalisera | |
| fade in, fade out, crossfade | tona in, tona ut, övertoning | |
| gain | förstärkning | "gain" |
| noise, hum, click, clipping, reverb | brus, brum, klick, överstyrning, efterklang | |
| repair (Restore) | reparera | |
| de-bleed | ta bort överhörning | |
| duck (under speech) | ducka (under tal) | "sänka under tal" is clearer but longer; ducka is said |
| stem, stems | stam, stammar | "stem" |
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
