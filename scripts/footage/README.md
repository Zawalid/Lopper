# Product footage

How the website's tour clips and hero loop are made, from the running app to the files in `website/public/media`.
Everything is real: the app photographs its own window, so no screen recording permission is needed and nothing
else on your screen can end up in a clip.

| Step | Script | Output |
|---|---|---|
| 1. Record the tour | `capture.sh <capture dir>` | JPEG frames, `frames.json`, `events.json` |
| 2. Cut one clip per shot | `cut.py <capture dir> <clips dir>` | `overview.mp4`, `repository.mp4`, `agents.mp4`, `disk.mp4`, `history.mp4`, `clean-*.mp4` (2560x1600, 30 fps) |
| 3. Encode for the site | `encode-site.sh <clips dir> <media dir>` | `film-*-{2560,1920}.mp4`, `hero-{2560,1920}.mp4` and their poster stills |
| Stills | `site-stills.sh` | `film-overview-*.webp` and `film-onlyhere-*.webp` from the screenshots in `docs/images` |

```bash
scripts/demo-world/build.sh ~/Personal/Projects/LopperDemo --force   # fresh world: the tour removes things, then undoes
scripts/footage/capture.sh build/footage-capture                     # about 100 s; leave the Mac alone while it runs
scripts/footage/cut.py build/footage-capture build/footage-clips
scripts/footage/encode-site.sh build/footage-clips website/public/media
scripts/footage/site-stills.sh
```

Needs `ffmpeg`, `python3`, Node (for `sharp`, from `website/node_modules`), `cwebp` and the demo world. The capture is
DEBUG only (`App/LopperApp/Preview/DemoTour.swift`). The tour edits the demo world, never your own repositories.
