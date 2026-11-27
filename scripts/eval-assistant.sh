#!/bin/sh
# Runs Jämmer's assistant evaluation against a model, so that "tried with Jämmer" is something
# anyone can find out for a model of their own instead of guessing.
#
#   scripts/eval-assistant.sh                     the on-device model (Apple)
#   scripts/eval-assistant.sh ollama:qwen3:8b     a model already installed in Ollama on this Mac
#
# Seven sets: the standard 18 requests and six hold-out sets (24, 23, 29, 9, 15 and 10), Swedish and English.
# JAMMER_EVAL_NORETRY=1 leaves out the one retry for a plan that names a strip the document doesn't have.
# Each set's log (build/eval/<model>/<set>.md.log) also has, under "REPLY CHANGED BY THE CHECK", every
# reply that the check on figures changed: what the model wrote and what the user is shown.
# The reports go to build/eval/<model>/; the last line of each is the score. Nothing is
# downloaded and nothing is paid for: only models on this Mac can be evaluated this way.
# For comparison, docs/ASSISTANT.md has the on-device model's and qwen3:8b's results.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
# Built first, under the series' build lock, and let go; then evaluated under the model lock (one model
# evaluation at a time on this Mac, across the three apps: two at once fill the memory and the Mac's own model
# starts to fail) with --skip-build. Never both locks at once: a build waiting behind a model run would hold up
# every app's builds. A caller that already holds the model lock has built the tests itself.
tools="$root/../the-apps/tools"
case ":${APPS_HELD_LOCKS:-}:" in *":/tmp/the-apps-build.lock:"*)
  echo "eval-assistant: run it without the build lock held (it builds under it, then evaluates under the model lock)." >&2; exit 64 ;; esac
if [ -z "${JAMMER_MODEL_LOCKED:-}" ]; then
  mkdir -p "$root/build/eval"
  built() { cd "$root/Packages/JammerKit" && swift build --build-tests; }
  if [ -x "$tools/with-build-lock.sh" ]; then
    (cd "$root/Packages/JammerKit" && "$tools/with-build-lock.sh" jammer --wait "${BUILD_WAIT:-3600}" -- swift build --build-tests) > "$root/build/eval/build.log" 2>&1
  else
    (built) > "$root/build/eval/build.log" 2>&1
  fi || { echo "eval-assistant: the tests didn't build; see build/eval/build.log" >&2; exit 1; }
  if [ -x "$tools/with-model-lock.sh" ]; then
    JAMMER_MODEL_LOCKED=1 exec "$tools/with-model-lock.sh" jammer --wait "${JAMMER_MODEL_WAIT:-3600}" -- "$0" "$@"
  fi
fi
model="${1:-}"
case "$model" in
  "") name="on-device" ;;
  ollama:*) name="$(printf '%s' "$model" | tr ':/' '--')" ;;
  *) echo "eval-assistant: give nothing (the on-device model) or ollama:<model>." >&2; exit 64 ;;
esac
# A model in Ollama stays loaded (about 6 GB for an 8B model) until its timer runs out, and the Mac's own
# model has been seen to fail right after such a run. So the model is unloaded when this ends, however it ends.
unload() {
  case "$model" in ollama:*) curl -s -m 20 -o /dev/null http://127.0.0.1:11434/api/generate -d "{\"model\":\"${model#ollama:}\",\"keep_alive\":0}" || true ;; esac
}
trap unload EXIT
trap 'exit 130' INT TERM
out="$root/build/eval/$name"
mkdir -p "$out"
cd "$root/Packages/JammerKit"
run() { # <report> <test filter> <env…>
  report="$1"; filter="$2"; shift 2
  env JAMMER_EVAL_PLANNER="$model" JAMMER_EVAL_REPORT="$out/$report" "$@" swift test --skip-build --filter "$filter" >"$out/$report.log" 2>&1 || { echo "eval-assistant: $report failed; see $out/$report.log" >&2; return 1; }
  printf '%s: %s\n' "$report" "$(tail -1 "$out/$report")"
}
run standard.md AssistantEval JAMMER_ASSISTANT_EVAL=1
run holdout1.md HoldoutEval JAMMER_HOLDOUT=1
run holdout2.md HoldoutEval JAMMER_HOLDOUT=2
run holdout3.md HoldoutEval JAMMER_HOLDOUT=3
run holdout4.md HoldoutEval JAMMER_HOLDOUT=4
run holdout5.md HoldoutEval JAMMER_HOLDOUT=5
run holdout6.md HoldoutEval JAMMER_HOLDOUT=6
echo "Reports in $out"
