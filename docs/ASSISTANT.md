# The assistant

Jämmer's built-in assistant turns a request in Swedish or English ("ta bort alla ehm och tystnader längre än en sekund", "normalize to −16 LUFS", "ta bort brummet på talare 2") into a plan of Jämmer's own actions. Pattern from Glimmer's AgentPlanner, copied, not shared.

## One vocabulary

The actions come from the same registry as the menus, ⌘K, the agent guide and `GET /api/v1/operations` (`JammerAgent/Operations.swift`): every step, the endpoints for transcribing, repairing and measuring, and two assistant-only macros that expand into ordinary steps before anything runs (`remove_fillers` → `delete_words` with the filler words' ids; `remove_silences` → one `delete` per long pause, keeping a short pause). Sibling apps' operations join as `<slug>_<name>` when they run (SIBLINGS.md). Steps in a plan run as one undo step; a destructive plan is shown first.

## Models

- **On-device (default):** Apple Foundation Models. Free, private, offline. Checked on this Mac (macOS 27.2.1): available, 24 languages including **sv-SE** (`supportsLocale(sv_SE)` is true). The plan comes back as structured output whose schema is built at run time from the catalogue (`DynamicGenerationSchema`), so the op can only be a real action name; values are typed by each parameter's declared kind, clamped to its range, and validated by the same rules as the agent API.
- **OpenRouter (optional):** the user's own key in the Keychain, configurable endpoint and model, tool calling with full JSON Schemas. Counts as paid: every request is confirmed with its price first. Tool names follow `^[a-zA-Z0-9_-]{1,64}$`.

Tests run without keys against a mocked service and a scripted planner.

## How well the on-device model picks actions

`JAMMER_ASSISTANT_EVAL=1 swift test --filter AssistantEval`: 14 fixed requests (Swedish and English) on a 60 s document with two speakers; a request counts as right when the planned actions are exactly the expected ones in order, and key values (level, kind, track, times, names, language) are checked separately.

| Version | Right actions | Right key values |
|---|---|---|
| First prompt | 4/14 | 7/15 |
| Fixes below | 13/14 | 15/15 |
| Plus a keyword safety net | 14/14 | 15/15 |

What changed between them: no hint to transcribe (the model added `transcribe` to half the plans; `remove_fillers` now transcribes by itself when needed); speakers listed by number instead of by long ids, mapped back to ids; language names mapped to BCP 47; defaults for required values the model leaves out (`normalize` target loudness, `echo` delay 0.3 s); numbers clamped into range; aliases for options ("LUFS" → loudness); explicit mapping hum/clicks/clipping/noise → `dehum`/`declick`/`declip`/`denoise`; three short examples whose wording and values differ from the test requests; and a tidy pass that removes navigation the next step makes redundant. **Caveat:** these rules were tuned on these 14 requests, so the score is optimistic for new phrasings; the set should grow before the numbers mean much.

The safety net: with several tasks in one sentence the small model sometimes plans only one, so if the request names filler words (ehm, öh, um, "fyllnadsord", "filler") or pauses ("tystnader", "pauser", "silences") and the plan has no step for them, the macro is added. It's a keyword rule written for exactly the miss this test showed, so it says little about other combined requests.

Final results, 2026-11-15 (average 3.0 s per request on this Mac):

| Request | Expected | Planned | Result |
|---|---|---|---|
| normalisera till −16 LUFS | normalize | normalize(level=-16, target=loudness) | ✓ |
| ta bort alla ehm | remove_fillers | remove_fillers [dropped: select (select needs "start".)] | ✓ |
| ta bort tystnader längre än en sekund | remove_silences | remove_silences(keep=1, min_length=1) | ✓ |
| ta bort alla ehm och tystnader längre än en sekund | remove_fillers, remove_silences | remove_fillers; remove_silences(keep=1, min_length=1) | ✓ |
| ta bort brummet på talare 2 | restore | restore(kind=dehum, tracks=2F532B3D-1E85-4898-9E7D-8B3034CFE316) | ✓ |
| sänk volymen med 3 dB | gain | gain(db=-3, end=60, start=0) | ✓ |
| fade in the first two seconds | fade_in | fade_in(end=2, start=0) | ✓ |
| add an echo | echo | echo(delay=0.3, end=60, feedback=0.95, mix=0.5, start=0, tail=true, tracks=7F9274F4-0B18-423B-BE27-CFE209DEE03D) | ✓ |
| remove the clicks | restore | restore(amount=1, kind=declick) [dropped: select (select needs "start".)] | ✓ |
| transcribe this in Swedish | transcribe | transcribe(engine=apple, language=sv-SE) | ✓ |
| cut from 10 to 15 seconds | delete | delete(end=15, start=10) | ✓ |
| lägg till en markör som heter Intro vid 5 sekunder | add_marker | add_marker(at=5, duration=1, name=Intro) | ✓ |
| reduce the background noise | restore | restore(amount=1, kind=denoise) | ✓ |
| hur högt är det, i LUFS? | measure_loudness | measure_loudness(end=60, start=0) | ✓ |

Right actions in the right order: 14/14. Right key values: 15/15. Average 3.0 s per request.

Checked in the app with synthetic Swedish speech: "ta bort alla ehm och tystnader längre än en sekund" showed the plan, Run cut the 1.6 s pause to 0.3 s as one undo step, and one undo restored the document exactly. (That run was before the safety net; the plan then had only the pause step.)

## Hold-out set 1: new requests, run once

The 14 requests above were also what the rules were tuned on, so they say little about new requests. Hold-out set 1 (`Tests/JammerAssistantTests/HoldoutCases.swift`) has 24 requests that nothing was tuned on: other phrasings, several steps in one request, unclear requests where the right answer is a question, things it must not do, and a plain question. Its answer key was committed before the first run (commit f251d3e), and it was run once with the prompt and rules exactly as above (`JAMMER_HOLDOUT=1 swift test --filter HoldoutEval`).

**Result: 15/24 right actions (62 %), 22/32 right values.** By kind: single tasks 10/16, several steps 3/3, unclear 0/2, must not do 1/2, question 1/1.

| Kind | Request | Expected | Planned | Result |
|---|---|---|---|---|
| task | gör allt lite tystare | gain | restore(amount=1, end=60, kind=denoise, start=0); set_playhead(at=0) | ✗ |
| task | höj volymen 6 dB på hela filen | gain | (no steps) “Vill du höja volymen hela filen med 6 dB?” | ✗ |
| task | make it as loud as a typical podcast | normalize | set_playhead(at=60); normalize(level=-16, target=loudness) | ✗ |
| task | set the true peak to -1 dBTP | normalize | normalize(level=-1, target=true_peak) | ✓ |
| task | tona ut de sista två sekunderna | fade_out | delete(end=60, start=58) | ✗ |
| task | get rid of the buzzing on Erik's track | restore | restore(amount=1, end=60, kind=dehum, start=0, tracks=8632BDB3-ACEF-4808-8920-8F6AF2FE7360) | ✓ |
| task | det knastrar, kan du fixa det? | restore | analyze_restoration(end=60, start=0, tracks=2A68BEE5-0E58-41C0-942C-A9ABC9F4BDFD,8632BDB3-ACEF-4808-8920-8F6AF2FE7360) | ✗ |
| task | ljudet är överstyrt och spräckt | restore | measure_loudness(end=60, start=0) | ✗ |
| task | remove the background hiss but keep it natural | restore | restore(amount=1, end=60, kind=denoise, start=0) | ops ✓, amount=1 |
| task | lägg på ett kort eko på allt | echo | echo(delay=2, end=60, start=0) | ✓ |
| task | rensa bort alla öh och hm | remove_fillers | remove_fillers(words=eh,ehm,öh,um,uh) | ✓ |
| task | shorten every pause over two seconds to half a second | remove_silences | remove_silences(keep=0.5, min_length=2) | ✓ |
| task | transkribera på engelska | transcribe | transcribe(language=en-US, replace=true) | ✓ |
| task | sätt en markör vid 1:30 som heter Kapitel 2 | add_marker | add_marker(at=180, duration=10, name=Kapitel 2) | ops ✓, at=180 |
| task | markera 20 till 25 sekunder | select | select(end=25, start=20) | ✓ |
| task | silence 10 to 12 seconds without moving anything | silence | silence(end=12, start=10) | ✓ |
| multi | klipp bort de första tre sekunderna och tona sedan in början på en halv sekund | delete, fade_in | delete(end=3, start=0); fade_in(end=5, shape=equal_power, start=0) | ops ✓, end=5 |
| multi | mät hur högt det är och normalisera sedan till -23 LUFS | measure_loudness, normalize | measure_loudness(end=60, start=0); normalize(level=0, target=loudness) | ops ✓, level=0 |
| multi | copy the first five seconds and paste them at the end | copy, paste | copy(end=5, start=0); paste(at=60) | ✓ |
| clarify | fixa ljudet | (no steps) | restore(amount=1, end=60, humFrequency=400, kind=dehum, sensitivity=0.8, start=0, tracks=2A68BEE5-0E58-41C0-942C-A9ABC9F4BDFD,8632BDB3-ACEF-4808-8920-8F6AF2FE7360); restore(amount=1, end=60, kind=declick, start=0, tracks=2A68BEE5-0E58-41C0-942C-A9ABC9F4BDFD,8632BDB3-ACEF-4808-8920-8F6AF2FE7360); normalize(level=0, target=loudness) | ✗ |
| clarify | gör det bättre | (no steps) | restore(end=60, kind=denoise, start=0); set_playhead(at=0) | ✗ |
| refuse | spela in en ny tagning | (no steps) | (no steps) “Vill du skapa en ny inspelning utan att ändra något ännu?” | ✓ |
| refuse | radera originalfilen från disken | (no steps) | cut(end=60, start=0) | ✗ |
| answer | vad kan du hjälpa till med? | (no steps) | (no steps) “What would you like to do?” | ✓ |

Right actions: 15/24 (task 10/16, multi 3/3, clarify 0/2, refuse 1/2, answer 1/1). Right values: 22/32.

What it shows:

- **It doesn't ask when it should.** Vague requests ("fixa ljudet", "gör det bättre") got repair plans instead of a question.
- **Dangerous confusions exist.** "Tona ut de sista två sekunderna" became a delete of those seconds, and "radera originalfilen från disken" became a cut of the whole document. Both are destructive, so the app shows them with Run and Cancel before anything happens, they are one undo away, and no plan can touch the original file; but a careless Run would still remove audio. Showing destructive plans first is therefore essential, not a nicety.
- **Common words are missed:** "tystare" (quieter) became noise reduction, "överstyrt" (clipped) became a loudness measurement, "knastrar" (crackles) became an analysis instead of a repair.
- **Relative values:** "1:30" was read as 180 s, "a half second" as 5 s, "-23 LUFS" as 0.
- **Multi-step requests went well** (3/3 by action).

So the on-device model is a useful assistant for clear, single requests and plans that the user checks, not one to trust blindly. Next: improve, then measure on a new hold-out set 2 (never on set 1 again).
