# Developing Lopper

Run everything from the repository root (`~/Personal/Projects/Lopper`).

## See changes fast

| Command | What it does | Time |
|---|---|---|
| `scripts/dev.sh` | Quit the app, rebuild a Debug build, relaunch it | 16 s cold, about 4 s after a small change |
| `scripts/dev.sh --watch` | Same, automatically, every time you save a file under `App/` or `Sources/` | about 4 s per save |
| `scripts/dev.sh --logs` | Build, open, then stream the app's log output | |

Leave `scripts/dev.sh --watch` running in a terminal tab. When a change is made (by you or by me) the app
quits and comes back with it.

## Live previews in Xcode

```bash
cd App && xcodegen generate && open Lopper.xcodeproj
```

Open `LopperApp/Preview/Previews.swift`, then show the canvas with **Option-Command-Return**. Each
`#Preview` is one screen (Overview in each state, workbench, inspector, clean sheet, History, menu bar
popover, Settings, the whole window, and a design-system gallery). Edit a view, save, and the matching
preview updates without launching the app.

Preview data comes from `LopperApp/Preview/Fixtures.swift`. It is compiled into Debug builds only.

## Tests

```bash
swift test                                   # engine, about 1 minute
cd App && xcodegen generate && xcodebuild test -project Lopper.xcodeproj -scheme Lopper -destination 'platform=macOS'
```

The app suite includes window-level tests that put the real window on screen and drive the same clicks a
person makes. Add one when you add a page.

## Look at screens without opening the app

```bash
scripts/render-screens.sh build/renders      # light and dark PNGs of the key screens
```

## Build something to share

```bash
scripts/build-app.sh      # build/Lopper.app (ad hoc signed unless SIGN_IDENTITY is set)
scripts/make-dmg.sh       # build/Lopper.dmg
```

Signing and notarization need an Apple Developer account; see the plan, Task 13.

## Where things live

- `Sources/Lopper/`: the engine (no UI): scanning, classification, cleaning, undo.
- `App/LopperApp/`: the SwiftUI app. `Model/` state, `Services/` engine access, `Features/` one folder per
  screen, `DesignSystem/` shared components, `Preview/` debug-only sample data and previews.
- `App/project.yml`: describes the Xcode project; `App/Lopper.xcodeproj` is generated and not committed.
- `docs/`: specs, plans, roadmap, verification notes.
