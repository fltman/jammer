#!/bin/zsh
# Everything that has to be green before a commit, as ONE command with one exit status, so that a commit
# can be made to depend on it:   scripts/precommit.sh && git add -A && git commit …
#   the agents guide exported; the scripts checked for zsh's `path`; the app built; the whole test suite;
#   the site built strictly.
# It takes the series' build lock around itself (one heavy build at a time across the three apps'
# sessions); run it without any other lock held (the order is: build lock, then GUI lock, then model lock).
#   JAMMER_PRECOMMIT_LOCKED=1 is set for the inner run; don't set it yourself.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
tools=$root/../the-apps/tools
if [[ -z "${JAMMER_PRECOMMIT_LOCKED:-}" && -x "$tools/with-build-lock.sh" ]]; then
  exec "$tools/with-build-lock.sh" jammer --wait "${BUILD_WAIT:-1800}" -- env JAMMER_PRECOMMIT_LOCKED=1 "$0" "$@"
fi
cd "$root"
out="${JAMMER_PRECOMMIT_OUT:-$root/build/precommit}"
mkdir -p "$out"
fail() { echo "precommit: NOT green: $1 (see $out)"; exit 1; }
scripts/export-agents-guide.sh > "$out/guide.out" 2>&1 || fail "the agents guide didn't export"
[[ ! -x "$tools/check-zsh-path.sh" ]] || "$tools/check-zsh-path.sh" scripts > "$out/path.out" 2>&1 || fail "a script uses zsh's path as a variable"
[[ -d Jammer.xcodeproj ]] || xcodegen generate > /dev/null 2>&1
xcodebuild -project Jammer.xcodeproj -scheme Jammer -configuration Debug -derivedDataPath build/dd build > "$out/app.out" 2>&1 || fail "the app didn't build"
# The signed app's entitlements, read as the system reads them, against what is decided.
scripts/check-entitlements.sh > "$out/entitlements.out" 2>&1 || fail "the signed app's entitlements are not what is decided ($(head -1 "$out/entitlements.out"))"
scripts/test.sh > "$out/suite.out" 2>&1 || fail "the test suite: $(grep -c '✘ Test' "$out/suite.out") failing"
[[ "$(grep -c '✘' "$out/suite.out")" == 0 ]] || fail "the test suite printed a failure"
(cd "$tools/../site" && node build.mjs --strict) > "$out/site.out" 2>&1 || fail "the strict site build"
echo "precommit: green ($(grep -E 'Test run with' "$out/suite.out" | awk '{t+=$5} END {print t}') tests)"
