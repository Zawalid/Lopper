#!/usr/bin/env bash
# Records the product tour: builds the Debug app, runs it against the demo world, and lets it perform the scripted tour
# while it photographs its own window (App/LopperApp/Preview/DemoTour.swift). The app quits when the tour ends.
#
#   scripts/footage/capture.sh <capture dir>
#
# The capture dir must be new or empty. Do not use the Mac while it runs (about 100 seconds): the window has to stay
# in front. The tour removes things from the demo world and undoes them again; rebuild the world afterwards if you
# want the exact starting state (scripts/demo-world/build.sh <dir> --force).
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT="${1:?usage: capture.sh <capture dir>}"
if [ -d "$OUT" ] && [ -n "$(ls -A "$OUT")" ]; then
  echo "$OUT is not empty; use a new folder (this script never deletes anything)" >&2
  exit 1
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

(cd App && xcodegen generate >/dev/null)
xcodebuild build -project App/Lopper.xcodeproj -scheme Lopper -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/dev -quiet

LOPPER_DEMO_TOUR=1 LOPPER_CAPTURE_DIR="$OUT" scripts/demo-world/run.sh
[ -f "$OUT/events.json" ] || { echo "the tour did not finish: no events.json in $OUT" >&2; exit 1; }
echo "captured $(ls "$OUT" | grep -c '\.jpg$') frames in $OUT"
