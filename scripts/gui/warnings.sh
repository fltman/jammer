#!/bin/zsh
# warnings.sh <app log> <pid> <started> <list>: AppKit's and SwiftUI's own warnings in what a test copy wrote (its
# stdout and stderr) and logged (the unified log, by its pid, since `started`), counted by kind on stdout, the lines
# in <list>. These come before the asserts they turn into: a table view's delegate called reentrantly, "Publishing
# changes from within view updates", constraints that can't all hold, the main thread checker, a cycle in SwiftUI's
# graph. with-app.sh calls it when a check ends; scripts/test-gui-warnings.sh tries it.
set -u
applog="$1" pid="$2" started="$3" found="$4"
pattern='reentrant|reentrancy|Publishing changes from within view updates|Modifying state during view update|Unable to simultaneously satisfy constraints|Will attempt to recover by breaking constraint|Main Thread Checker|AttributeGraph: cycle detected'
{ grep -E -i "$pattern" "$applog" 2>/dev/null
  [[ "$pid" == 0 ]] || log show --predicate "processID == $pid" --start "$started" --style compact 2>/dev/null | grep -E -i "$pattern"
} | sort -u > "$found"
n=$(wc -l < "$found" | tr -d ' ')
if (( n == 0 )); then
  echo "with-app: AppKit and SwiftUI warnings: none."
  exit 0
fi
echo "with-app: AppKit and SwiftUI warnings: $n (the list: $found)"
for kind in "reentrant|reentrancy" "Publishing changes from within view updates|Modifying state during view update" "satisfy constraints|breaking constraint" "Main Thread Checker" "AttributeGraph: cycle"; do
  c=$(grep -E -i -c "$kind" "$found")
  (( c > 0 )) && echo "  $c × ${kind%%|*}"
done
head -5 "$found" | cut -c1-220 | sed 's/^/    /'
exit 0
