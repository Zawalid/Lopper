#!/usr/bin/env bash
# Builds the update feed for a release: a signed zip of the app and the appcast Sparkle reads.
#
#   scripts/appcast.sh 0.5.0                 uses build/Lopper.app and build/notes.md, key from the login keychain
#   SPARKLE_ED_PRIVATE_KEY=... scripts/appcast.sh 0.5.0     key given as text (CI)
#
# Writes build/appcast/Lopper-<version>.zip and build/appcast/appcast.xml. Attach both to the GitHub release: the app
# reads releases/latest/download/appcast.xml. The EdDSA private key signs the zip. Whoever holds it can ship an update
# to every install, and losing it strands every install, so it lives in a GitHub secret and an offline backup.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/appcast.sh <version>}"
APP="${APP:-build/Lopper.app}"
NOTES="${NOTES:-build/notes.md}"
ACCOUNT="${SPARKLE_ACCOUNT:-lopper}"
SPARKLE_VERSION="${SPARKLE_VERSION:-2.10.0}"
OUT="build/appcast"

[ -d "$APP" ] || { echo "no app at $APP; run scripts/build-app.sh first" >&2; exit 1; }

# The tools come with the Sparkle package the app already builds against; download the same release if they are not there.
find_tools() {
  [ -n "${SPARKLE_BIN:-}" ] && [ -x "$SPARKLE_BIN/generate_appcast" ] && { echo "$SPARKLE_BIN"; return; }
  local found
  found="$(find build "$HOME/Library/Developer/Xcode/DerivedData" -path '*artifacts/sparkle/Sparkle/bin/generate_appcast' 2>/dev/null | head -1)"
  [ -n "$found" ] && { dirname "$found"; return; }
  local dir="build/sparkle-$SPARKLE_VERSION"
  if [ ! -x "$dir/bin/generate_appcast" ]; then
    mkdir -p "$dir"
    curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
      | tar -xJ -C "$dir"
  fi
  echo "$dir/bin"
}
BIN="$(find_tools)"

find "$OUT" -mindepth 1 -delete 2>/dev/null || true
mkdir -p "$OUT"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/Lopper-$VERSION.zip"
# Sparkle shows these notes in the update window, in place of a web page.
if [ -s "$NOTES" ]; then cp "$NOTES" "$OUT/Lopper-$VERSION.md"; fi

KEY_ARGS=(--account "$ACCOUNT")
if [ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
  KEY_FILE="$(mktemp)"
  trap 'rm -f "$KEY_FILE"' EXIT
  printf '%s' "$SPARKLE_ED_PRIVATE_KEY" > "$KEY_FILE"
  KEY_ARGS=(--ed-key-file "$KEY_FILE")
fi

"$BIN/generate_appcast" "${KEY_ARGS[@]}" \
  --download-url-prefix "https://github.com/Zawalid/Lopper/releases/download/v$VERSION/" \
  --link "https://lopper.zawalid.com" \
  --maximum-versions 1 \
  --embed-release-notes \
  "$OUT"

[ -s "$OUT/appcast.xml" ] || { echo "no appcast was written" >&2; exit 1; }
grep -q "sparkle:edSignature" "$OUT/appcast.xml" || { echo "the appcast has no signature" >&2; exit 1; }
echo "wrote $OUT/appcast.xml and $OUT/Lopper-$VERSION.zip"
