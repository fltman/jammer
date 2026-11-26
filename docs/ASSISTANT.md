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
- In any other reply, a sentence with a number and a unit (LUFS, LU, dB, dBFS, dBTP, Hz, kHz, BPM, s, ms, minutes, %, and since 2026-11-16 money and sizes on disk) is taken out unless something backs the number up. The series rule (the-apps/SIBLINGS.md, "Siffror i assistentens svar") says what does; in Jämmer (`ReplyGuard.Backing`):
  1. the request, in digits or in words ("two seconds", "en och en halv sekund");
  2. the document's description that the model was given; and, Jämmer's own addition, the values of the plan's steps (they are what will run, and the user sees them beside the sentence);
  3. an action's description, its parameters' descriptions and ranges, only in a sentence that names the action (its name, a word of its name, a parameter name that isn't a common one, or one of its `onDeviceWhenNamed` words), and never in a sentence that speaks of the user's own sound ("your", "is at", "ligger på", …);
  4. the closed set `ReplyGuard.derived`: the selection's length, what is left after the playhead and after the selection, half the document and half the selection, the sum and the difference of two times in the request, any of those times in ms, s or minutes, and the difference between two levels given. Membership with the rounding a person sees (the value, or to 0, 1 or 2 decimals). Not in the set, though suggested: a length from frames and sample rate, and the sum of two clips' lengths; the model isn't told the sample rate or the clips, so there is nothing given to work them out from.
  - Money, sizes on disk, a time in a sentence about how long something takes, and any figure in a sentence about a service: only 1 and 2. 0, 1 and a count up to the number of steps are free.
  - The sentences taken out are in `AssistantPlan.heldBack`; the panel says that a sentence was held back, in the request's language. "I'll normalize to −16 LUFS" stays when the request said −16; "the peak is at −1.2 dBTP" goes.
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
| Hold-out 4 (6, the mixer) | 2026-11-16, written without looking at any model's answers | Regression set since the same day: two changes came from its first run (below) |

Hold-out 3, baseline 2026-11-16, on-device: 18/29 (task 14/22, multi 1/2, clarify 2/2, refuse 1/2, answer 0/1), no figure of the model's own, 0 plans that would have changed the document without a yes. It has the four newer actions that the on-device model only gets when the request names them (`duck` and `detect_tempo` right; `level_speakers` and `loudness_preset` wrong), and a six-step request.

**The answer limit and a long plan.** The six-step request ("fade in…, lower the volume by 3 dB, add a marker…, add a marker…, fade out… and normalize to −16 LUFS") comes back whole: six steps in 359 tokens, the same with the limit at 700 and at 3 000 (a six-step plan written by hand in the model's form is 217 tokens). So the limit doesn't cut real plans. Two of the six steps are lost for another reason: the model left out `db` for the level change and wrote `target = "level=-16"` for the normalization, so Jämmer shows four steps and says "Left out: gain (gain needs "db"); normalize (normalize needs "level")". With several tasks in one sentence the on-device model is still the weaker choice.

When a change is made because of something set 3 showed, it becomes a regression set and a new one is written first.

**The mixer's first actions (2026-11-16).** `add_bus` is given to the assistant (to the on-device model only when the request says bus or submix); `set_bus` and `remove_bus` are not, because they need a bus id the assistant isn't told. Hold-out set 4 was written for it, unseen, and run:

| | Standard | Hold-out 1 | Hold-out 2 | Hold-out 3 | Hold-out 4 |
|---|---|---|---|---|---|
| Before the mixer's actions | 17/18 | 21/24 | 17/23 | 18/29 | – |
| With them, first run | 17/18 | 21/24 | 17/23 | 18/29 | 1/6 |
| After the two changes below | 17/18 | 21/24 | 18/23 | 18/29 | 4/6 |

What set 4's first run showed, and what was changed (which is why it is a regression set now):

1. "create a bus called Music" was answered "What should I change?" by Jämmer's own guard before the model was asked: the guard's list of words that mean an action had none of the mixer's or the mastering steps'. They are in it now.
2. The model did choose `add_bus`, and gave the name under another name than the parameter's (the step was left out as "add_bus needs name", and the model's sentence said "Bus Music created."). A value given under a name the action doesn't have is now taken as the one required value that is missing, when there is exactly one of each (`PlanParser.typed`). It is a general rule, not one for buses: it also moved one request in hold-out 2 to right.

**Counted both ways from 2026-11-16.** Each set now gives two figures: *as the user gets it*, after the checks the app makes on every plan (`ReplyGuard`: a plan that only moves the playhead for a request that asks for nothing of the kind is no plan, and so on), and *the model's own plan*. The first is what the app does and is the one a target applies to; the second says how much the checks carry.

| On-device, 2026-11-16, after buses got names | Standard | Hold-out 1 | Hold-out 2 | Hold-out 3 | Hold-out 4 |
|---|---|---|---|---|---|
| As the user gets it | 17/18 | 21/24 | 18/23 | 19/29 | 6/9 |
| The model's own plan | 17/18 | 21/24 | 18/23 | 18/29 | 6/9 |

Hold-out 4 got three more requests that name a bus (its document has one bus, Music; the other sets' documents have none, so their requests reach the model exactly as before). The model is told the buses by name and `set_bus` and `remove_bus` take the name. "remove the Music bus" was right at once; "set the Music bus to -6 dB" and "tysta bussen Music" were not, and the model's raw answer showed why: it names the argument after the bus itself (`{"name": "Music", "value": "-6"}`), adds `output: Music` (the bus to itself), and answers "tysta" with a level of 0 and a `remove_bus` besides. The app now reads it: an argument whose name is the name of exactly one bus is the target, with its value as the level when it is a number and as the mute when it says so; a route from a bus to itself is dropped; a request that says mute and not remove is a mute, and loses a `remove_bus` nobody asked for; `remove_bus` always waits for a yes; and a change to a bus with nothing to change is left out and said, so the user is asked instead of told "done". After that: hold-out 4 at 7/9 both ways, the three bus requests right, the other sets unchanged (17/18, 21/24, 18/23, 19/29 as the user gets it). The sentence in the wrong language for the English request is dropped by `ReplyGuard` (checked).

The rule that recovers a value given under another name is narrow: exactly one required value missing, exactly one value under a name the action doesn't have, the value of the kind that is missing, and never for an action that removes or replaces audio.

Earlier the same day, before the names: the two requests the assistant couldn't do ("pan Erik a little to the left", "ta bort bussen Musik") are answered with a step that moves the playhead or the selection instead of a refusal. In the app such a plan is not run and the user gets a refusal (`ReplyGuard`, the rule about steps that only move the playhead); the sets count the plan as the model made it, so they count as wrong. The same rule 2 has a cost that shows in hold-out 3: "what's the weather like in Stockholm" used to come back as a step left out for a missing value and now comes back as `set_playhead(at=0)`, so that set's refusals went from 1 of 2 to 0 of 2 while a task went from wrong to right (18/29 both times). In the app that request, too, ends as a refusal.

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

## The mixer's later parts, and the rule on figures (2026-11-16)

The assistant was given `set_master`, `set_send`, `add_vca`, `set_vca`, `remove_vca`, `freeze` and `unfreeze`; the on-device model is shown each only when the request has its word (`onDeviceWhenNamed`). Tracks, buses and VCA groups are named by name and become ids (`AssistantContext.stripID`, `vcaID`); the model is told the VCA groups, what is frozen and the master limiter's ceiling. Hold-out set 5 (15 requests, written before any answer was seen) is about them. It was looked at after its first run and changed from: it is a regression set from now on.

On-device, three runs the same evening, as the user gets it / the model's own plan:

| Set | Before (new actions, old rule on figures) | New rule on figures and first repairs | Final |
|---|---|---|---|
| standard (18) | 17 / 17 | 17 / 17 | 17 / 17 |
| hold-out 1 (24) | 21 / 21 | 21 / 21 | 21 / 21 |
| hold-out 2 (23) | 18 / 18 | 18 / 18 | 18 / 18 |
| hold-out 3 (29) | 19 / 18 | 20 / 19 | 20 / 19 |
| hold-out 4 (9) | 7 / 7 | 7 / 7 | 7 / 7 |
| hold-out 5 (15) | 8 / 8 | 10 / 10 | 11 / 11 |

(Before the new actions the same day: standard 17, hold-out 1 21, hold-out 2 17, hold-out 3 18. The one-request moves in sets 2 and 3 are within what this model varies between runs.)

What set 5's first run showed, and what was done (all in `PlanParser`, none in the model's instructions):
- A short request about freezing, the master or a VCA was answered "What should I change?" before the model was asked: their words were added to the words that mean an action.
- `set_master` came with every setting filled in ("limiter": false and a ceiling for "sänk mastern till −3 dB"; counted right because only the asked value was compared). Now the limiter's settings stay only when the request speaks of a limiter or a ceiling, a limiter that is asked for is switched on, and a setting nobody gave a figure for is left as it is.
- "Freeze the Music bus" came as a change to the bus that changes nothing: that is now the freeze of that bus.
- Two plans would have changed the document unasked: "send Erik to the Music bus at −6 dB" set the Music bus's own level to −6, and "tysta VCA-gruppen Voices" made a new group called "muted". Both are now left out with a line saying why. In the final run no plan changes the document without being asked.
- Still wrong in the final run, 4 of 15: the send (nothing is done; the model doesn't choose `set_send`), muting a VCA group in Swedish (nothing is done), "remove the Voices VCA" (the model names the group in a way that isn't found; nothing is done, but its sentence "VCA Voices removed." is still shown above the line that says the step was left out), and "master the episode for Spotify" (normalised to −16 LUFS instead of the Spotify preset).

The rule on figures, in the same runs. The evaluation prints, for every reply the check changed, what the model wrote, what the user is shown, and which sentences were held back for a figure (`REPLY CHANGED BY THE CHECK` in each set's log).
- With the old rule, across the six sets, two replies lost a sentence whose figure the model had read rightly from the request, where the request gave it in words: "Pause shorter than 2 seconds to 0.5 seconds." (for "over two seconds to half a second") and "Loudness normalized to -18 LUFS." (for "minus eighteen"). So the same thing happened here as in Glimmer, in the form of numbers in words.
- With the new rule, second run: one, "Ta bort pauser längre än 1.5 sekunder." for "en och en halv sekund"; "and a half" was added to the number words.
- Final run: no sentence held back for a figure in any of the 118 requests, and no reply had a figure of the model's own. The other changed replies were changed for the language or because the plan only measures.
- No reply in these sets used a figure from the worked-out set (the model doesn't do arithmetic in its replies here), so that part is shown by `ReplyGuardTests` only: a rightly worked-out figure stays and a made-up one beside it is held back.

**Later the same evening: three more things, and a fourth run.**
- A sentence that says something was done is not shown above a step that wasn't run (series rule). When every step the model planned was left out, Jämmer's own "I can't do that as asked" stands in place of the model's sentence, with the line about what was left out; when some steps stay and some were left out, the model's sentence isn't shown at all (whether it claims more than what will run can't be told), and the plan and the left-out line speak. Found as "VCA Voices removed." above "Left out: remove_vca".
- "Master the episode for Spotify" came as a normalize to −16 LUFS, where Spotify's preset is −14: a wrong target that would have run. A delivery target that the request names (Spotify, YouTube, Apple, EBU/R128, ATSC/A85) now makes a normalize into that `loudness_preset`, unless the request gives the level itself ("normalize to −16 LUFS for Spotify" stays a normalize). What went: the model was offered the preset and didn't choose it; the repair is in `PlanParser.augment`, not in the model. The words that name a target are the presets' own names (`LoudnessPreset.allCases`), not a second table, and a plan with a preset chosen this way is always shown before it runs, with the preset and its targets ("Spotify (−14 LUFS, −1 dBTP): the preset for the target you named, not a level of the assistant's own.").
- Fourth run, on-device, as the user gets it / the model's own plan: standard 17 / 17, hold-out 1 21 / 21, hold-out 2 18 / 18, hold-out 3 21 / 20 (its "master it for Spotify" is now right too), hold-out 4 7 / 7, hold-out 5 12 / 12. No plan that changes the document unasked, no sentence held back for a figure.

**Seen in the app** (a debug copy answered from a file, `-assistantScript <file>`, Debug builds only, so that the panel's handling can be looked at without waiting for a model to say the right wrong thing; the answers go through the same typing, repairs and checks as a model's): "freeze track one" froze the track (the mixer says so, the status line says "Episode 7 is frozen…") and "unfreeze track one" thawed it; "Half of it is 12.5 s. The peak is at -3.2 dBTP." for a 25.08 s document was shown as "Half of it is 12.5 s." with the line "A sentence with a figure I can't back up was held back."; "VCA Drums removed." for a group that doesn't exist was shown as "I can't do that as asked…" with the left-out line. Looked at as a picture. Not seen: the same with a real model in the panel, and the Swedish form of the held-back line.

**After the API's texts became American English (2026-11-17: "Recognizer", "center", "neighboring" in the descriptions the model is given).** All six sets run once, on-device: as the user gets it 17/18, 21/24, 18/23, 21/29, 7/9 and 12/15 (the model's own plan 17/18, 21/24, 18/23, 20/29, 7/9, 12/15). No set is lower than the last run written down above for it (17/18, 21/24, 18/23, 19/29, 6/9, and 11/15 for the fifth, where 4 of 15 were still wrong); the three that are higher by one or two are within what the model varies between runs, not a gain to claim.

## Tracks by name (2026-11-19)

Found while making the product film: asked "sänk musiken med 12 dB när någon pratar", the on-device model planned `duck` with `"tracks": ["music"]`, the track's name, and Jämmer refused ("no track with id music"; the plan's preview said "duck: duck: …"). Now every parameter that names a track, bus or VCA group (`track`, `tracks`, `under`, `strip`, `from`, `to`, `members`, `add`, `remove`, `reference`, `against`, `output`) takes an id or the strip's exact name, ignoring case (`StepRunner.resolveStrips`, run before each step and in the plan's preview). A name that fits one strip gives that strip; a name that fits none or several isn't guessed at, and the step fails with every strip's id and name so the model can try again. Anders's choice, the coordinator's proposal. The preview no longer says the step's name twice.

