#!/bin/zsh
# No script sends anything through System Events (the series' rule, 2026-11-26): it sends keys to whatever app is in
# front, so a check could type into another app. Keys go through build/tools/keys (to the test copy's pid, checked
# in front before each key), windows through build/tools/ax. A comment may name it; code may not.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
found=0
for f in "$root"/scripts/**/*(.N); do
  [[ "$f" == "$root/scripts/check-no-system-events.sh" ]] && continue
  while IFS= read -r line; do
    n="${line%%:*}"; text="${line#*:}"
    stripped="${text#"${text%%[![:space:]]*}"}"
    [[ "$stripped" == \#* || "$stripped" == //* ]] && continue
    echo "check-no-system-events: ${f#$root/}:$n: $stripped"
    found=1
  done < <(grep -n "System Events" "$f" 2>/dev/null)
done
(( found == 0 )) && echo "check-no-system-events: no script sends through System Events"
exit $found
