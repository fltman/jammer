#!/bin/sh
# Runs the package tests. The engine's realtime guard runs as part of the build
# (-Werror=function-effects), so a passing build is itself a check.
set -eu
cd "$(dirname "$0")/../Packages/JammerKit"
swift build
# Tests reach only this Mac (Tests/Support/TestNetGuard): a request to anywhere else is refused and
# written here, and the run fails on it even if the test that made it passed.
JAMMER_NETGUARD_LOG="${TMPDIR:-/tmp}/jammer-netguard.$$.log"
export JAMMER_NETGUARD_LOG
rm -f "$JAMMER_NETGUARD_LOG"
status=0
swift test "$@" || status=$?
if [ -s "$JAMMER_NETGUARD_LOG" ]; then
  echo "test.sh: tests asked for addresses that are not this Mac (refused by the guard):" >&2
  sort "$JAMMER_NETGUARD_LOG" | uniq -c >&2
  status=1
fi
rm -f "$JAMMER_NETGUARD_LOG"
exit $status
