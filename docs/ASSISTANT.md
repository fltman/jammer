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
