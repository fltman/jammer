#!/bin/zsh
# Tries scripts/gui/warnings.sh on a made-up app log: each kind of warning is found and counted, an ordinary line
# isn't, and an empty log says none. (No app runs: pid 0 skips the system log.)
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
dir="$(mktemp -d "${TMPDIR:-/tmp/}jammer-warnings-test.XXXXXX")"
trap 'rm -rf "$dir"' EXIT
cat > "$dir/app.log" <<'LOG'
2026-11-26 10:00:00 Jammer[123] -[NSTableView reloadData] called reentrantly from the delegate; this is not supported
Publishing changes from within view updates is not allowed, this will cause undefined behavior.
Unable to simultaneously satisfy constraints.
Will attempt to recover by breaking constraint <NSLayoutConstraint:0x6000 H:[NSView]-(8)-|>
Main Thread Checker: UI API called on a background thread: -[NSView setNeedsDisplay:]
=== AttributeGraph: cycle detected through attribute 1234 ===
Jammer: the agent API listens on 9003
LOG
out="$("$root/scripts/gui/warnings.sh" "$dir/app.log" 0 now "$dir/found.txt")"
failed=0
expect() { [[ "$out" == *"$1"* ]] || { echo "test-gui-warnings: expected \"$1\" in: $out"; failed=1; }; }
expect "warnings: 6"
expect "1 × reentrant"
expect "1 × Publishing changes from within view updates"
expect "2 × satisfy constraints"
expect "1 × Main Thread Checker"
expect "1 × AttributeGraph: cycle"
grep -q "agent API listens" "$dir/found.txt" && { echo "test-gui-warnings: an ordinary line was taken for a warning"; failed=1; }
: > "$dir/empty.log"
[[ "$("$root/scripts/gui/warnings.sh" "$dir/empty.log" 0 now "$dir/none.txt")" == *"warnings: none."* ]] || { echo "test-gui-warnings: an empty log didn't say none"; failed=1; }
(( failed == 0 )) && echo "test-gui-warnings: each kind found and counted, an ordinary line not, an empty log none"
exit $failed
