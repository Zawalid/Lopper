#!/bin/bash
# Times `lop` against a world made by scripts/stress/build.py, with settings in a throwaway folder.
# Usage: scripts/stress/measure.sh <world-folder>
set -euo pipefail
world="${1:?usage: measure.sh <world-folder>}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
swift build -c release --product lop --package-path "$root" >/dev/null
lop="$root/.build/release/lop"
export LOPPER_SUPPORT_DIR="$(mktemp -d)"
run() {
  local label="$1"; shift
  /usr/bin/time -l "$@" >/dev/null 2>"$LOPPER_SUPPORT_DIR/time.txt" || true
  local secs rss
  secs=$(awk '/real/ {print $1}' "$LOPPER_SUPPORT_DIR/time.txt")
  rss=$(awk '/maximum resident set size/ {printf "%.0f", $1/1048576}' "$LOPPER_SUPPORT_DIR/time.txt")
  printf "%-26s %8ss  %6s MB peak\n" "$label" "$secs" "$rss"
}
run "scan (no gh)"        "$lop" scan --no-gh --folder "$world"
run "list --safe (no gh)" "$lop" list --safe --no-gh --folder "$world"
run "agents (no gh)"      "$lop" agents --no-gh --folder "$world"
run "disk (no gh)"        "$lop" disk --no-gh --folder "$world"
run "risk (no gh)"        "$lop" risk --no-gh --folder "$world"
echo "world: $(find "$world" -maxdepth 3 -name .git | wc -l | tr -d ' ') repositories"
