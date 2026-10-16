# Lopper

Lopper keeps your repositories light. It finds the branches, worktrees and generated folders you no longer
need, shows the evidence for why each one is safe to remove, removes it to the Trash, and lets you undo
anything for 30 days.

It is a native macOS app (SwiftUI) with a small Swift engine underneath. Everything stays on your Mac: no
account, no upload, no telemetry.

<!-- screenshots: docs/images/overview.png, disk.png, history.png, menubar.png -->

## What it does

- **Branches and worktrees.** Merged branches and finished worktrees are marked safe, with the git evidence
  behind each verdict. Anything that holds work that exists nowhere else is protected or flagged for a look.
- **Agents.** Worktrees left behind by Claude Code, Cursor and Codex: how old, whether they have unmerged or
  uncommitted work, and which are finished and can be reclaimed in one step.
- **Disk.** Generated folders (`node_modules`, build output, caches) grouped by project, by kind, or as a map,
  plus developer caches outside your projects. Clearing moves folders to the Trash; reinstalling is optional.
- **History and undo.** Every removal is logged. Restore one item or a whole cleanup. Branches come back at
  their exact commit.
- **Rules.** Offer-only suggestions such as "branches merged more than 14 days ago". Lopper never deletes
  anything on its own: you review and confirm every cleanup.
- **Menu bar.** A glance at what can be reclaimed, with one click to review.

## Safety model

Lopper's job is to never remove work that exists nowhere else.

- A branch is offered only when git confirms its commits are already part of the default branch (or a merged
  pull request, when the GitHub CLI is available).
- Worktrees holding uncommitted changes or commits that exist nowhere else are never offered as safe.
- Generated folders are cleared only when they are git-ignored, are not symlinks, and are verified again right
  before they move to the Trash.
- Nothing is permanently deleted unless you empty the Trash. The one exception is the optional "delete for
  good", which only touches items Lopper itself moved to the Trash.

## Requirements

- macOS 14 or later
- Git on your `PATH` (install the Xcode command line tools with `xcode-select --install`)
- Optional: the [GitHub CLI](https://cli.github.com) (`gh`) for pull request based merge detection

## Build from source

You need Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
git clone <repository url> Lopper
cd Lopper/App && xcodegen generate && open Lopper.xcodeproj
```

Or build and run a Debug build from the terminal:

```bash
scripts/dev.sh
```

Run the tests:

```bash
swift test                                   # engine
cd App && xcodegen generate && xcodebuild test -project Lopper.xcodeproj -scheme Lopper -destination 'platform=macOS'
```

To try Lopper on throwaway data instead of your own repositories, build the demo world:

```bash
scripts/demo-world/build.sh ~/LopperDemo
scripts/demo-world/run.sh
```

See [docs/development.md](docs/development.md) for the rest of the development loop and
[docs/roadmap.md](docs/roadmap.md) for what is planned.

## Project layout

- `Sources/Lopper`: the engine (no UI): scanning, classification, cleaning, undo.
- `Tests/LopperTests`: engine tests, using real git repositories created on the fly.
- `App/LopperApp`: the SwiftUI app.
- `scripts`: dev loop, packaging and the demo world.
- `docs`: development notes, the settings file format, the roadmap.

## Contributing

Issues and pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) first; changes to anything that
deletes things need tests that prove the safety rules still hold.

## License

[MIT](LICENSE)
