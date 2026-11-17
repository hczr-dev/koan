#!/bin/bash
# Usage: scripts/custom/sync-upstream.sh [--build]
# Brings upstream Yab's main into the custom branch, keeping ours: fetches
# origin, moves the local main to it, and merges it into custom. Git's
# rerere remembers how a conflict was settled, so the same one is settled
# once. With --build, the Dev app is built again (scripts/custom/build-dev.sh).
# Changes nothing on uncommitted work, or on a conflict it has not seen
# settled before: it says which files, and leaves the branch as it was.
set -euo pipefail
cd "$(dirname "$0")/../.."
BRANCH=custom
say() { echo "sync: $*"; [ -n "${YAB_SYNC_NOTIFY:-}" ] && osascript -e "display notification \"$*\" with title \"Yab Dev\"" >/dev/null 2>&1 || true; }
git config rerere.enabled true
git config rerere.autoupdate true
HERE="$(git rev-parse --abbrev-ref HEAD)"
[ "$HERE" = "$BRANCH" ] || { say "on $HERE, not $BRANCH: nothing merged"; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { say "uncommitted changes: nothing merged"; exit 1; }
git fetch --quiet origin main
git branch -f main origin/main >/dev/null
NEW="$(git rev-list --count HEAD..origin/main)"
if [ "$NEW" = 0 ]; then
  say "up to date with upstream main"
  [ "${1:-}" = --build ] || exit 0
  [ -n "${YAB_SYNC_ALWAYS_BUILD:-}" ] || exit 0
else
  if git merge --no-edit -m "Merge upstream main into custom" origin/main >/dev/null 2>&1; then
    say "merged $NEW upstream commit(s)"
  elif [ -z "$(git diff --name-only --diff-filter=U)" ]; then
    # Every conflict settled the way it was settled before (rerere).
    git commit --no-edit >/dev/null
    say "merged $NEW upstream commit(s), conflicts settled as before"
  else
    FILES="$(git diff --name-only --diff-filter=U | tr '\n' ' ')"
    git merge --abort
    say "conflicts with upstream in: $FILES(nothing merged)"
    exit 2
  fi
fi
if [ "${1:-}" = --build ]; then
  if bash scripts/custom/build-dev.sh > build/sync-build.log 2>&1; then say "built the new Yab Dev"; else say "build failed: build/sync-build.log"; exit 3; fi
fi
