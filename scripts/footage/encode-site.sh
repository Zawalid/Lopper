#!/usr/bin/env bash
# Encodes the website's tour clips and hero loop from the clips made by cut.py.
#
#   scripts/footage/encode-site.sh <clips dir> <media dir>
#
# Writes film-{evidence,agents,disk,clean,undo}-{2560,1920}.mp4 and hero-{2560,1920}.mp4, plus the still that stands
# in for each before its video loads (film-<name>-<w>.webp, hero-poster-<w>.webp). 24 fps, closed keyframes every
# 16 frames so scrubbing with the scroll stays smooth, no sound. The overview and "only here" stills come from the
# screenshots instead: scripts/footage/site-stills.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."

CLIPS="${1:?usage: encode-site.sh <clips dir> <media dir>}"
OUT="${2:?usage: encode-site.sh <clips dir> <media dir>}"
CLIPS="$(cd "$CLIPS" && pwd)"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
ROOT="$PWD"
WORK="$(mktemp -d)"
cd "$WORK"
mkdir png

# Near-lossless trims at full size. The numbers cut the lead-in of each clip so a chapter starts on its action.
trim() { ffmpeg -loglevel error -y -ss "$2" ${3:+-to "$3"} -i "$CLIPS/$1.mp4" -an -c:v libx264 -crf 6 -preset fast "$4"; }
trim repository 1.05 "" n-evidence.mp4
trim agents 1.2 "" n-agents.mp4
trim disk 1.0 "" n-disk.mp4
trim clean-review 0.85 "" n-c1.mp4
trim clean-run 0 "" n-c2.mp4
trim clean-done 0 "" n-c3.mp4
trim clean-toast 0.6 6.7 n-u1.mp4
trim history 0.9 "" n-u2.mp4
trim overview 0.85 "" n-ov.mp4
printf "file n-c1.mp4\nfile n-c2.mp4\nfile n-c3.mp4\n" > nc.txt
printf "file n-u1.mp4\nfile n-u2.mp4\n" > nu.txt
ffmpeg -loglevel error -y -f concat -safe 0 -i nc.txt -c copy n-clean.mp4
ffmpeg -loglevel error -y -f concat -safe 0 -i nu.txt -c copy n-undo.mp4

encode() { # <input> <output> <width> <gop>
  local vf="fps=24,format=yuv420p"
  [ "$3" = 1920 ] && vf="fps=24,scale=1920:-2:flags=lanczos,format=yuv420p"
  ffmpeg -loglevel error -y -i "$1" -an -vf "$vf" -c:v libx264 -preset slow -tune stillimage -crf 20 \
    -g "$4" -keyint_min "$4" -sc_threshold 0 -movflags +faststart -profile:v high -level 5.1 "$2"
}

for n in evidence agents disk clean undo; do
  for w in 2560 1920; do encode "n-$n.mp4" "$OUT/film-$n-$w.mp4" "$w" 16; done
  ffmpeg -loglevel error -y -i "n-$n.mp4" -frames:v 1 "png/film-$n.png"
done

# The hero loop is one continuous visit: overview, a repository, agents, disk.
printf "file n-ov.mp4\nfile $CLIPS/repository.mp4\nfile $CLIPS/agents.mp4\nfile $CLIPS/disk.mp4\n" > hero.txt
ffmpeg -loglevel error -y -f concat -safe 0 -i hero.txt -an -c:v libx264 -crf 6 -preset fast n-hero.mp4
for w in 2560 1920; do encode n-hero.mp4 "$OUT/hero-$w.mp4" "$w" 96; done
ffmpeg -loglevel error -y -i n-hero.mp4 -frames:v 1 png/hero-poster.png

# Stills for the moment before a video loads.
node "$ROOT/scripts/footage/posters.mjs" "$WORK/png" "$OUT"

# Clean up the scratch folder (only the files made above, then the empty folder).
find "$WORK" -type f -delete
find "$WORK" -mindepth 1 -type d -delete
rmdir "$WORK"
ls -la "$OUT" | grep -E "film-(evidence|agents|disk|clean|undo)|hero"
