# Safety

Lopper's one job is to never remove work that exists nowhere else. This page says how that is enforced, which test
proves each part, what the last audit found, and what Lopper knowingly accepts.

## The rules and where they are enforced

| Rule | How | Proved by |
|---|---|---|
| Nothing is removed that you did not review | A confirmed list is the only way anything is removed. Rules only suggest. Agent worktrees in use and Protected items are never in a bulk set. | `CleanerTests`, `BatchCleanerTests`, `AgentPipelineTests`, `SafetyReviewCLITests` |
| Every removal is checked again right before it runs | The branch or worktree is re-read from git, its verdict must still be at least as safe as the one you approved, and the commit it points to must be unchanged. | `CleanerTests`, `CleanerFolderOnlyWorkTests`, `SafetyReviewTests` |
| The way back exists before the removal | Order is fixed: keep-alive ref under `refs/lopper/trash`, then an undo record, then the command. If the record cannot be written, nothing is removed. If it cannot be written afterwards, the outcome says so instead of reporting success. | `CleanerTests`, `FsSafetyReviewTests` |
| A branch is deleted only if it still points where it did | `update-ref -d <ref> <old>` is a compare-and-delete. `--force` is never used. | `CleanerTests`, `SafetyReviewTests` |
| "Merged" means the content really is in the default branch | Ancestry, tree equality, or patch equivalence with no merge commits in between. Anything git cannot show is "no evidence", never a guess. A shallow or unknown default branch yields no evidence. | `MergeEvidenceTests`, `SafetyReviewTests` |
| A worktree is clean only if it really is | Uncommitted changes, untracked files, stashes, an operation in progress, and edits to files hidden with `skip-worktree` or `assume-unchanged` all make it need a look. A branch being rebased or bisected in another worktree counts as in use. | `WorktreeFactsTests`, `SafetyReviewMoreTests` |
| A missing worktree folder is not assumed to be junk | A folder missing together with its parent (an unplugged drive) is not touched. Removing one worktree's registration never touches another's. A detached head gets a saved branch first. | `SafetyReviewTests`, `SafetyReviewMoreTests` |
| A folder git will not remove is moved, never forced | When a worktree holds changes git refuses to discard, the only way past is "Remove anyway, keep a copy": one worktree at a time, after its files are shown. The whole folder goes to the Trash, git's own record of it (index and HEAD) is copied aside, then dropped, and the branch and a keep-alive ref stay. Restore puts the folder back and the record with it. A locked or Protected worktree, one with an operation half done or another worktree inside, and one an agent may still be using are refused. If the Trash move or the record removal fails, the folder is put back and the record rebuilt. | `CleanerKeepCopyTests`, `WorkspaceTests`, `NotRemovedModelTests` |
| Generated folders go to the Trash, not away | Only git-ignored, not tracked, not a symlink, inside their project, with a lockfile for dependency folders, and checked again at the last moment. A folder holding another git repository is never cleared. | `ArtifactCleanerTests`, `FsSafetyReviewTests` |
| Lopper only deletes what it trashed | Each Trash record keeps the folder's identity (device and inode), so a different folder that later takes the same name in the Trash is neither restored over a project nor deleted for good. | `TrashSweeperTests`, `FsSafetyReviewTests` |
| Git is judged in the repository you named | Variables that redirect git (`GIT_DIR`, `GIT_INDEX_FILE`, `GIT_WORK_TREE` and the like) are not passed on, so a `lop` started from a hook cannot check or act on the wrong repository. | `FsSafetyReviewTests`, `SafetyReviewTests` |
| Your protections are never silently replaced | A settings file that cannot be read in full stops the CLI and the app from removing anything, keeps what was readable, and is never overwritten when it could not be read at all. A file written by a newer version is never rewritten by an older one. | `FsSafetyReviewTests`, `SettingsLoaderTests` |
| The undo log survives two writers and a crash | Appends are atomic and locked across processes, a half-written last line is never glued to the next record, and a line this version cannot read hides its record instead of showing an older state. | `FsSafetyReviewTests` |

