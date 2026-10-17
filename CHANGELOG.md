# Changelog

All notable changes to Lopper are listed here. The format follows [Keep a Changelog](https://keepachangelog.com),
and versions follow [Semantic Versioning](https://semver.org). Entries under **Unreleased** are written by hand as
work lands; `scripts/release.sh` moves them under the new version.

## [Unreleased]

### Changed
- Only on this Mac is easier to work with. Three tiles at the top filter by Not pushed, Uncommitted and Other, and
  a search box and a sort menu narrow the list. Rows are ordered by risk, with commits that no branch holds first
  and the biggest unpushed branches next. Each repository folds up, shows its first five items with a "Show more"
  row, and sets worktrees that hold only untracked files apart.
- Click a row to see what is in it: the commit subjects for unpushed work, the changed files for an uncommitted
  worktree, the files in a stash. Every action has a name and a tooltip, and a repository can copy all of its push
  commands at once. A new Copy list button copies the whole page as plain text. Lopper still never pushes or
  removes anything on this page.

## [0.3.1] - 2026-10-17

### Fixed
- On macOS 26 the top of the window showed a strip in a different grey from the sidebar below it. The window
  toolbar color is now only set on macOS 14 and 15, where the title bar is a separate band.

## [0.3.0] - 2026-10-16

### Added
- A styled installer: the DMG opens with a dark window, a drag arrow to Applications and a first launch hint.
- An "Only on this Mac" page, and `lop risk`: work that exists nowhere else, meaning unpushed commits, uncommitted
  changes in worktrees, stashes, commits on a detached head and half done rebases or merges. It lists and explains;
  it never removes or pushes anything.
- Setup screens when git is missing (Apple's command line tools) or macOS blocks the folders you chose, and
  `lop doctor` and `lop folders` now report which folder cannot be read and why.

- Diagnostics: Settings, About, Diagnostics and `lop diagnostics` show a report for bug reports (versions, setup
  problems, settings as counts, last scan timings, recent problems). Repository and branch names are left out unless
  you include them; home folders, credentials and email addresses are always removed. Nothing is sent. Events are kept
  in a small local log, capped at 500 entries and 30 days.

### Changed
- First launch instructions say Open Anyway in System Settings, Privacy & Security, which is what macOS 15 and later
  require (right-click, Open only works on macOS 14). Updated in the README, install guide, website and Homebrew note.

### Fixed
- The window's toolbar takes the page color, so the title bar no longer shows as a separate lighter band.
- Safety audit (see docs/safety.md): edits hidden with `skip-worktree` or `assume-unchanged` no longer make a worktree
  look clean; work that lives only in a merge commit is no longer called merged; a branch being rebased in another
  worktree is never deleted; removing one missing worktree no longer drops the others; undo records survive two writers
  and a crash; a reused Trash name can no longer be mistaken for a Lopper folder; damaged settings stop removals instead
  of silently resetting protections; `--include-review` never removes an agent that is still working; `lop disk
  --untouched-days` looks at the project, not the generated folder; reinstall only runs where a folder was really
  cleared; git is no longer redirected by `GIT_DIR` and similar variables.
- Large scans: file descriptors are released as soon as a command ends, so thousands of branches no longer end in
  "could not start git". A scan of 200 repositories takes 15 seconds instead of 100, and the window no longer stutters
  with thousands of rows.
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
