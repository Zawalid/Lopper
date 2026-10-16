#!/usr/bin/env bash
# Starts the dev build of Lopper against the demo world, completely separate from your real settings and your
# real undo history.
#
# Usage:  scripts/demo-world/run.sh [--world <dir>] [--reset-settings] [--no-refresh] [path to the Lopper binary]
#
#   --world <dir>      the world built by build.sh (default: LOPPER_DEMO_WORLD, else <projects>/LopperDemo,
#                      a sibling of the Lopper checkout)
#   --reset-settings   rewrite <world>-support/settings.json (only the five demo folders)
#   --no-refresh       leave the "active" agent worktrees as they are instead of touching their files now
#   binary             default: build/dev/Build/Products/Debug/Lopper.app/Contents/MacOS/Lopper
#
# The app runs with LOPPER_SUPPORT_DIR=<world>-support (for example ~/Personal/Projects/LopperDemo-support).
# That folder holds settings.json (the demo folders as scanned roots) and undo-log.jsonl (the History page), so
# the real ~/Library/Application Support/Lopper is never read or written.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

# The main checkout of this repository, even when this script runs from a worktree of it.
COMMON_GIT="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)"
MAIN_CHECKOUT="$(dirname "$COMMON_GIT")"
WORKTREE_ROOT="$(git -C "$HERE" rev-parse --show-toplevel)"

WORLD="${LOPPER_DEMO_WORLD:-$(dirname "$MAIN_CHECKOUT")/LopperDemo}"
RESET=0
REFRESH=1
BINARY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --world) WORLD="$2"; shift ;;
    --reset-settings) RESET=1 ;;
    --no-refresh) REFRESH=0 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) BINARY="$1" ;;
  esac
  shift
done

WORLD="$(cd "$WORLD" 2>/dev/null && pwd -P)" || die "the demo world does not exist yet: run scripts/demo-world/build.sh first"
[ -f "$WORLD/.demo-world/MARKER" ] || die "$WORLD was not created by build.sh"
SUPPORT="$WORLD-support"

if [ -z "$BINARY" ]; then
  for candidate in \
    "$WORKTREE_ROOT/build/dev/Build/Products/Debug/Lopper.app/Contents/MacOS/Lopper" \
    "$MAIN_CHECKOUT/build/dev/Build/Products/Debug/Lopper.app/Contents/MacOS/Lopper"; do
    if [ -x "$candidate" ]; then BINARY="$candidate"; break; fi
  done
fi
[ -n "$BINARY" ] && [ -x "$BINARY" ] || die "no Lopper binary found: build it with scripts/dev.sh or pass its path"

mkdir -p "$SUPPORT"
if [ "$RESET" = 1 ] || [ ! -f "$SUPPORT/settings.json" ]; then
  write_settings "$SUPPORT" "$WORLD"
  echo "wrote $SUPPORT/settings.json"
fi
[ -f "$SUPPORT/undo-log.jsonl" ] || echo "note: $SUPPORT/undo-log.jsonl is missing; the History page will start empty"

# "Active" agent worktrees must look like someone is working in them right now, whenever the world was built.
if [ "$REFRESH" = 1 ] && [ -f "$WORLD/.demo-world/active-worktrees.txt" ]; then
  while IFS= read -r dir; do
    if [ -d "$dir" ]; then find "$dir" -exec touch {} +; fi
  done < "$WORLD/.demo-world/active-worktrees.txt"
fi

echo "world   : $WORLD"
echo "support : $SUPPORT"
echo "binary  : $BINARY"
exec env LOPPER_SUPPORT_DIR="$SUPPORT" "$BINARY"
