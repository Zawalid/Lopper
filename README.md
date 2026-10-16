# Lopper

Lopper keeps your repositories light. It finds the branches, worktrees and generated folders you no longer
need, shows the evidence for why each one is safe to remove, removes it to the Trash, and lets you undo
anything for 30 days.

It is a native macOS app (SwiftUI) with a small Swift engine underneath. Everything stays on your Mac: no
account, no upload, no telemetry.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/overview-dark.png">
  <img alt="Lopper overview: 453.7 MB ready to reclaim, with the repositories that hold the most" src="docs/images/overview-light.png">
</picture>

<table>
<tr>
<td width="50%"><picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/repository-dark.png">
  <img alt="A repository: every branch and worktree with its verdict, and the evidence behind it" src="docs/images/repository-light.png">
</picture></td>
<td width="50%"><picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/agents-dark.png">
  <img alt="Agents: worktrees left behind by Claude Code, Cursor, Codex and Conductor" src="docs/images/agents-light.png">
</picture></td>
</tr>
<tr>
<td width="50%"><picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/disk-map-dark.png">
  <img alt="Disk map: generated folders and developer caches sized by bytes" src="docs/images/disk-map-light.png">
</picture></td>
<td width="50%"><picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/history-dark.png">
  <img alt="History: every removal, why it was safe, and how long it can be restored" src="docs/images/history-light.png">
</picture></td>
</tr>
</table>

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

## Install

Download the latest DMG from [Releases](https://github.com/Zawalid/Lopper/releases/latest), drag Lopper to
Applications, and open it. Until the app is notarized, macOS asks you to confirm the first launch once; the steps
are in the [install guide](docs/install.md), along with Homebrew (`brew install --cask zawalid/lopper/lopper`),
building from source, updating and uninstalling.

**Requirements:** macOS 14 or later, and git on your `PATH` (`xcode-select --install`). The
[GitHub CLI](https://cli.github.com) (`gh`) is optional and adds pull request based merge detection.

## Build from source and contribute

You need Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
git clone https://github.com/Zawalid/Lopper.git
cd Lopper
scripts/dev.sh               # build a Debug app and open it; add --watch to relaunch on save
swift test                   # engine tests
cd App && xcodegen generate && xcodebuild test -project Lopper.xcodeproj -scheme Lopper -destination 'platform=macOS'
```

To try Lopper on throwaway data instead of your own repositories, build the demo world:

```bash
scripts/demo-world/build.sh ~/LopperDemo
scripts/demo-world/run.sh
```

See [docs/development.md](docs/development.md) for the development loop, [docs/releasing.md](docs/releasing.md) for
versions and releases, and [docs/roadmap.md](docs/roadmap.md) for what is planned.

## Project layout

- `Sources/Lopper`: the engine (no UI): scanning, classification, cleaning, undo.
- `Tests/LopperTests`: engine tests, using real git repositories created on the fly.
- `App/LopperApp`: the SwiftUI app.
- `scripts`: dev loop, packaging and the demo world.
- `docs`: development notes, the settings file format, the roadmap.

## Contributing

Issues and pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) first; changes to anything that
deletes things need tests that prove the safety rules still hold.

## Author

Made by [Walid Zakan](https://zawalid.com): [GitHub](https://github.com/Zawalid) · [X](https://x.com/Zawaalid)

## License

[MIT](LICENSE)
