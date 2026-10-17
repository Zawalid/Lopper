#!/usr/bin/env bash
# The two tour chapters that are a still, not a video, come from the screenshots in docs/images (full resolution,
# no video compression): film-overview-* and film-onlyhere-*. Run it after a screenshot capture
# (LOPPER_SCREENSHOT_DIR=docs/images scripts/demo-world/run.sh).
set -euo pipefail
cd "$(dirname "$0")/../.."
for pair in "overview:overview" "only-here:onlyhere"; do
  shot="${pair%%:*}"; key="${pair##*:}"
  for w in 1920 2560; do
    cwebp -quiet -q 86 -m 6 -resize "$w" $((w * 10 / 16)) "docs/images/$shot-dark.png" -o "website/public/media/film-$key-$w.webp"
  done
done
echo "wrote film-overview-* and film-onlyhere-* in website/public/media"
