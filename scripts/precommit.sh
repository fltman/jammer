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
# The string catalogue and the code that uses it: placeholders, plural forms, keys, and no user text in moved files.
scripts/test-guest-clean.sh > "$out/guestclean.out" 2>&1 || fail "guest-clean.sh: $(tail -1 "$out/guestclean.out")"
scripts/check-fetch-guard.sh > "$out/fetch.out" 2>&1 || fail "a script can fetch third-party code without a yes ($(head -1 "$out/fetch.out"))"
scripts/check-strings.py --self-test > "$out/strings.out" 2>&1 || fail "the catalogue check doesn't catch what it should ($(head -1 "$out/strings.out"))"
scripts/check-strings.py --require sv >> "$out/strings.out" 2>&1 || fail "the string catalogue: $(grep -c 'check-strings:' "$out/strings.out") fault(s), the first: $(grep 'check-strings:' "$out/strings.out" | head -1)"
# The project file is generated and not committed: made again whenever project.yml or the list of files is newer.
xcodegen generate > /dev/null 2>&1 || fail "the project couldn't be generated"
xcodebuild -project Jammer.xcodeproj -scheme Jammer -configuration Debug -derivedDataPath build/dd build > "$out/app.out" 2>&1 || fail "the app didn't build"
scripts/test-language-switch.sh > "$out/language.out" 2>&1 || fail "the language switch: $(tail -1 "$out/language.out")"
# The signed app's entitlements, read as the system reads them, against what is decided.
scripts/check-entitlements.sh > "$out/entitlements.out" 2>&1 || fail "the signed app's entitlements are not what is decided ($(head -1 "$out/entitlements.out"))"
scripts/test.sh > "$out/suite.out" 2>&1 || fail "the test suite: $(grep -c '✘ Test' "$out/suite.out") failing"
[[ "$(grep -c '✘' "$out/suite.out")" == 0 ]] || fail "the test suite printed a failure"
(cd "$tools/../site" && node build.mjs --strict) > "$out/site.out" 2>&1 || fail "the strict site build"
echo "precommit: green ($(grep -E 'Test run with' "$out/suite.out" | awk '{t+=$5} END {print t}') tests)"
