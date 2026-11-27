#!/bin/zsh
# A commit only after a green gate, decided by the gate's exit code and never by reading its text (2026-11-26: a
# commit chained on `grep -q green` went in on "precommit: NOT green"; Flimmer's way, the coordinator).
#
#   scripts/commit-checked.sh <message file> <path> [<path> …]
#
# The paths are what is committed, and nothing else may be changed in the tree, so the gate tests exactly what goes
# in (AGENTS.md, never committed, is left out of both). The gate runs under the build lock; the commit is made only
# when scripts/precommit.sh exits 0. Not a hook: Anders's own commits don't wait for it.
set -u
cd "$(dirname "$0")/.."
msg="${1:-}"; shift 2>/dev/null || true
[[ -n "$msg" && -s "$msg" && $# -gt 0 ]] || { echo "usage: scripts/commit-checked.sh <message file> <path> [<path> …]" >&2; exit 2; }
for p in "$@"; do
  [[ "$p" == "AGENTS.md" ]] && { echo "commit-checked: AGENTS.md is never committed." >&2; exit 2; }
  [[ -e "$p" ]] || git ls-files --error-unmatch -- "$p" >/dev/null 2>&1 || { echo "commit-checked: no such path: $p" >&2; exit 2; }
done
# Everything changed in the tree must be among the paths given.
typeset -A given; for p in "$@"; do given[$p]=1; done
stray=()
while IFS= read -r line; do
  f="${line:3}"; f="${f#\"}"; f="${f%\"}"
  [[ "$f" == "AGENTS.md" ]] && continue
  [[ -n "${given[$f]:-}" ]] && continue
  # A path given as a folder covers what is in it.
  covered=0; for p in "$@"; do [[ "$f" == "$p"/* ]] && covered=1; done
  (( covered )) || stray+=("$f")
done < <(git status --porcelain --untracked-files=all)
if (( ${#stray} )); then
  echo "commit-checked: changed but not given, so the gate would test more than is committed:" >&2
  printf '  %s\n' "${stray[@]}" >&2
  exit 2
fi
out="build/precommit/commit-checked.out"; mkdir -p build/precommit
# The tree as it is now, to hold against the tree after the gate: an edit made while the gate ran (2026-11-27: the
# gate of a docs commit built and tested work begun meanwhile) means the gate tested something else.
tree() { { git diff HEAD --binary -- "$@"; git ls-files --others --exclude-standard -z -- "$@" | xargs -0 shasum 2>/dev/null; } | shasum | cut -c1-40; }
before=$(tree . ':!AGENTS.md')
/Users/andersbj/Projekt/the-apps/tools/with-build-lock.sh jammer --wait 7200 -- scripts/precommit.sh > "$out" 2>&1
rc=$?
tail -1 "$out"
if (( rc != 0 )); then echo "commit-checked: the gate exited $rc; nothing committed (the log: $out)." >&2; exit 1; fi
if [[ "$(tree . ':!AGENTS.md')" != "$before" ]]; then
  echo "commit-checked: the tree changed while the gate ran, so the gate didn't test what would be committed; nothing committed. Run it again." >&2
  exit 1
fi
git add -- "$@" && git commit -q -F "$msg" && git log --oneline -1
