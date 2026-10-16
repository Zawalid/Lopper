#!/usr/bin/env bash
# Prints the Homebrew formula for a published release of the lop command line tool, with its checksum filled in.
#
#   scripts/formula.sh 0.2.0 > ../homebrew-lopper/Formula/lop.rb
#
# Run it after the release workflow has finished: it reads the tarball's checksum file from GitHub.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/formula.sh <version>}"
SHA="$(curl -fsSL "https://github.com/Zawalid/Lopper/releases/download/v$VERSION/lop-$VERSION-macos.tar.gz.sha256" | cut -d' ' -f1)"
[ -n "$SHA" ] || { echo "no checksum found for v$VERSION" >&2; exit 1; }
sed -e "s/@VERSION@/$VERSION/g" -e "s/@SHA256@/$SHA/" packaging/homebrew/lop.rb
