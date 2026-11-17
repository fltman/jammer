#!/bin/zsh
# No script reaches the network for third-party code on its own. A script that clones, downloads,
# resolves or installs must carry the guard (JAMMER_FETCH_ALLOWED, set only after Anders has said yes
# in the session's own window); and the package has no dependency that a build would go and fetch.
# Loopback (the app's own agent API) is not the network.
set -u
cd "$(dirname "$0")/.."
bad=0
for f in scripts/*.sh scripts/*.py; do
  [[ $f == scripts/check-fetch-guard.sh ]] && continue
  # Lines that do the fetching (comments and messages that only name a tool don't count).
  hits=$(grep -nE '^[^#]*(git +(clone|fetch|pull)|curl [^|]*https?://|wget |cargo +(build|fetch|install)|pip3? +install|brew +install|npm +(ci|install)|swift +package +(resolve|update)|-resolvePackageDependencies|FetchContent|cmake +-S)' "$f" | grep -vE '127\.0\.0\.1|localhost|echo |\$B/' )
  [[ -z "$hits" ]] && continue
  if ! grep -q 'JAMMER_FETCH_ALLOWED:-}" = "yes" \] ||' "$f"; then
    echo "check-fetch-guard: $f can fetch or build third-party code and has no guard:"; echo "$hits" | head -3 | sed 's/^/    /'; bad=1
  fi
done
# The Swift package and the Xcode project name only what is in this repository.
if grep -nE '\.package\( *url:' Packages/JammerKit/Package.swift; then echo "check-fetch-guard: Package.swift has a dependency by URL; a build would fetch it"; bad=1; fi
if grep -nE '^ +url:' project.yml; then echo "check-fetch-guard: project.yml has a package by URL; a build would fetch it"; bad=1; fi
[[ $bad == 0 ]] && echo "check-fetch-guard: every script that can fetch third-party code waits for a yes, and no build resolves a package from outside"
exit $bad
