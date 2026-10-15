#!/usr/bin/env bash
# Renders the key screens (light and dark) to PNG files for design review, without opening any window.
# usage: scripts/render-screens.sh [output-dir]    (default: build/renders)
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-build/renders}"
mkdir -p "$OUT"
(cd App && xcodegen generate)
# xcodebuild only forwards environment variables to the test host when they carry this prefix.
TEST_RUNNER_LOPPER_RENDER_DIR="$(cd "$OUT" && pwd)" xcodebuild test \
  -project App/Lopper.xcodeproj -scheme Lopper -destination 'platform=macOS' \
  -only-testing:LopperAppTests/OverviewRenderTests \
  -only-testing:LopperAppTests/InspectorRenderTests \
  -only-testing:LopperAppTests/SheetAndMenuRenderTests | tail -3
ls "$OUT"
