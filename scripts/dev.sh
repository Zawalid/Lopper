#!/usr/bin/env bash
# Fast development loop: quit the running app, rebuild a Debug build, relaunch it.
#
#   scripts/dev.sh            build and open once
#   scripts/dev.sh --watch    keep running: save a file under App/ or Sources/ and the app relaunches
#   scripts/dev.sh --logs     build, open, then stream the app's log output
#
# Builds go to build/dev (ignored by git), so the app path is stable and Xcode's own build is untouched.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/dev/Build/Products/Debug/Lopper.app"
MODE="${1:-once}"

build_and_open() {
  local started=$SECONDS
  (cd App && xcodegen generate >/dev/null)
  if ! xcodebuild build \
      -project App/Lopper.xcodeproj -scheme Lopper -configuration Debug \
      -destination 'platform=macOS' -derivedDataPath build/dev -quiet 2>build/dev-errors.log; then
    echo "build failed:"
    grep -E "error:" build/dev-errors.log | head -10
    return 1
  fi
  pkill -x Lopper 2>/dev/null || true
  sleep 0.3
  open "$APP"
  echo "relaunched in $((SECONDS - started))s"
}

# A fingerprint of every source file the app depends on; changes when anything is saved.
fingerprint() {
  find App/LopperApp Sources/Lopper -name '*.swift' -o -name '*.yml' -o -name '*.json' 2>/dev/null \
    | sort | xargs stat -f '%N %m' 2>/dev/null | shasum | cut -d' ' -f1
}

mkdir -p build
case "$MODE" in
  --watch)
    build_and_open || true
    last="$(fingerprint)"
    echo "watching for changes (Ctrl-C to stop)"
    while true; do
      sleep 1
      now="$(fingerprint)"
      if [ "$now" != "$last" ]; then
        last="$now"
        echo "change detected"
        build_and_open || true
      fi
    done
    ;;
  --logs)
    build_and_open
    exec /usr/bin/log stream --style compact --predicate 'process == "Lopper"'
    ;;
  *)
    build_and_open
    ;;
esac
