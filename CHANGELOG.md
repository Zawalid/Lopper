# Changelog

All notable changes to Lopper are listed here. The format follows [Keep a Changelog](https://keepachangelog.com),
and versions follow [Semantic Versioning](https://semver.org). Entries under **Unreleased** are written by hand as
work lands; `scripts/release.sh` moves them under the new version.

## [Unreleased]

### Added
- An "Only on this Mac" page, and `lop risk`: work that exists nowhere else, meaning unpushed commits, uncommitted
  changes in worktrees, stashes, commits on a detached head and half done rebases or merges. It lists and explains;
  it never removes or pushes anything.
- Setup screens when git is missing (Apple's command line tools) or macOS blocks the folders you chose, and
  `lop doctor` and `lop folders` now report which folder cannot be read and why.

### Fixed
- A folder macOS refused to open used to look like "No repositories found". It is now named, and the other folders
  are still scanned.

## [0.2.0] - 2026-10-16

### Added
- `lop`, a command line tool with the same engine and rules as the app: `scan`, `list`, `why`, `clean`, `agents`, `disk`,
  `history`, `undo`, `folders` and `doctor`, with `--json` output and shell completions. It shares the app's settings
  and undo history. See docs/cli.md.
- A website at lopper.zawalid.com.

### Changed
- The cleanup rows and agent rows moved from the app into the engine, so the app and the command line share one
  definition of what is safe.

## [0.1.0] - 2026-10-16

### Added
- First public release.
- Scans the folders you choose for git repositories and classifies every branch and worktree as safe to remove,
  needing a look, or protected, with the git evidence behind each verdict.
- Agents page for worktrees left by Claude Code, Cursor, Codex and Conductor: age, unmerged work, size, and a
  one-step reclaim of the finished ones.
- Disk page for generated folders and developer caches: by project, by kind, or as a map; clears to the Trash,
  with optional reinstall.
- History with restore for 30 days, a weekly chart of space given back, and filters.
- Offer-only rules, a weekly digest notification, a menu bar popover, a command palette (Command-K).
- Onboarding with suggested folders, an opt-in search of the whole Mac, and a first-scan summary.
