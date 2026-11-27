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
lock_tool=/Users/andersbj/Projekt/the-apps/tools/with-build-lock.sh

# The tree as it is: its hash through an index of its own (tracked and new files, AGENTS.md left out), and a marker
# whose time every file is held to. A file changed during the gate and put back has the same content but a newer time.
tree_hash() { local idx; idx=$(mktemp); cp .git/index "$idx" 2>/dev/null; GIT_INDEX_FILE="$idx" git add -A -- . ':!AGENTS.md' >/dev/null 2>&1; GIT_INDEX_FILE="$idx" git write-tree; rm -f "$idx"; }
touched_since() { { git ls-files -z --cached; git ls-files -z --others --exclude-standard; } | xargs -0 sh -c 'find "$@" -maxdepth 0 -newer "$MARKER" -print 2>/dev/null' sh | grep -vx 'AGENTS.md'; }

if [[ "${1:-}" == "--self-test" ]]; then
  # A repository of its own with a gate that changes a file and puts it back, one that leaves it changed, and one
  # that touches nothing: the first two must commit nothing, the third must commit.
  st=$(mktemp -d "${TMPDIR:-/tmp}/commit-checked-selftest.XXXXXX"); trap 'rm -rf "$st"' EXIT
  failed=0
  for case in restored changed clean; do
    rm -rf "$st/r"; mkdir -p "$st/r/scripts"; cd "$st/r"
    git init -q; git config user.name "commit-checked self-test"; git config user.email "self-test@localhost"
    echo one > a.txt; echo build/ > .gitignore; git add -A; git commit -qm start
    # The copy runs its gate without the series' build lock: these gates build nothing, and three turns in the queue
    # behind the other apps' builds would hold the self-test for nothing.
    printf '#!/bin/zsh\nwhile [[ $# -gt 0 && "$1" != -- ]]; do shift; done; shift; exec "$@"\n' > "$st/nolock"; chmod +x "$st/nolock"
    sed "s|^lock_tool=.*|lock_tool=$st/nolock|" "$OLDPWD/scripts/commit-checked.sh" > scripts/commit-checked.sh; chmod +x scripts/commit-checked.sh
    case $case in
      restored) gate='mkdir -p build; cp a.txt build/a.keep; echo two > a.txt; sleep 1; cp build/a.keep a.txt' ;;
      changed) gate='echo two > a.txt' ;;
      clean) gate='true' ;;
    esac
    printf '#!/bin/zsh\n%s\necho "precommit: green"\n' "$gate" > scripts/precommit.sh; chmod +x scripts/precommit.sh
    git add scripts .gitignore; git commit -qm gate
    echo three > b.txt; echo "self-test" > "$st/msg"
    before=$(git rev-parse HEAD)
    scripts/commit-checked.sh "$st/msg" b.txt >/dev/null 2>&1; rc=$?
    after=$(git rev-parse HEAD)
    if [[ $case == clean ]]; then [[ $rc == 0 && $after != $before ]] || { echo "commit-checked self-test: a clean gate didn't commit (rc $rc)"; failed=1; }
    else [[ $rc != 0 && $after == $before ]] || { echo "commit-checked self-test: a gate that $case a file committed (rc $rc)"; failed=1; }; fi
    cd "$OLDPWD"
  done
  (( failed )) && exit 1
  echo "commit-checked self-test: a file changed and put back, and one left changed, commit nothing; a clean gate commits"
  exit 0
fi

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
# The tree as it is now, held against the tree after the gate: an edit made while the gate ran, even one put back
# before it ended (2026-11-27, twice), means the gate tested something else. By content and by time.
export MARKER="build/precommit/commit-checked.marker"
before=$(tree_hash)
touch "$MARKER"
"$lock_tool" jammer --wait 7200 -- scripts/precommit.sh > "$out" 2>&1
rc=$?
tail -1 "$out"
if (( rc != 0 )); then echo "commit-checked: the gate exited $rc; nothing committed (the log: $out)." >&2; exit 1; fi
touched=$(touched_since)
if [[ -n "$touched" || "$(tree_hash)" != "$before" ]]; then
  echo "commit-checked: files were changed while the gate ran, so it didn't test what would be committed; nothing committed. Run it again." >&2
  [[ -n "$touched" ]] && printf '  %s\n' ${(f)touched} >&2
  exit 1
fi
git add -- "$@" && git commit -q -F "$msg" && git log --oneline -1
