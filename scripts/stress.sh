#!/bin/sh
# The multi-hour stress test (a 3-hour WAV through peaks, zoom, edits, loudness
# and a bit-exact export). Release build, so the timings mean something.
# Needs about 5 GB free; the files are removed afterwards. Writes docs/STRESS.md.
#   scripts/stress.sh              3 hours
#   JAMMER_STRESS_HOURS=0.1 scripts/stress.sh   a quick run
set -eu
# Builds only under the series' build lock (re-entrant: under precommit or commit-checked it runs as it is;
# scripts/check-build-lock.py holds every script that builds to this).
apps_tools="$(cd "$(dirname "$0")/../.." && pwd)/the-apps/tools"
case ":${APPS_HELD_LOCKS:-}:" in *":/tmp/the-apps-build.lock:"*) ;; *) [ ! -x "$apps_tools/with-build-lock.sh" ] || exec "$apps_tools/with-build-lock.sh" jammer --wait "${BUILD_WAIT:-3600}" -- "$0" "$@" ;; esac
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/Packages/JammerKit"
JAMMER_STRESS=1 JAMMER_STRESS_REPORT="${JAMMER_STRESS_REPORT:-$root/docs/STRESS.md}" \
    swift test -c release -Xswiftc -enable-testing --filter StressTests "$@"