The evaluation, on-device model, the same day, before and after the change: standard 17/18, hold-out sets 21/24, 18/23, 21/29, 7/9 and 12/15, both times (96/118). None of its requests names a track, so the change was expected to leave it as it was; the duck test (`duckThroughSteps`) covers an id, a name in another case, a name nobody has and a name two tracks share, and fails with the change taken out. The doubled name came from two places, the preview and `MacroExpander` (which put "duck: " before a failure that already began with it); both say it once now (`failureSaidOnce`, which fails with the fix taken out).

Tried in the app afterwards with the same request: the model now wrote `"under": "12"` (the 12 dB in the wrong parameter), and Jämmer refused it with the list of tracks. So the request still doesn't go through on the on-device model; what changed is that a track's name works and that a wrong value is said once, with what would be right. "Ta bort alla ehm och tystnader längre än en sekund" (the app's own example) is what the film shows in Swedish.

### One more try with the list (2026-11-19)

Anders's choice on the coordinator's proposal: when a plan names a strip the document doesn't have (an unknown name, or a number where a track goes, as `"under": 10`), the model is asked once more with Jämmer's words and every strip's id and name (`StripRetry`, `planChecked`, used by the app and by the evaluation); a second wrong plan stands and fails when it runs, said once. Never more than one retry. Tested against stand-in planners (`stripRetry`, which fails with the retry switched off).

Hold-out set 6 (`HoldoutCases6.swift`, 10 requests written before any answer was seen, the film's document with the tracks Dialog and Music) was added to measure it, and the scoring now takes a strip's name where its id would count. On-device model, the same day:

| Set | Without the retry (`JAMMER_EVAL_NORETRY=1`) | With it |
|---|---|---|
| Standard | 17/18 | 17/18 |
| Hold-out 1–5 | 21/24, 18/23, 21/29, 7/9, 12/15 | the same |
| Hold-out 6 (tracks) | 6/10, values 7/19 | 6/10, values 7/19 |

What it changed is not in the score, because the evaluation doesn't run the steps: "duck the music under the speech" was planned with `"under": 1` (a step that would fail) and, after the retry, without it (a step that runs). It didn't help the other two duck requests: "sänk musiken med 12 dB när någon pratar" gets `"under": "music"`, a real track (so no retry) but the one being ducked, which `duck` refuses in its own words; "duck Music under Dialog by 10 dB" still gets `"under": -10` after the retry. The set's other misses are not about names: "mute the Music track" and "tysta musikspåret" get a question back, "pan the dialog a little to the left" a click repair, and "set the Music track's level to -8 dB" a gain instead of the track's level.

### Plans that can be carried out (2026-11-19)

The coordinator's second proposal, Anders's yes: the evaluation also runs every plan that names the right actions on a fixed copy of its document, with sound and a transcript and no window (`EvalRun`: macros expanded, strips resolved, each step run; a step the app runs as a job, such as `restore` or `transcribe`, checked as the API checks it). "Runnable as planned" counts a request only when its plan is right for the user and every step can be carried out. The plans themselves are made from the same context as before, so the first column compares with the earlier runs. Ducking a track under itself now also gets the one retry. On-device model, the same day:

| Set | Plan right | Runnable, without the retry | Runnable, with it |
|---|---|---|---|
| Standard | 17/18 | 17/18 | 17/18 |
| Hold-out 1 | 21/24 | 21/24 | 21/24 |
| Hold-out 2 | 18/23 | 18/23 | 18/23 |
| Hold-out 3 | 21/29 | 18/29 | 19/29 |
| Hold-out 4 | 7/9 | 7/9 | 7/9 |
| Hold-out 5 | 12/15 | 12/15 | 12/15 |
| Hold-out 6 (tracks) | 6/10 | 3/10 | 4/10 |
| All | 102/128 | 96/128 | 98/128 |

Still not runnable with the retry: "make Erik 4 dB quieter" (a `gain` whose end is its start), "sänk musiken med 12 dB när någon pratar" and "duck Music under Dialog by 10 dB" (`under` 1 and 10 again after the retry: the model reads the amount as a track), and "vad är tempot i låten?" (tempo detection isn't compiled into the test build, so that one says nothing about the model).

`split_speakers` (2026-11-19) joined the actions: for the on-device model only when the request names it (`onDeviceWhenNamed`: split, dela upp, own track, eget spår, …), so its list stays the 28 it was measured at; the full catalogue for other models grew to about 6 110 characters (the check is now under 6 200). The evaluation run again with it: 17/18, 21/24, 18/23, 21/29, 7/9, 12/15 and 5/10 plans right; no request planned `split_speakers`. Set 6 was 5/10 instead of 6/10 because the Swedish duck request got a question back ("Vilket spår ska jag sänka…?") instead of a wrong track: the run-to-run variation noted above, not the new action.


## Match ACX Requirements given to the assistant (2026-11-26)

`acx_match` was added to the assistant's actions. The on-device model is told about it only when the request names it ("acx", "audible", "audiobook", "ljudbok"), so its list of 28 is otherwise unchanged. The whole catalogue went from under 6 200 characters to 6 491.

The seven sets were run on the on-device model twice the same day, without the action and then with it (`scripts/eval-assistant.sh`, under the model lock):

| On-device, 2026-11-26 | Standard | Hold-out 1 | Hold-out 2 | Hold-out 3 | Hold-out 4 | Hold-out 5 | Hold-out 6 | All |
|---|---|---|---|---|---|---|---|---|
| Without `acx_match` | 13/18 | 17/24 | 20/23 | 22/29 | 8/9 | 10/15 | 4/10 | 94/128 |
| With it | 13/18 | 17/24 | 20/23 | 22/29 | 8/9 | 10/15 | 4/10 | 94/128 |

The other figures moved by one each way:
- Hold-out 3 had 19/29 plans runnable as planned, where it had 18/29.
- Hold-out 6 had two replies in the wrong language (replaced before the user saw them), where it had one.
- The average time per request went from 2.9 s to 3.0 s.

The standard set's 13/18 is lower than the 17/18 measured on 2026-11-16 with the same model; both runs today are, which is why the comparison is made on the same day.

## Why the standard set fell to 13/18, and the fix (2026-11-26)

The standard set gave 13/18 on 2026-11-26, against 17/18 on 2026-11-19. To tell the code from the model, the commit measured then (d84d6ae) was built in a worktree of its own and evaluated on today's on-device model (macOS 27.2.1, 26B131, the same as then). It gave 17/18 three times out of three, so it is the code.

Only three lines of what the on-device model is shown for these requests had changed:
- **`transcribe`'s engine list** gained `pianissimo` and `berget_pianissimo` (86d0f4b, 2026-11-21). The paid one should never have been offered: the filter left out only `openai`.
- **`transcribe`'s description** became "as a job and applies the transcript in one undo step" (the same commit).
- **`remove_marker`** gained a marker id beside the name, so `name` was no longer required (1865d97, 2026-11-25). The assistant is never shown marker ids.

Measured on the standard set:

| Code | Standard set (runs) |
|---|---|
| d84d6ae (2026-11-19) | 17, 17, 17 |
| 86d0f4b (the transcribe lines) | 16 |
| Before the fix | 13, 13 |
| `remove_marker` by name, paid engines out, the old description | 15, 17, 15, 15 |
| The same, and `pianissimo` not offered | 17, 17 |

The model is not fully repeatable: the same code moved by two on the standard set once, so each comparison was run more than once.

The fix is in the assistant's view only; agents keep the new forms:
- `remove_marker` is offered by name, as it was evaluated.
- `transcribe` gets the engines it was evaluated with: no paid one, by the engines' own list, and not `pianissimo`, which stays the transcript panel's choice (and an agent's).
- `transcribe` gets the description it was evaluated with, which is true for what the assistant can do.

A test holds all three. With the fix, all seven sets in one run:

| On-device, 2026-11-26 | Standard | Hold-out 1 | Hold-out 2 | Hold-out 3 | Hold-out 4 | Hold-out 5 | Hold-out 6 | All |
|---|---|---|---|---|---|---|---|---|
| Before the fix | 13/18 | 17/24 | 20/23 | 22/29 | 8/9 | 10/15 | 4/10 | 94/128 |
| d84d6ae | 17/18 | 21/24 | 18/23 | 21/29 | 7/9 | 12/15 | 5/10 | 101/128 |
| With the fix | 17/18 | 21/24 | 18/23 | 21/29 | 7/9 | 12/15 | 6/10 | 102/128 |
