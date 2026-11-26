#!/bin/zsh
# Builds the small tools the GUI checks use (scripts/gui/*.swift) into build/tools/. Run it under the build lock,
# never under the GUI lock: with-app.sh, which runs under the GUI lock, only checks that they are there and current.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/build/tools"
for src in "$root"/scripts/gui/*.swift; do
  out="$root/build/tools/$(basename "$src" .swift)"
  if [[ ! -x "$out" || "$src" -nt "$out" ]]; then
    swiftc -O "$src" -o "$out"
    echo "build-gui-tools: $(basename "$out")"
  fi
done
