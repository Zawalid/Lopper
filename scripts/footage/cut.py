#!/usr/bin/env python3
"""Cuts one clip per shot from a capture made by capture.sh.

    scripts/footage/cut.py <capture dir> <clips dir>

The capture is a folder of JPEG frames plus frames.json (when each frame was taken) and events.json (when each shot
started and ended). Frames arrive at uneven times, so each clip is built with the real gap between frames and then
resampled to 30 fps. Each shot gets a little lead and tail so the camera moves have room; the clean run, which takes
half a minute, is sped up five times.
"""
import json, os, subprocess, sys

# name, seconds before the shot starts, seconds after it ends, speed-up
SHOTS = [
    ("overview", 0.6, 0.4, 1),
    ("repository", 0.6, 0.4, 1),
    ("agents", 0.6, 0.4, 1),
    ("disk", 0.6, 0.4, 1),
    ("history", 0.6, 0.4, 1),
    ("clean-review", 0.3, 0.4, 1),
    ("clean-run", 0.2, 0.3, 5),
    ("clean-done", 0.2, 0.3, 1),
    ("clean-toast", 0.2, 0.4, 1),
]


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    capture, clips = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    frames = json.load(open(os.path.join(capture, "frames.json")))
    events = {e["name"]: e for e in json.load(open(os.path.join(capture, "events.json")))}
    os.makedirs(clips, exist_ok=True)
    lists = os.path.join(clips, "lists")
    os.makedirs(lists, exist_ok=True)

    for name, pre, post, speed in SHOTS:
        if name not in events:
            sys.exit(f"the capture has no shot called {name}")
        t0, t1 = events[name]["start"] - pre, events[name]["end"] + post
        picked = [f for f in frames if t0 <= f["t"] <= t1]
        if len(picked) < 2:
            sys.exit(f"shot {name} has fewer than two frames")
        lines = []
        for a, b in zip(picked, picked[1:]):
            lines.append("file '%s/f%06d.jpg'\nduration %.5f" % (capture, a["i"], b["t"] - a["t"]))
        lines.append("file '%s/f%06d.jpg'" % (capture, picked[-1]["i"]))
        listing = os.path.join(lists, name + ".txt")
        open(listing, "w").write("\n".join(lines) + "\n")
        vf = "fps=30" if speed == 1 else "fps=%d,setpts=PTS/%d,fps=30" % (30 * speed, speed)
        out = os.path.join(clips, name + ".mp4")
        subprocess.run(
            ["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", listing, "-vf", vf, "-an",
             "-c:v", "libx264", "-crf", "15", "-preset", "medium", "-pix_fmt", "yuv420p", "-movflags", "+faststart", out],
            check=True)
        length = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", out],
            capture_output=True, text=True).stdout.strip()
        print(f"{name}: {t1 - t0:.1f}s of tour -> {float(length):.1f}s clip", flush=True)


main()
