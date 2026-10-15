#!/usr/bin/env bash
# Packs build/Lopper.app into build/Lopper.dmg with an Applications shortcut.
# Notarize afterwards (needs an Apple Developer account):
#   xcrun notarytool submit build/Lopper.dmg --keychain-profile "<profile>" --wait
#   xcrun stapler staple build/Lopper.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

[ -d build/Lopper.app ] || { echo "run scripts/build-app.sh first" >&2; exit 1; }
rm -rf build/dmg-root build/Lopper.dmg
mkdir -p build/dmg-root
cp -R build/Lopper.app build/dmg-root/
ln -s /Applications build/dmg-root/Applications
hdiutil create -volname "Lopper" -srcfolder build/dmg-root -ov -format UDZO build/Lopper.dmg >/dev/null
rm -rf build/dmg-root
echo "built build/Lopper.dmg"
