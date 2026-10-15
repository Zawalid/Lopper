# The settings file

Lopper keeps its engine settings in one readable JSON file, shared by the app and (later) the `lop` command
line tool:

```
~/Library/Application Support/Lopper/settings.json
```

Edit it while Lopper is closed, or use the Settings window. Keys are sorted, so diffs stay small.

## Schema version 2

| Key | Type | Meaning |
|---|---|---|
| `schemaVersion` | number | Always `2` for this layout |
| `folders` | list | Folders to look in: `path` (file URL), `isEnabled`, `excludePatterns` (directory name globs) |
| `scanDepth` | number | How many levels below each folder to search for repositories |
| `protectedPatterns` | list of globs | Branch names that are never offered for removal |
| `disposableNames` | list | File and directory names (globs allowed) treated as throwaway inside a worktree |
| `staleDays` | number | Age after which a branch counts as stale |
| `trashRetentionDays` | number | How long removals stay restorable |
| `repos` | object | Per repository, keyed by its path: `defaultBranch`, `protectedPatterns` (replaces the global list), `disposableNames` (added to the global list), `isIgnored` |

Anything else in the file is kept as is when Lopper saves.

## Safety guarantees

- Opening a version 1 file migrates it in memory and keeps the original as `settings.json.v1-backup`
  (never overwritten, so it is always the original).
- A file that cannot be read is copied to `settings.json.broken-<date>` before anything is written, and
  Lopper starts with defaults and says so.
- A file written by a newer Lopper is used as far as it is understood, unknown keys are preserved, and a copy
  is kept as `settings.json.v<N>-backup`.
- Saves are atomic and coalesced (one write after changes stop for 300 ms, and one on quit).

## What causes a rescan

Changing enabled folders, their exclude patterns, `scanDepth`, `protectedPatterns`, `disposableNames`, or
anything under `repos`. Changing `staleDays` or `trashRetentionDays` does not.
