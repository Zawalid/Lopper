#!/usr/bin/env bash
# Builds Lopper.app into build/. Ad hoc signed unless SIGN_IDENTITY is set (a "Developer ID Application: ..." name).
# usage: scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${SIGN_IDENTITY:--}"
(cd App && xcodegen generate)
rm -rf build/Lopper.xcarchive build/Lopper.app
xcodebuild archive \
  -project App/Lopper.xcodeproj -scheme Lopper -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath build/Lopper.xcarchive \
  CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual \
  OTHER_CODE_SIGN_FLAGS="--timestamp" | tail -3
cp -R build/Lopper.xcarchive/Products/Applications/Lopper.app build/Lopper.app
codesign --verify --deep --strict build/Lopper.app
echo "built build/Lopper.app (identity: $IDENTITY)"
