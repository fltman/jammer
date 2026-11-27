#!/bin/zsh
# Builds the small tools the GUI checks use (scripts/gui/*.swift) into build/tools/, and the menus reader
# (scripts/menus/main.swift) into build/menus. It takes the build lock itself; never run it under the GUI lock:
# with-app.sh and ax-audit.sh, which run under the GUI lock, only check that they are there and current.
set -eu
# Builds only under the series' build lock (re-entrant: under precommit or commit-checked it runs as it is;
# scripts/check-build-lock.py holds every script that builds to this).
apps_tools="$(cd "$(dirname "$0")/../.." && pwd)/the-apps/tools"
case ":${APPS_HELD_LOCKS:-}:" in *":/tmp/the-apps-build.lock:"*) ;; *) [ ! -x "$apps_tools/with-build-lock.sh" ] || exec "$apps_tools/with-build-lock.sh" jammer --wait "${BUILD_WAIT:-3600}" -- "$0" "$@" ;; esac
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/build/tools"
for src in "$root"/scripts/gui/*.swift; do
  out="$root/build/tools/$(basename "$src" .swift)"
  if [[ ! -x "$out" || "$src" -nt "$out" ]]; then
    swiftc -O "$src" -o "$out"
    echo "build-gui-tools: $(basename "$out")"
  fi
done
if [[ ! -x "$root/build/menus" || "$root/scripts/menus/main.swift" -nt "$root/build/menus" ]]; then
  xcrun swiftc -O -o "$root/build/menus" "$root/scripts/menus/main.swift"
  echo "build-gui-tools: menus"
fi
