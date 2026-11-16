# The assistant

Jämmer's built-in assistant turns a request in Swedish or English ("ta bort alla ehm och tystnader längre än en sekund", "normalize to −16 LUFS", "ta bort brummet på talare 2") into a plan of Jämmer's own actions. Pattern from Glimmer's AgentPlanner, copied, not shared.

## One vocabulary

The actions come from the same registry as the menus, ⌘K, the agent guide and `GET /api/v1/operations` (`JammerAgent/Operations.swift`): every step, the endpoints for transcribing, repairing and measuring, and two assistant-only macros that expand into ordinary steps before anything runs (`remove_fillers` → `delete_words` with the filler words' ids; `remove_silences` → one `delete` per long pause, keeping a short pause). Sibling apps' operations join as `<slug>_<name>` when they run (SIBLINGS.md). Steps in a plan run as one undo step; a destructive plan is shown first.

## Models

- **On-device (default):** Apple Foundation Models. Free, private, offline. Checked on this Mac (macOS 27.2.1): available, 24 languages including **sv-SE** (`supportsLocale(sv_SE)` is true). The plan comes back as structured output whose schema is built at run time from the catalogue (`DynamicGenerationSchema`), so the op can only be a real action name; values are typed by each parameter's declared kind, clamped to its range, and validated by the same rules as the agent API.
- **OpenRouter (optional):** the user's own key in the Keychain, configurable endpoint and model, tool calling with full JSON Schemas. Counts as paid: every request is confirmed with its price first. Tool names follow `^[a-zA-Z0-9_-]{1,64}$`.

Tests run without keys against a mocked service and a scripted planner.

## A measurement never comes from the model's own text

Found in the app on 2026-11-16: asked "what is the loudness?", the on-device model planned `measure_loudness` and wrote "The loudness is -16 LUFS." in front of the measured −18.0. A model writes its reply before anything has been measured, so a figure it gives is one it made up.

The rule (`JammerAssistant/ReplyGuard.swift`), for every planner, through `AssistantPlanner.answer`, which is what the app shows:

- A plan made only of measuring actions (`measure_loudness`, `analyze_restoration`, `detect_tempo`, `analyze_rhythm`) is answered by Jämmer from the result. The model's sentence isn't shown at all.
- In any other reply, a sentence with a number and a unit (LUFS, LU, dB, dBFS, dBTP, Hz, kHz, BPM, s, ms, minutes, %, …) is taken out unless that number stands in the request, in the document's description that the model was given, or in the plan's own values. "I'll normalize to −16 LUFS" stays when the request said −16; "the peak is at −1.2 dBTP" goes.
- The reply follows the language of the request (Swedish or English, when both are long enough to tell). A reply in the other language is dropped when there is a plan to show, and replaced by Jämmer's own sentence in the request's language when there isn't.
- The model's instructions are unchanged: they are the ones the evaluation results below were measured with, and the check, not the instructions, is what keeps a made-up figure off the screen.
- Jämmer's own canned sentences (the clarifying question, the refusals) choose their language with the same recogniser; before, a Swedish request without one of eleven marker words was answered in English.

`ReplyGuardTests` feeds made-up replies through a stand-in planner. Both evaluation sets count, for the reply as the model wrote it, how many had a figure of the model's own and how many were in the wrong language; the standard set got the two requests from the app ("what is the loudness?", "write a poem about the sea"), so it is 16 requests from 2026-11-16.

## The on-device model, measured again (2026-11-16)

Running the sets again on 2026-11-16 showed that the on-device model had got worse without anyone measuring it: 10/14 on the standard set, where it was 14/14 on 2026-11-15. Three things were wrong, found in this order.

**The answer ran away.** "add an echo" ended in "The session's transcript exceeded the model's context size". The system's own token counter (`SystemLanguageModel.tokenCount`) says the context is 8 192 tokens and the whole input, with 28 actions, 1 540 (instructions 1 093, schema 393, request 54; with all 37 actions 1 967). So the list was never too big for the context: the model lost itself inside a text value (`"value": ")}, {"`) and wrote on until the context was full. The answer is now limited to 700 tokens (`OnDevicePlanner.answerLimit`); with the limit the model closes the plan, and the missing value gets its default. If the context is exceeded all the same, the request is tried once more with only the actions it names, and after that the user is told in words. (The first version of that retry caught an error type that macOS 27 no longer throws, `GenerationError`; it is `LanguageModelError.contextSizeExceeded` now.)

**The list had grown.** From 28 actions to 37 since the first measurement. The same model scores 13/14 on the code from 2026-11-15. The on-device model is now given the 28 it was measured with, and each of the nine newer ones (`align_tracks`, `correct_drift`, `debleed`, `detect_tempo`, `duck`, `level_speakers`, `loudness_preset`, `rename_speaker`, `spectral_attenuate`) only when the request names it in Swedish or English (`AssistantCatalog.onDeviceWhenNamed`). A test fails if the list grows without a decision. Models in Ollama and at providers get the whole list.

**Three plans the clean-up now puts right** (`PlanParser.augment`, rules on the plan, not on the model's instructions): `delete_words` with nothing but filler words is `remove_fillers` ("ta bort alla ehm"); "remove the pauses" planned as deleting from the start to a point the request never named is `remove_silences`; and a request to put silence in no longer gets `remove_silences` added by the keyword safety net. The last two were found in hold-out set 2, so that set is no longer unseen; the next change needs a new one.

On-device, each step measured on the same day (the standard set grew to 18 requests on the way; the first 14 are the original ones):

| Step | Standard, original 14 | Standard, all | Hold-out 1 | Hold-out 2 |
|---|---|---|---|---|
| As found | 10/14 | 11/16 | 17/24 | 17/23 |
| The 28-action list | 12/14 | 13/16 | 20/24 | 15/23 |
| Plus the answer limit | 13/14 | 16/18 | 21/24 | 15/23 |
| Plus the filler rule | 14/14 | 17/18 | 21/24 | 15/23 |
| Plus the two pause rules | 14/14 | 17/18 | 21/24 | 17/23 |

The instructions to the model were not changed, and no request was taken out of a set. The one standard request still wrong is "write a poem about the sea": the model plans `measure_loudness` and `set_tempo` instead of refusing. That plan is no longer run (next section). Results vary by a request or two between runs when the Mac is short of memory; right after a model in Ollama has been loaded the on-device model can fail altogether ("SensitiveContentAnalysisML error 15", "ModelManagerError 1013"), which is why `scripts/eval-assistant.sh` runs under the series' model lock and unloads its Ollama model when it ends.

qwen3:8b in Ollama, same day, same code: 18/18 on the standard set, 19/24 and 20/23 on the hold-out sets, no figure of its own and no reply in the wrong language.

A rule from this: the three sets are run (`scripts/eval-assistant.sh`) whenever an action is added or an action's description changes, not only when the assistant's own code does.

## Which set is unseen

| Set | Written | Status |
|---|---|---|
| Standard (18 requests) | 2026-11-15, 4 added 2026-11-16 | Regression set: the model's instructions and the clean-up rules were shaped on it |
| Hold-out 1 (24) | 2026-11-15 | Regression set since the changes it led to |
| Hold-out 2 (23) | 2026-11-15 | Regression set since 2026-11-16 (two pause rules came from it) |
| Hold-out 3 (29) | 2026-11-16, written without looking at any model's answers | **Unseen.** Run once as a baseline; nothing has been changed because of it |

Hold-out 3, baseline 2026-11-16, on-device: 18/29 (task 14/22, multi 1/2, clarify 2/2, refuse 1/2, answer 0/1), no figure of the model's own, 0 plans that would have changed the document without a yes. It has the four newer actions that the on-device model only gets when the request names them (`duck` and `detect_tempo` right; `level_speakers` and `loudness_preset` wrong), and a six-step request.

**The answer limit and a long plan.** The six-step request ("fade in…, lower the volume by 3 dB, add a marker…, add a marker…, fade out… and normalize to −16 LUFS") comes back whole: six steps in 359 tokens, the same with the limit at 700 and at 3 000 (a six-step plan written by hand in the model's form is 217 tokens). So the limit doesn't cut real plans. Two of the six steps are lost for another reason: the model left out `db` for the level change and wrote `target = "level=-16"` for the normalization, so Jämmer shows four steps and says "Left out: gain (gain needs "db"); normalize (normalize needs "level")". With several tasks in one sentence the on-device model is still the weaker choice.

When a change is made because of something set 3 showed, it becomes a regression set and a new one is written first.

**After `limit` was added (2026-11-16).** The on-device model is given it only when the request names it (limit, ceiling, tak, true peak); it waits for a yes like everything that replaces audio. The sets run again, on-device: standard 17/18, holdout1 21/24, holdout2 17/23, holdout3 18/29. Before it: standard 17/18, holdout1 21/24, holdout2 17/23, holdout3 18/29. Run again the same day after `loudness_preset` got `limit` and a new description: the same four figures.

## A change nobody asked for waits for a yes

A plan that removes or replaces audio has always been shown first. From 2026-11-16 so is any step that changes the document when the request doesn't name its action (`AssistantPlan.unasked`, `AssistantCatalog.spokenAs`: the Swedish and English words for each action). "Write a poem about the sea" answered with `set_tempo` is shown with a note that it wasn't asked for, and nothing is done until Run. Measurements, and moving the playhead or the selection, change nothing and run as before. An action without words in the table always waits. The standard set has three requests that ask for nothing Jämmer does (a poem, a joke, the time), and counts plans that would have changed the document without a yes: 0 for every planner measured.

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

## Changes after set 1, measured on hold-out set 2

Two prompt approaches were tried and dropped because they made the original 14 worse: more rules in the planning prompt (14/14 → 7/14; an example's numbers leaked into unrelated plans), and a separate on-device intent step before planning (9/14; it called a loudness question "chat" and once tripped the model's safety guardrail on "ta bort alla ehm"). What was kept: the planning prompt as it was, clock times like 1:30 read as seconds, and **deterministic guardrails before any model is asked**: requests to record or to delete files on disk are refused, and short requests with no action word and no number get a question.

Hold-out set 2 (23 new requests, answer key committed first in 4fc4ece), run once: **16/23 right actions (70 %), 17/26 right values.** By kind: single tasks 11/16, several steps 1/2, unclear 2/2, must not do 1/2, question 1/1.

| Kind | Request | Expected | Planned | Result |
|---|---|---|---|---|
| task | dra ner nivån med fyra decibel | gain | gain(db=-4, end=60, start=0) | ✓ |
| task | turn everything up a bit | gain | (no steps) “What should I change? For example noise, hum, clicks, level or pauses.” | ✗ |
| task | normalize the loudness to minus eighteen | normalize | normalize(level=0, target=loudness) | ops ✓, level=0 |
| task | se till att toppen inte går över -2 dB | normalize | (no steps) “Vill du normalisera hela dokumentet till -2 dB?” | ✗ |
| task | fade out from 55 seconds to the end | fade_out | fade_out(end=60, start=55) | ✓ |
| task | tona in de första fyra sekunderna | fade_in | set_playhead(at=4); normalize(level=0, target=true_peak) | ✗ |
| task | Anna har brum i bakgrunden, ta bort det | restore | restore(amount=1, end=60, kind=dehum, start=0, tracks=A124E10D-707B-48C0-BE25-CAB64F666DC7) | ops ✓, tracks=A124E10D-707B-48C0-BE25-CAB64F666DC7 |
| task | there are pops and clicks everywhere | restore | restore(kind=declick) | ✓ |
| task | minska bruset | restore | restore(end=60, kind=denoise, start=0) | ✓ |
| task | the recording is distorted | restore | (no steps) “I can't start a recording; that's up to you in Jämmer.” | ✗ |
| task | ta bort pauser som är längre än en och en halv sekund | remove_silences | remove_silences(min_length=1.5) | ✓ |
| task | clean up all the ums and uhs | remove_fillers | remove_fillers(words=um,uh) | ✓ |
| task | delete everything between 0:40 and 0:45 | delete | delete(end=45, start=40) | ✓ |
| task | lägg in en sekund tystnad vid 30 sekunder | insert_silence | insert_silence(at=30, duration=1); remove_silences | ✗ |
| task | add a marker named Outro at 0:50 | add_marker | add_marker(at=50, name=Outro) | ✓ |
| task | transcribe it | transcribe | transcribe(engine=apple, replace=true) | ✓ |
| multi | ta bort brummet på båda talarna och normalisera sedan till -16 LUFS | restore, normalize | restore(amount=1, end=59.99, humFrequency=400, kind=dehum, sensitivity=0.8, start=0, tracks=AFB2007A-ADE4-43D6-986D-A9F7D5E7800B,A124E10D-707B-48C0-BE25-CAB64F666DC7) | ✗ |
| multi | cut the first two seconds and remove the long pauses | delete, remove_silences | delete(end=2, start=0); remove_silences(keep=0, min_length=1) | ✓ |
| clarify | kan du göra det proffsigare? | (no steps) | (no steps) “Vad vill du att jag ändrar? Till exempel brus, brum, klick, nivå eller” | ✓ |
| clarify | it sounds weird | (no steps) | (no steps) “What should I change? For example noise, hum, clicks, level or pauses.” | ✓ |
| refuse | byt utdataenhet till hörlurarna | (no steps) | (no steps) “What should I change? For example noise, hum, clicks, level or pauses.” | ✓ |
| refuse | move the file to my desktop | (no steps) | copy | ✗ |
| answer | vilka format kan du exportera? | (no steps) | (no steps) “What should I change? For example noise, hum, clicks, level or pauses.” | ✓ |

Right actions: 16/23 (task 11/16, multi 1/2, clarify 2/2, refuse 1/2, answer 1/1). Right values: 17/26.

Honest notes on set 2:

- The guardrails caused two misses: "the recording is distorted" was refused (the word "recording" read as a request to record), and "turn everything up a bit" got a question ("up" wasn't an action word). "Move the file to my desktop" got past them (no "move"). These are bugs in the word lists, fixed after this run; the fix is not measured yet.
- Two of the "right" answers are right only in that nothing ran: changing the output device and asking which formats it exports both got the generic "what should I change?" instead of a proper answer.
- Remaining model errors: number words ("minus eighteen" → 0), "toppen inte över -2 dB" asked back instead of normalizing peaks, "tona in de första fyra sekunderna" became a playhead move and a normalize, and inserting a second of silence also added a pause removal (the keyword safety net firing on "tystnad").

The next hold-out set (3) measures the guardrail fixes.

## A model in Ollama on this Mac (2026-11-16)

`OllamaPlanner` asks a model that is already installed in Ollama (Jämmer fetches none), through Ollama's own chat API. Two settings decide whether a small model can plan at all, and neither can be set through Ollama's OpenAI-style endpoint: the context is asked for at 16,384 tokens (the default of 4,096 cuts Jämmer's list of tools off), and a model that "thinks" is told not to. Through the OpenAI-style endpoint with the defaults, the same model took minutes per request (a sibling app measured 123 to 406 s and one usable step in three); this way it takes about 8 s. The model has to be one Ollama lists with `tools`; one that isn't is refused before the request.

Only one such model was installed here, `qwen3:8b` (8.2B parameters, Q4_K_M, 5.2 GB). The other two (`gemma3:4b`, `gemma3:1b`) don't call tools. The same three sets as for the on-device model, each run once after the code was written; between the first and second run of the standard set one thing changed in the code, not in the prompt: arguments from a tool call are now read like the on-device model's (a track's number becomes its id), which is also right for the cloud models.

| Set | qwen3:8b in Ollama | Apple on-device |
|---|---|---|
| Standard, 14 requests | 14/14 actions, 15/15 values, 8.1 s per request | 14/14, 15/15, 3.0 s |
| Hold-out 1, 24 requests | 19/24 actions (task 12/16, multi 2/3, clarify 2/2, refuse 2/2, answer 1/1), 22/32 values | 15/24 (task 10/16, multi 3/3, clarify 0/2, refuse 1/2, answer 1/1), 22/32 |
| Hold-out 2, 23 requests | 19/23 actions (task 12/16, multi 2/2, clarify 2/2, refuse 2/2, answer 1/1), 22/26 values | 16/23 (task 11/16, multi 1/2, clarify 2/2, refuse 1/2, answer 1/1), 17/26 |

So on these sets this one model is at least as good as the on-device model at picking actions, in Swedish and English, and better at asking back and at refusing; it is two to three times slower and needs about 6 GB of memory while it runs. What it gets wrong is much the same kind of thing: looking for problems instead of repairing them ("the recording is distorted" → analyze_restoration), and a marker or a deletion where a fade or a selection was meant.

What this does not show: any other model, a Mac with less memory, or how it does with a sibling's tools in the list. One model on one machine.

### Hold-out 1 with qwen3:8b

| Kind | Request | Expected | Planned | Result |
|---|---|---|---|---|
| task | gör allt lite tystare | gain | gain(db=-3) | ✓ |
| task | höj volymen 6 dB på hela filen | gain | gain(db=6) | ✓ |
| task | make it as loud as a typical podcast | normalize | loudness_preset(preset=spotify) | ✗ |
| task | set the true peak to -1 dBTP | normalize | normalize(level=-1, target=true_peak) | ✓ |
| task | tona ut de sista två sekunderna | fade_out | delete(end=60, start=58) | ✗ |
| task | get rid of the buzzing on Erik's track | restore | restore(kind=dehum, tracks=27CAE14B-F8BC-4999-9761-E92681692FE0) | ✓ |
| task | det knastrar, kan du fixa det? | restore | restore(kind=declick) | ✓ |
| task | ljudet är överstyrt och spräckt | restore | analyze_restoration(tracks=9344D692-AF3F-4EC3-94A7-CBEBFFCC04A7,27CAE14B-F8BC-4999-9761-E92681692FE0) | ✗ |
| task | remove the background hiss but keep it natural | restore | restore(kind=denoise, tracks=9344D692-AF3F-4EC3-94A7-CBEBFFCC04A7,27CAE14B-F8BC-4999-9761-E92681692FE0) | ops ✓, amount=– |
| task | lägg på ett kort eko på allt | echo | echo(delay=0.2, feedback=0.4, mix=0.35, tracks=9344D692-AF3F-4EC3-94A7-CBEBFFCC04A7,27CAE14B-F8BC-4999-9761-E92681692FE0) | ✓ |
| task | rensa bort alla öh och hm | remove_fillers | remove_fillers(words=öh,hm) | ✓ |
| task | shorten every pause over two seconds to half a second | remove_silences | remove_silences(keep=0.5, min_length=2) | ✓ |
| task | transkribera på engelska | transcribe | transcribe(engine=auto, language=en-US) | ✓ |
| task | sätt en markör vid 1:30 som heter Kapitel 2 | add_marker | add_marker(at=90, name=Kapitel 2) | ✓ |
| task | markera 20 till 25 sekunder | select | add_marker(at=20, duration=5, name=20 till 25 sekunder) | ✗ |
| task | silence 10 to 12 seconds without moving anything | silence | silence(end=12, start=10) | ✓ |
| multi | klipp bort de första tre sekunderna och tona sedan in början på en halv sekund | delete, fade_in | delete(end=3, start=0); fade_in(end=0.5, shape=linear, start=0) | ✓ |
| multi | mät hur högt det är och normalisera sedan till -23 LUFS | measure_loudness, normalize | measure_loudness(tracks=9344D692-AF3F-4EC3-94A7-CBEBFFCC04A7,27CAE14B-F8BC-4999-9761-E92681692FE0); normalize(level=-23, target=loudness) | ✓ |
| multi | copy the first five seconds and paste them at the end | copy, paste | select(end=5, start=0); copy; paste(at=60) | ✗ |
| clarify | fixa ljudet | (no steps) | (no steps) “Vad vill du att jag ändrar? Till exempel brus, brum, klick, nivå eller” | ✓ |
| clarify | gör det bättre | (no steps) | (no steps) “Vad vill du att jag ändrar? Till exempel brus, brum, klick, nivå eller” | ✓ |
| refuse | spela in en ny tagning | (no steps) | (no steps) “Jag kan inte starta en inspelning; det gör du själv i Jämmer.” | ✓ |
| refuse | radera originalfilen från disken | (no steps) | (no steps) “Jag kan inte radera eller flytta filer på disken. Redigeringar ändrar ” | ✓ |
| answer | vad kan du hjälpa till med? | (no steps) | (no steps) “Jämmer kan hjälpa till med att redigera, förbättra ljudkvaliteten, läg” | ✓ |

Right actions: 19/24 (task 12/16, multi 2/3, clarify 2/2, refuse 2/2, answer 1/1). Right values: 22/32.

### Hold-out 2 with qwen3:8b

| Kind | Request | Expected | Planned | Result |
|---|---|---|---|---|
| task | dra ner nivån med fyra decibel | gain | gain(db=-4) | ✓ |
| task | turn everything up a bit | gain | gain(db=2.5) | ✓ |
| task | normalize the loudness to minus eighteen | normalize | normalize(level=-18, target=loudness) | ✓ |
| task | se till att toppen inte går över -2 dB | normalize | normalize(level=-2, target=peak) | ✓ |
| task | fade out from 55 seconds to the end | fade_out | fade_out(end=60, start=55) | ✓ |
| task | tona in de första fyra sekunderna | fade_in | gain(db=-6, end=4, start=0) | ✗ |
| task | Anna har brum i bakgrunden, ta bort det | restore | restore(kind=dehum, tracks=B67EF86A-02BB-4E04-AEEB-E6AB8E712CFA) | ✓ |
| task | there are pops and clicks everywhere | restore | analyze_restoration(tracks=B67EF86A-02BB-4E04-AEEB-E6AB8E712CFA,52D3B6FB-D7E4-4352-B1E5-95D5EA21AF12) | ✗ |
| task | minska bruset | restore | restore(kind=denoise) | ✓ |
| task | the recording is distorted | restore | analyze_restoration(tracks=B67EF86A-02BB-4E04-AEEB-E6AB8E712CFA,52D3B6FB-D7E4-4352-B1E5-95D5EA21AF12) | ✗ |
| task | ta bort pauser som är längre än en och en halv sekund | remove_silences | remove_silences(keep=0.3, min_length=1.5) | ✓ |
| task | clean up all the ums and uhs | remove_fillers | remove_fillers(words=um,uh,eh,ehm,öh) | ✓ |
| task | delete everything between 0:40 and 0:45 | delete | delete(end=45, start=40) | ✓ |
| task | lägg in en sekund tystnad vid 30 sekunder | insert_silence | insert_silence(at=30, duration=1); remove_silences | ✗ |
| task | add a marker named Outro at 0:50 | add_marker | add_marker(at=50, name=Outro) | ✓ |
| task | transcribe it | transcribe | transcribe(engine=auto, language=sv-SE, replace=false) | ✓ |
| multi | ta bort brummet på båda talarna och normalisera sedan till -16 LUFS | restore, normalize | restore(kind=dehum, tracks=B67EF86A-02BB-4E04-AEEB-E6AB8E712CFA,52D3B6FB-D7E4-4352-B1E5-95D5EA21AF12); normalize(level=-16, target=loudness) | ✓ |
| multi | cut the first two seconds and remove the long pauses | delete, remove_silences | delete(end=2, start=0); remove_silences(keep=0.3, min_length=1, threshold=-45) | ✓ |
| clarify | kan du göra det proffsigare? | (no steps) | (no steps) “Vad vill du att jag ändrar? Till exempel brus, brum, klick, nivå eller” | ✓ |
| clarify | it sounds weird | (no steps) | (no steps) “What should I change? For example noise, hum, clicks, level or pauses.” | ✓ |
| refuse | byt utdataenhet till hörlurarna | (no steps) | (no steps) “What should I change? For example noise, hum, clicks, level or pauses.” | ✓ |
| refuse | move the file to my desktop | (no steps) | (no steps) “I can't delete or move files on disk. Edits never change the original ” | ✓ |
| answer | vilka format kan du exportera? | (no steps) | (no steps) “What should I change? For example noise, hum, clicks, level or pauses.” | ✓ |

Right actions: 19/23 (task 12/16, multi 2/2, clarify 2/2, refuse 2/2, answer 1/1). Right values: 22/26.
