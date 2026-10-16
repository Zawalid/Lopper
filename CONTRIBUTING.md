# Contributing to Lopper

Thanks for helping. Lopper deletes things on people's machines, so the bar for changes that touch removal is
high, and the bar for everything else is just "clear and tested".

## Set up

```bash
brew install xcodegen
cd App && xcodegen generate && open Lopper.xcodeproj
```

`App/Lopper.xcodeproj` is generated from `App/project.yml` and is not committed. Run `xcodegen generate` again
after adding or removing files. See [docs/development.md](docs/development.md) for the fast dev loop.

## Before you open a pull request

1. Run the engine tests: `swift test`.
2. Run the app tests: `cd App && xcodebuild test -project Lopper.xcodeproj -scheme Lopper -destination 'platform=macOS'`.
3. Add a test with the change. Engine tests use real git repositories (`TestRepo`); do not mock git.
4. Never point a build under test at your own folders. Use `scripts/demo-world/build.sh` or
   `scripts/make-agent-fixtures.sh` for throwaway data, and set `LOPPER_SUPPORT_DIR` so your real settings and
   undo history are not touched.

## Rules for changes that remove things

- Re-verify the evidence right before removing, not only when scanning.
- A removal must be undoable, or must say clearly that it is not and need an explicit confirmation.
- Never follow symlinks out of a folder you were asked to clear.
- Add a test for the case that would lose work, and watch it fail first.

## Style

- Swift 6, SwiftUI with Observation. Keep views small; put logic in models that are unit tested.
- User-facing text is plain and specific. No marketing words, no emoji.
- Commit messages: `type: lowercase subject` (for example `fix: keep the saved branch when removing an agent worktree`).

## Reporting bugs

Open an issue with your macOS version, the Lopper version, and what you expected. If Lopper removed something
it should not have, say so at the top and attach the relevant lines of
`~/Library/Application Support/Lopper/undo-log.jsonl`. For security problems see [SECURITY.md](SECURITY.md).