## Audit, 16 October 2026

Two independent reviewers read the destructive code cold, one for git-state paths and one for filesystem, process and
persistence paths, each told to prove findings with a real test. A third piece of work measured scale with a synthetic
world (`scripts/stress/build.py`, `scripts/stress/measure.sh`). Every finding was reproduced on the unmodified code
before it was fixed, and each fix kept its test.

Fixed, grouped by what could have gone wrong:

- **Work hidden from git status.** Edits to files flagged `skip-worktree` or `assume-unchanged` were invisible, so a
  Safe worktree holding them could be removed. Work that existed only inside a merge commit could be called merged. A
  branch being rebased in another worktree could be deleted underneath it.
- **Bookkeeping that could orphan commits.** `git worktree prune` is repository-wide and could drop other missing
  worktrees holding unpushed commits. Removal of a missing worktree now touches only its own registration.
- **Records that could be wrong.** Concurrent writers could lose undo records, a crash could glue the next record onto
  a half line, a failed completion write was reported as success, and a reused Trash name could make Lopper delete or
  restore someone else's folder.
- **Settings.** One bad value reset every protection, an unreadable file was treated as corrupt and could be
  overwritten, and the CLI never said so.
- **Scope.** `lop disk --untouched-days` filtered on the wrong date, reinstall could run `npm ci` in a project Lopper had
  refused to clear, `--include-review` could sweep an agent that was still working and accepted a one-character query,
  and a stray `.git` file could pull another repository into scope.
- **Scale.** Each finished git command held its file descriptors for thirty seconds, so a large scan ran out of them and
  later repositories failed with "could not start git". Branches are now judged several at a time, ancestry and
  ahead/behind are asked once per repository, and the real git binary is used instead of the `/usr/bin/git` stub.
  The interface caches the rows it derives, so a redraw no longer rebuilds eight thousand of them.

### Measured

Synthetic world on an Apple silicon Mac, no GitHub CLI:

| | Before | Now | Budget |
|---|---|---|---|
| 200 repositories of 40 branches, 10 with worktrees | 100 s (and repositories failing) | 15 s | 30 s |
| One repository with 3,000 branches | 254 s | 15 s | n/a |
| Peak memory, 200 repositories | 98 MB | 95 MB | 500 MB |
| Interface reads at 8,000 branches (debug build) | about 135 ms each | about 18 ms | 100 ms |

Run it yourself: `scripts/stress/build.py ~/LopperStress` then `scripts/stress/measure.sh ~/LopperStress`. The world is
throwaway and is never created inside your own repositories.

## Accepted trade-offs

These are known and chosen, not missed:

- **Disposable names.** A folder named `out`, `build`, `dist`, `target`, `coverage` and the like inside a worktree is
  treated as disposable even if it holds something you made. Narrowing it would turn most monorepo worktrees into
  "needs a look". The list is yours to edit in Settings, Safety.
- **A brand-new empty branch is Safe.** It has no commits, so only its name is lost, and it is restorable.
- **The local default branch counts as evidence.** A branch merged into a local `main` that was never pushed is Safe.
  The work does exist in `main`, and `Only on this Mac` lists unpushed commits so that gap is visible.
- **Trash records made before 0.3 have no recorded identity.** They behave as before. New ones are checked.
- **App worktrees that are not from an agent** are checked for work that exists only in their folder when you review
  them, not again at the last moment (agent worktrees and everything removed from the CLI are).
- **Keep-alive refs are not expired automatically yet.** History counts down thirty days, but the refs under
  `refs/lopper/trash` stay until removed. They cost almost nothing. The expiry code exists and is tested, and is not
  wired up until its own pass.
- **Restore does not bring back** a branch's description or push configuration, the same as forcing the deletion with
  git directly.
