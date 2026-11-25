#!/bin/zsh
# Reads the entitlements out of a signed app, as the system will, and holds them to what is decided:
#
#   scripts/check-entitlements.sh [path to Jammer.app]     (default: the Debug build)
#
#   the app:      com.apple.security.app-sandbox = false, and nothing else
#                 (get-task-allow is Xcode's own in a Debug build and is allowed there);
#                 never com.apple.security.cs.disable-library-validation (CLAUDE.md, docs/RELEASING.md);
#   the helpers:  jammer-plugin-probe and jammer-plugin-host have none, until Anders approves theirs.
#
# Why it exists: a sibling app shipped builds for a day without an entitlement that had been added to a
# generated file and not to the project's source, and nothing noticed until the signed app was read.
# The source here is project.yml (`entitlements.properties`); App/Jammer.entitlements is written from it.
# When an entitlement is decided, it goes into project.yml AND into `want` below, in the same commit.
set -u
cd "$(dirname "$0")/.."
app="${1:-build/dd/Build/Products/Debug/Jammer.app}"
[[ -d "$app" ]] || { echo "check-entitlements: no app at $app" >&2; exit 2; }
read_keys() { # <binary> → one "key=value" per line, sorted; empty when it has none
  codesign -d --entitlements - --xml "$1" 2>/dev/null | plutil -convert json -o - - 2>/dev/null | python3 -c '
import json,sys
raw=sys.stdin.read().strip()
d=json.loads(raw) if raw else {}
for k in sorted(d): print("%s=%s" % (k, json.dumps(d[k])))'
}
failed=0
codesign -v "$app" 2>/dev/null || { echo "check-entitlements: $app is not signed, or its signature doesn't hold"; exit 1; }
want=("com.apple.security.app-sandbox=false" "com.apple.security.device.audio-input=true")
allowed_in_debug=("com.apple.security.get-task-allow=true")
never=("com.apple.security.cs.disable-library-validation")
have=("${(@f)$(read_keys "$app/Contents/MacOS/Jammer")}")
for w in $want; do
  [[ ${have[(Ie)$w]} != 0 ]] || { echo "check-entitlements: the app is missing $w"; failed=1; }
done
for h in $have; do
  [[ -z "$h" ]] && continue
  [[ ${want[(Ie)$h]} != 0 || ${allowed_in_debug[(Ie)$h]} != 0 ]] || { echo "check-entitlements: the app has $h, which nobody decided"; failed=1; }
  for n in $never; do [[ "$h" == $n=* ]] && { echo "check-entitlements: the app has $n, which it must never have"; failed=1; }; done
done
for helper in jammer-plugin-probe jammer-plugin-host; do
  f="$app/Contents/MacOS/$helper"
  [[ -f "$f" ]] || { echo "check-entitlements: $helper is not in the app"; failed=1; continue; }
  got="$(read_keys "$f")"
  [[ -z "$got" ]] || { echo "check-entitlements: $helper has entitlements nobody decided: ${got//$'\n'/, }"; failed=1; }
done
# The source says the same as the signed app: every wanted key stands in project.yml.
for w in $want; do
  grep -q "^ *${w%%=*}: ${w#*=}" project.yml || { echo "check-entitlements: project.yml doesn't carry ${w%%=*}: ${w#*=} (a generated file is not the source)"; failed=1; }
done
[[ $failed == 0 ]] && echo "check-entitlements: $app as decided (the app: ${(j:, :)want}; the helpers: none)"
exit $failed
