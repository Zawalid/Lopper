# The `lop` command line tool

`lop` does what the Lopper app does, from the terminal: it finds the branches, worktrees and generated folders you
no longer need, shows the git evidence for each, and removes them to the Trash or deletes them with an undo record.
It shares the app's settings and the app's undo history: a cleanup made in the terminal appears in the app's History,
and Undo works in either place.

## Install

```bash
brew install zawalid/lopper/lop
```

Or download `lop-<version>-macos.tar.gz` from the [latest release](https://github.com/Zawalid/Lopper/releases/latest),
unpack it, and move `lop` somewhere on your `PATH`:

```bash
tar xzf lop-0.2.0-macos.tar.gz
sudo mv lop-0.2.0/lop /usr/local/bin/
```

Shell completions for zsh, bash and fish are in the tarball's `completions` folder (Homebrew installs them for you).
`lop --generate-completion-script zsh` prints one directly.

## First run

```bash
lop folders add ~/Code      # where your projects live; the app's folders are used if you already set them up
lop doctor                  # checks git, the GitHub CLI, your folders and Lopper's files
lop scan                    # one line per repository
```

## Commands

| Command | What it does |
|---|---|
| `lop scan` | Summary per repository: how many items are safe, need a look, or are protected, and the space a clean would free. |
| `lop list [--safe] [--review] [--protected] [--repo NAME] [TEXT]` | Every branch and worktree with its verdict and the evidence behind it. |
| `lop why NAME` | The full explanation for one branch or worktree: evidence, last commit, how it compares to the default branch, pull request, agent state. |
| `lop clean [--dry-run] [--yes] [--repo NAME] [TEXT]` | Shows the plan, asks you to confirm, removes the safe items. |
| `lop diagnostics [--include-names]` | A report to paste into a bug report: versions, setup problems, settings as counts, last scan timings, recent problems. Names are left out unless you ask; nothing is sent. |
| `lop risk` | Work that exists only on this Mac: unpushed commits, uncommitted changes, stashes. Read only, nothing is removed or pushed. |
| `lop agents [--reclaim-finished]` | Worktrees from Claude Code, Cursor, Codex and Conductor, grouped by state. `--reclaim-finished` removes the finished ones. |
| `lop disk [--caches] [--clear] [--untouched-days N]` | Generated folders and, with `--caches`, tool caches. `--clear` moves the offered folders to the Trash. |
| `lop history [-l N]` | What was removed, newest first, and how many days each can still be restored. |
| `lop undo ID` / `lop undo --last` | Restore one entry (an id or the start of it from `history`), or the whole latest cleanup. |
| `lop folders [list\|add PATH\|remove PATH]` | The scanned folders, shared with the app. Removing one never touches its contents. |
| `lop doctor` | Environment checks. Exits with 1 when something required is wrong. |

Every command takes `--json`, `--no-color`, `--no-gh` (skip pull request detection) and `--folder PATH` (scan that folder
instead of the configured ones, repeatable). `lop COMMAND --help` documents the rest.

## How it stays safe

The terminal gets the same rules as the app, because the same engine decides.

- Only items the app would call safe are removed by `clean` and `agents --reclaim-finished`. An agent worktree that may
  still be in use, or that holds work that exists only in its folder, is never part of a bulk clean.
- Nothing is removed without a confirmation. In a terminal `lop` asks `[y/N]`. Without a terminal (scripts, CI, an AI
  agent) it refuses unless you pass `--yes`.
- `--dry-run` shows the plan and stops.
- `lop clean --include-review` can remove items that need a look, but only together with a name or `--repo`, so it can
  never be a blanket removal.
- Each item is re-checked against fresh git state right before it is removed, and every removal writes an undo record
  first. Branches come back at their exact commit.
- Folders go to the Trash, not into the void. Nothing is deleted for good unless you ask the app to.

## Output for scripts and agents

`--json` prints one JSON document with a `schema` number (currently `1`) and a `generatedAt` time. Field names are
stable within a schema version.

```bash
lop list --safe --json | jq -r '.rows[] | "\(.repository)\t\(.title)\t\(.evidence)"'
lop agents --json | jq '{finished, reclaimableBytes, tools}'
lop clean --yes --json        # removes the safe items, prints what happened
```

Exit codes: `0` success, `1` an operation failed (or `doctor` found a problem), `2` the command line was wrong or a
confirmation was required and not given.

## Environment

| Variable | Effect |
|---|---|
| `LOPPER_SUPPORT_DIR` | An absolute folder for settings and the undo log, instead of `~/Library/Application Support/Lopper`. Useful for trying `lop` on throwaway data. |
| `NO_COLOR` | Turns colors off. |

## Build it

```bash
swift build -c release --product lop
.build/release/lop --version
```
