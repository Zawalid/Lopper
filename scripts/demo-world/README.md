# The Lopper demo world

A believable developer machine, generated from scratch with real git, to test every Lopper feature by hand and
to record the product demo.

| | |
|---|---|
| Build | `scripts/demo-world/build.sh <target dir> [--force]` (about 45 seconds, about 1.6 GB on disk) |
| Run | `scripts/demo-world/run.sh` (dev build of the app, isolated settings and undo history) |
| Default location | `~/Personal/Projects/LopperDemo` (next to the Lopper checkout), support files in `~/Personal/Projects/LopperDemo-support` |
| Contents | 5 workspace folders, 17 repositories (1 broken on purpose), 92 branches, 30 linked worktrees, 6 past cleanups, 41 generated folders on disk |

## Build and run

```bash
scripts/demo-world/build.sh ~/Personal/Projects/LopperDemo          # first build
scripts/demo-world/build.sh ~/Personal/Projects/LopperDemo --force  # throw it away and rebuild (reset after a demo)
scripts/demo-world/run.sh                                           # start the app against the world
```

- `build.sh` refuses to run when the target exists and is not empty. `--force` deletes the target folder itself
  and nothing else, and only when the folder carries the `.demo-world/MARKER` file this script leaves behind.
  The absolute path is printed first. No network, no sudo, and git runs with an isolated config
  (`GIT_CONFIG_GLOBAL` in a temp folder, `GIT_CONFIG_SYSTEM=/dev/null`), so your own git config is never read or
  written. All dates are relative to the moment of the build ("3 days ago" stays true on every rebuild).
- `run.sh` starts the Debug build (`build/dev/Build/Products/Debug/Lopper.app/Contents/MacOS/Lopper`, or the path
  you pass) with `LOPPER_SUPPORT_DIR=<world>-support`. That folder holds `settings.json` (schema 2, only the five
  demo workspaces as scanned folders, engine defaults for everything else) and `undo-log.jsonl` (the History
  page). Your real `~/Library/Application Support/Lopper` is never touched.
- `run.sh` also touches the files of the worktrees that must look "active right now" (listed in
  `.demo-world/active-worktrees.txt`), so the Agents page shows them as active whenever you start the app. Use
  `--no-refresh` to skip that. After clicking through destructive actions, rebuild with `--force` to get the
  world, the repositories and the undo history back to the starting state.
- Fake remotes: repositories talk to real bare repositories in `<world>/.remotes` while they are built (so
  upstream tracking and "remote branch deleted" are genuine), then `remote.origin.url` is rewritten to
  `git@github.com:<org>/<repo>.git`. Nothing ever contacts GitHub. GitHub links render; the remote branches
  cannot be opened.

### What is expected and is not a bug

- `gh` cannot see the fake pull requests, so Lopper reports "PR detection off" for GitHub-remote repositories.
  Branches merged with a merge commit show "Already part of the default branch", not "Merged via PR #118". The
  History page does show "Merged via PR #..." reasons (those are stored text, written as Lopper would have with
  `gh` signed in).
- The broken repository is meant to be broken (see Archive).
- Hidden folders (`.cursor`, `.codex`, `.remotes`, `.demo-world`) are never scanned directly; their worktrees
  appear through the repositories that own them.

## How to read the tables

Verdicts come from `Classifier.swift`: any protected reason wins (Protected), otherwise any review reason
(Review), otherwise Safe. Protected: default branch, main working directory head, checked out in a worktree,
matches a protected pattern (`main`, `master`, `develop`, `release/*`, `hotfix/*` by default). Review: no merge
evidence, remote branch gone but unproven, dirty worktree, locked, unreadable, untracked or ignored non-disposable
files, operation in progress, stash entry. Safe: strong merge evidence (ancestor, or content already in the
default branch) and nothing else wrong.

Agent state comes from `AgentAssessment.swift`: Protected if the verdict is Protected, Active if the newest of
(HEAD commit date, worktree creation date, newest file outside `.git` and disposable folders) is under 120 minutes
old, otherwise Unmerged when work exists only in the folder or the comparison is unknown, Abandoned when it holds
unmerged commits and has been idle for `staleDays` (30) or more, and Finished when nothing unique is left.

Everything in the tables was checked against the engine itself (`swift run lopper-scan --no-gh` and a throwaway
harness around `AgentAssessor`), not only derived by reading.

## startup-saas (GitHub org `acme`)

### web (Next.js, the busy product repository; default `main`, remote `acme/web`)

| Branch or worktree | State it is in | Lopper shows |
|---|---|---|
| `feature/billing-portal` | merged with a merge commit (#118), remote branch deleted, checked out in `web-billing-portal` | Protected: checked out in worktree |
| `fix/login-redirect-loop` | squash merged (#121), remote branch deleted | Safe: content already in the default branch (squash or rebase merge) |
| `chore/upgrade-next-14` | rebase merged (new SHAs, same patches), never pushed | Safe: content already in the default branch |
| `feature/empty-spike` | created from main, no commit of its own | Safe: already part of the default branch, no commits of its own |
| `chore/lint-cleanup` | merged (#126) but a stash entry belongs to it | Review: a stash entry belongs to this branch |
| `experiment/edge-runtime` | 3 commits, pushed, remote branch deleted, never merged | Review: remote branch is gone, nothing proves it was merged |
| `feature/dark-mode` | 4 commits, last 65 days ago, never pushed (checked out two days ago, the reflog knows) | Review: no merge evidence (stale) |
| `feature/team-invitations` | 5 commits (1 not pushed), live upstream, newest work | Review: no merge evidence |
| `develop`, `release/1.x` | long-lived, ahead of main | Protected: matches protected pattern |
| `hotfix/csrf-token` | merged (#127) | Protected: matches `hotfix/*` |
| `fix/avatar-upload` | merged (#125), checked out in `web-avatar-upload` | Protected: checked out in worktree |
| `feature/onboarding-checklist` | merged (#123), checked out in `web-onboarding-checklist` | Protected: checked out in worktree |
| `main` | default branch | Protected: default branch |
| worktree `web-billing-portal` | merged, clean, about 124 MB (node_modules, .next) | Safe, 124 MB reclaimable |
| worktree `web-avatar-upload` | merged, one tracked file edited and not committed | Review: uncommitted changes |
| worktree `web-onboarding-checklist` | merged, untracked `NOTES.md` and ignored `.env.local` | Review: contains files git does not track |

### api (Go service; remote `acme/api`)

| Branch or worktree | State it is in | Lopper shows |
|---|---|---|
| `fix/token-expiry` | merged (#77), remote branch deleted | Safe: already part of the default branch |
| `refactor/handlers-split` | squash merged (#81) | Safe: content already in the default branch |
| `feature/rate-limiting` | newest unmerged work, checked out in the main working directory | Protected: checked out in the main working directory |
| `feature/webhooks-v2` | 6 commits, 5 pushed, live upstream | Review: no merge evidence |
| `feature/pagination` | conflicts with main, a rebase is stopped in `api-pagination` | Review: no merge evidence |
| `develop`, `release/1.x`, `release/2.0`, `hotfix/auth-bypass` | protected by name | Protected: matches protected pattern |
| `perf/benchmark-harness` | merged (#76), checked out in the locked worktree `api-benchmarks` | Protected: checked out in worktree |
| worktree `api-benchmarks` | merged and clean, locked ("benchmark run in progress") | Review: the worktree is locked |
| worktree `api-pagination` | detached HEAD, rebase stopped on a conflict | Review: uncommitted changes, operation in progress |

### mobile (SwiftUI app; remote `acme/mobile`; a pile of old branches)

| Branch or worktree | State it is in | Lopper shows |
|---|---|---|
| `feature/onboarding-v2` | merged (#44) | Safe: already part of the default branch |
| `fix/keyboard-overlap` | merged (#51) | Safe: already part of the default branch |
| `feature/push-notifications` | squash merged (#47) | Safe: content already in the default branch |
| `fix/crash-on-launch` | rebase merged (#49) | Safe: content already in the default branch |
| `feature/offline-mode` | 3 commits, last 74 days ago | Review: no merge evidence (stale) |
| `spike/swiftui-charts` | 1 commit, 88 days ago | Review: no merge evidence (stale) |
| `feature/apple-pay` | 3 commits, live upstream | Review: no merge evidence |
| `chore/bump-xcode-15` | pushed, remote branch deleted, unmerged | Review: remote branch is gone, nothing proves it was merged |
| `develop` | protected by name | Protected |
| `fix/ios17-layout` | merged (#52), registered in a worktree whose folder was deleted by hand | Protected: checked out in worktree |
| worktree `mobile-ios17-fixes` | folder gone, git still lists it ("prunable") | Safe, shown as a stale registration to prune |

### docs (Markdown docs site; remote `acme/docs`)

| Branch | State it is in | Lopper shows |
|---|---|---|
| `docs/getting-started-rewrite` | merged (#17) | Safe: already part of the default branch |
| `docs/migration-guide` | merged (#15); Lopper removed it 17 days ago, the user restored it | Safe: already part of the default branch (History shows it as Restored) |
| `docs/api-v2-reference` | squash merged (#19), remote branch deleted | Safe: content already in the default branch |
| `docs/changelog-2.0` | 3 commits, newest, local only | Review: no merge evidence |

## client-work (GitHub org `northpine-agency`)

### bluebird-studio (marketing site; remote `northpine-agency/bluebird-studio`)

| Branch or worktree | State it is in | Lopper shows |
|---|---|---|
| `feature/contact-form` | merged (#31) | Safe: already part of the default branch |
| `feature/case-studies` | merged (#34), remote branch deleted | Safe: already part of the default branch |
| `fix/hero-image-crop` | squash merged (#36) | Safe: content already in the default branch |
| `staging` | 2 commits ahead of main, live upstream (not in the default protected patterns on purpose) | Review: no merge evidence |
| `content/spring-campaign` | 4 commits, live upstream | Review: no merge evidence |
| worktree `bluebird-studio-redesign` | detached HEAD, 1 commit no branch holds, clean | Review: no merge evidence |

### harbor-bakery (order site, no remote at all, so no links)

| Branch or worktree | State it is in | Lopper shows |
|---|---|---|
| `feature/order-form` | merged locally | Safe: already part of the default branch |
| `fix/mobile-nav` | squash merged locally | Safe: content already in the default branch |
| `feature/seasonal-menu` | 2 commits, 48 days old, local only | Review: no merge evidence (stale) |
| `feature/old-theme-revert` | merged, registered in `harbor-bakery-old-theme` | Protected: checked out in worktree |
| worktree `harbor-bakery-old-theme` | folder exists but its `.git` link is gone (copied away) | Review: could not be inspected, not known to be clean |

### atelier-noir (portfolio; default branch `trunk`, no origin, so the default branch is unknown)

| Branch or worktree | State it is in | Lopper shows |
|---|---|---|
| repository header | no `main`, no `master`, no `origin/HEAD` | "default branch unknown" (Lopper does not guess) |
| `redesign/gallery` | merged into trunk (merge commit) | Review: no merge evidence (cannot compare) |
| `fix/lightbox-focus` | squash merged into trunk | Review: no merge evidence |
| `feature/booking-widget` | 2 commits, 69 days old | Review: no merge evidence (stale) |
| `trunk` | head of the main working directory | Protected: checked out in the main working directory |
| worktree `.claude/worktrees/seo-meta-tags` | Claude Code, merged into trunk, clean, idle 3 days | Agent state Unmerged ("commits not compared"), Review sheet offers keeping `claude/seo-meta-tags` |

## open-source (GitHub user `amirabenali`)

### fastcsv (TypeScript library with tags v1.0.0, v1.4.2, v2.0.0, v2.1.0)

| Branch or worktree | State it is in | Lopper shows |
|---|---|---|
| `fix/bom-handling` | merged (#142), remote branch deleted | Safe: already part of the default branch |
| `fix/quoted-newlines` | squash merged (#145) | Safe: content already in the default branch |
| `dependabot/npm_and_yarn/vitest-1.6.0` | pushed, remote branch deleted, unmerged | Review: remote branch is gone, nothing proves it was merged |
| `feat/streaming-parser` | 6 commits, live upstream | Review: no merge evidence |
| `release/1.x` | backport, tag v1.4.2 | Protected: matches protected pattern |
| `release/2.x` | checked out in `fastcsv-release-2.x` | Protected: checked out in worktree and matches pattern |
| worktree `fastcsv-release-2.x` | clean | Protected: matches protected pattern |
| `chore/bump-deps` | removed by Lopper 28 days ago | not present; History offers Restore (2 days left) |

### pyrate (Python library; remote `amirabenali/pyrate`)

| Branch or worktree | State it is in | Lopper shows |
|---|---|---|
| `fix/retry-backoff` | merged (#55), remote branch deleted | Safe: already part of the default branch |
| `docs/api-reference` | rebase merged (#58) | Safe: content already in the default branch |
| `feature/async-client` | 3 commits, last 52 days ago, live upstream | Review: no merge evidence (stale) |
| `develop`, `release/0.4` | protected by name | Protected |
| worktree `pyrate-bisect` | detached at an old commit of main, clean | Safe: already part of the default branch |

### tinyhash (Rust crate; remote `amirabenali/tinyhash`)

| Branch | State it is in | Lopper shows |
|---|---|---|
| `fix/empty-input` | merged (#12) | Safe: already part of the default branch |
| `perf/simd-lookup` | 2 commits, live upstream | Review: no merge evidence |

## agents-lab (worktrees made by AI coding tools)

Worktree layouts: Claude Code at `<repo>/.claude/worktrees/<name>`, Cursor at
`agents-lab/.cursor/worktrees/<repo>/<id>`, Codex at `agents-lab/.codex/worktrees/<hash>/<repo>`, Conductor at
`agents-lab/conductor/workspaces/<repo>/<name>` (all match `AgentDetector.pathMarkers`).

### agent-playground (remote `amirabenali/agent-playground`)

| Worktree | State it is in | Agents page shows |
|---|---|---|
| `.claude/worktrees/fix-typo-readme` | merged with a merge commit, clean, idle 3 days, 21 MB | Claude Code, **Finished**, reclaim |
| `.claude/worktrees/tidy-imports` | squash merged, clean, idle 5 days, 37 MB | Claude Code, **Finished**, reclaim |
| `.cursor/worktrees/agent-playground/9f8e7d` | `cursor/dark-theme-tokens` merged, clean, idle 4 days | Cursor, **Finished**, reclaim |
| `.claude/worktrees/add-search-box` | unmerged commit, file edited just now (run.sh refreshes this) | Claude Code, **Active**, no removal offered |
| `.claude/worktrees/refactor-auth` | 2 commits not in main, clean, idle 1.5 days | Claude Code, **Unmerged**, folder removed and branch kept |
| `.claude/worktrees/wip-export` | 1 commit plus uncommitted edit plus untracked `NOTES.txt`, idle 2 days | Claude Code, **Unmerged**, removal blocked: changes exist only in this folder |
| `.cursor/worktrees/agent-playground/c4b2a1` | `cursor/form-validation`, 2 commits, idle 3 days | Cursor, **Unmerged**, folder removed and branch kept |
| `.claude/worktrees/old-websocket-spike` | 1 committed unmerged commit, idle 45 days, 45 MB | Claude Code, **Abandoned**, folder removed and branch kept |
| `.claude/worktrees/release-prep` | branch `release/3.0` | Claude Code, **Protected**, no removal offered |

Repository branches: each worktree's branch is Protected (checked out in worktree) in the Branches view.

### refactor-lab (monorepo; remote `amirabenali/refactor-lab`)

| Worktree | State it is in | Agents page shows |
|---|---|---|
| `.claude/worktrees/big-migration` | merged, clean, idle 4 days, **214 MB** (node_modules, .next, dist) | Claude Code, **Finished**, reclaim (the biggest) |
| `.claude/worktrees/locked-docs-sync` | squash merged, clean, idle 6 days, locked | Claude Code, **Finished**, removal blocked: the worktree is locked |
| `.claude/worktrees/detached-try` | detached HEAD, 1 commit no branch holds, idle 5 days | Claude Code, **Unmerged**, saved as a `lopper/saved/...` branch, then the folder is removed |
| `.claude/worktrees/ancient-detached` | detached HEAD, 1 commit, idle 70 days | Claude Code, **Abandoned**, saved as a branch, then removed |
| `conductor/workspaces/refactor-lab/lisbon` | branch `amira/lisbon-api-cleanup`, 1 commit, idle 2 days | Conductor, **Unmerged**, folder removed and branch kept |
| `refactor-lab-cleanup` (ordinary folder) | branch `codex/cleanup-types`, merged, clean, idle 8 days | "Probably Codex" (detected from the branch name only), **Finished**, reclaim |

### docsbot (Python; Codex worktrees are detached; remote `amirabenali/docsbot`)

| Worktree | State it is in | Agents page shows |
|---|---|---|
| `.codex/worktrees/a1b2c3d4/docsbot` | detached at a commit main contains, clean, idle 3 days, 26 MB `.venv` | Codex, **Finished**, reclaim |
| `.codex/worktrees/7e9f0a12/docsbot` | detached, 1 commit nobody else has, idle 2 days | Codex, **Unmerged**, saved as a branch, then removed |
| `.codex/worktrees/5f2e1d00/docsbot` | detached, tracked file modified, idle 4 days | Codex, **Unmerged**, removal blocked: changes exist only in this folder |
| `.codex/worktrees/3c5d6e78/docsbot` | commit 18 minutes ago plus an edit just now | Codex, **Active** |

"Reclaim finished" covers the six Finished rows that are not blocked (about 330 MB).

## archive (older repositories, completely tidy)

| Repository | State it is in | Lopper shows |
|---|---|---|
| `legacy-portal` | PHP, about 11 months old, `main` only, remote `acme/legacy-portal`, an ignored `build/` folder | nothing to clean in Branches; Disk shows `build` as not offered |
| `hackathon-weekend` | Python, about a year old, `main` only, no remote, a forgotten `.venv` | nothing to clean in Branches; Disk offers the `.venv` |
| `blog-2022` | static blog, `main` only, GitLab remote (no GitHub links), a forgotten `node_modules` | nothing to clean in Branches; Disk offers the `node_modules` |
| `restored-from-backup` | `.git` folder with a corrupted `HEAD` | the "could not read this repository" card |

## Disk page (generated folders)

The Disk page lists git-ignored folders (`git ls-files --others --ignored --exclude-standard --directory`) and
offers one only when the project can bring it back (`ArtifactRules` in `Artifacts.swift`). Every repository has a
lockfile or manifest in its first commits so that the folders below have something to rebuild from. Sizes are real
bytes on disk (zero-filled files), rounded.

| Project | Generated folders | Lopper shows |
|---|---|---|
| web | `node_modules` 88 MB (package-lock.json), `.next` 31 MB | Offered: `npm ci`, "your next build or dev run" |
| web / web-billing-portal | `node_modules` 98 MB, `.next` 26 MB, untouched 50 days | Offered, counted in "Untouched 30+ days" |
| web / web-avatar-upload | `node_modules` 25 MB | Offered |
| bluebird-studio | `node_modules` 98 MB (package-lock.json) | Offered: `npm ci` |
| fastcsv | `node_modules` 46 MB; `dist/` with a force-added `keep.txt` and an ignored 6 MB bundle | `node_modules` offered; `dist` is **not listed at all**: git reports its ignored files one by one because the folder holds a tracked file |
| agent-playground (main checkout) | `node_modules` 56 MB, `.next` 10 MB, `dist` 12 MB | Offered |
| agent-playground / agent worktrees | `node_modules` (18 to 39 MB) and `.next` (5 to 12 MB) in `add-search-box`, `refactor-auth`, `tidy-imports`, `wip-export`, `fix-typo-readme`, `9f8e7d`, `c4b2a1`, and `node_modules` + `dist` in `old-websocket-spike` (45 days idle) | Offered per worktree: "clear build folders, keep the worktree" |
| refactor-lab | root `node_modules` 46 MB and `.turbo` 3 MB; `packages/ui/node_modules` 18 MB (a workspace member, no lockfile of its own) | Offered: `pnpm install` through the root `pnpm-lock.yaml` and `pnpm-workspace.yaml` |
| refactor-lab / big-migration, detached-try, lisbon | `node_modules` 130 / 35 / 25 MB, `.next` 52 / 6 MB, `dist` 31 MB | Offered; big-migration is the largest single item |
| tinyhash | `target` 66 MB (Cargo.toml) | Offered: `cargo build` |
| mobile | `.build` 66 MB (Package.swift) | Offered: `swift build` (see the note on `.build` below) |
| pyrate | `.venv` 49 MB (pyproject.toml), `__pycache__`, `.pytest_cache` | Offered: "your environment tool"; the caches come back by themselves |
| docsbot / Codex worktrees | `.venv` 26 MB in two of them | Offered |
| blog-2022 (archive) | `node_modules` 109 MB, untouched 300 days | Offered, counted in "Untouched 30+ days" |
| hackathon-weekend (archive) | `.venv` 45 MB (requirements.txt), untouched 380 days | Offered, counted in "Untouched 30+ days" |
| **harbor-bakery** | `node_modules` 25 MB, **no lockfile anywhere** | **Not offered**: "There is no lockfile, so reinstalling could pull different versions." |
| **legacy-portal** (archive) | `build/` 6 MB, **no package.json, Makefile or Gradle file** | **Not offered**: "Lopper cannot tell how this folder is rebuilt." |

"Untouched 30+ days" is non-zero: `web-billing-portal` and `old-websocket-spike` (worktrees, 50 and 45 days),
plus `blog-2022` and `hackathon-weekend` (300 and 380 days), about 360 MB between them. Their file times and git
metadata are set back by the generator (`age_wt`, `age_tree`).

### Seeing "never clear a folder with tracked files"

A folder that already holds a tracked file is never even listed (the fastcsv `dist` above). The clear-time
refusal, "Part of this folder is tracked by git, so it was left alone", only appears when a file becomes tracked
after the page has loaded. To show it:

```bash
# 1. open the Disk page so agent-playground/dist (12 MB, offered) is on screen
# 2. in a terminal, force-add one of its files
git -C ~/Personal/Projects/LopperDemo/agents-lab/agent-playground add -f dist/bundle.js
# 3. back in the app, clear that dist folder: Lopper re-checks git and skips it
```

Rebuild with `--force` afterwards to reset it.

### Notes found while building this (engine behaviour, not generator problems)

- `.build` (Swift) is not in `Settings.defaultDisposableNames`, although `ArtifactRules` knows it. The demo
  `settings.json` adds it explicitly; with the engine defaults a Swift project's `.build` never reaches the
  Disk page.
- "Last edited" (the "Untouched" tile) is the newest regular file under the folder outside disposable folders,
  and `SizeCalculator` only skips an entry literally named `.git`, not the contents of a `.git` folder. So any
  git activity in a main checkout counts as an edit, and so does Lopper's own scan: the content check
  (`git merge-tree --write-tree`) writes loose objects into `.git`, and every scan freshens them. Repositories
  with a branch that is not an ancestor of the default branch therefore never look untouched. Worktrees
  (whose `.git` is a single file) and repositories whose branches are all merged by ancestry do, which is why the
  untouched projects above are worktrees and `main`-only archive repositories.

## History page (`undo-log.jsonl`, all real: keep-alive refs exist and Restore works)

| When | Repository | What was removed | Status |
|---|---|---|---|
| 1 day ago | web | worktree `web-search-filters` (77 MB) and branch `feature/search-filters`, "Merged via PR #128" | Removed, restorable |
| 4 days ago | agent-playground | two agent worktrees and their branches: `claude/rename-hooks` (104 MB, PR #28) and `claude/css-cleanup` (130 MB, PR #30) | Removed, restorable, one batch ("Restore all") |
| 9 days ago | mobile | branches `spike/lottie-splash` (no merge evidence), `feature/dark-icons` (squash merge), `chore/swiftlint-0-54` (remote branch deleted) | Removed, restorable, one batch |
| 17 days ago | docs | branch `docs/migration-guide`, restored the next day | Restored (the branch is back) |
| 28 days ago | fastcsv | branch `chore/bump-deps`, "Merged via PR #141" | Removed, restorable, expires in about 2 days |
| 41 days ago | mobile | branches `spike/widgetkit` and `spike/watchos-companion` | Expired: "No longer restorable" (keep-alive refs are gone) |

## Engine states this world cannot produce

- "Merged via PR #N" (`prMerged`) and "Has commits added after PR #N was merged"
  (`prMergedWithNewerCommits`): both need real merged pull requests returned by `gh`, which cannot be faked
  offline. Everything else in `VerdictReason` and every `AgentState` appears at least once.
- A Protected agent worktree through `isDefaultBranch` (the default branch is never a linked worktree).
- An agent worktree with an operation in progress or a stash (the rebase scenario is an ordinary worktree).

## Suggested three minute demo

1. **Overview (0:00 to 0:25).** Start with `run.sh`. The totals appear: about 22 branches and 9 worktrees are
   safe, about 0.45 GB of worktrees can be reclaimed, and several items need a look. "Nothing is changed while Lopper looks."
2. **One repository, why (0:25 to 1:15).** Open `web`. Click `fix/login-redirect-loop` (Safe, squash merged: the
   content is in main under different commits). Click `feature/billing-portal` (Protected, a worktree has it).
   Click `experiment/edge-runtime` (Review: the remote branch is gone, nothing proves it merged) and
   `feature/dark-mode` (stale, never pushed). Point out the evidence line on each, not just a colour.
3. **Worktrees (1:15 to 1:40).** Same repository: `web-billing-portal` is Safe and 124 MB, `web-avatar-upload`
   has uncommitted changes, `web-onboarding-checklist` has a `.env.local` and notes git does not track.
   Lopper tells the difference between throwaway folders and files you would miss.
4. **Clean with undo (1:40 to 2:10).** "Review and clean", "Select all safe", remove. A toast offers Undo; click
   it and everything comes back.
5. **Agents (2:10 to 2:45).** Open Agents. Show the states: Finished (six, about 330 MB, "Reclaim finished"),
   Active (`add-search-box`, nothing offered), Unmerged (`refactor-auth` keeps its 2 commits, `wip-export` is
   blocked because the changes exist only in the folder), Abandoned, and the locked one. Open
   `big-migration` (214 MB, merged, clean) and reclaim the finished ones.
6. **History (2:45 to 3:00).** Open History: removals by day, reasons and sizes, one Restored, one expired
   ("No longer restorable"). Click Restore on the day-old `web-search-filters` batch and watch the worktree and
   branch come back for real. Last, glance at `atelier-noir` (default branch unknown) and the broken
   `restored-from-backup` card to show Lopper says "I do not know" instead of guessing.
7. **Optional extra 30 seconds: Disk.** Open Disk. Group by project, then by kind: `node_modules`, `.next`,
   `target`, `.build`, `.venv`. Filter to "Untouched 30+ days" (`blog-2022`, `hackathon-weekend`,
   `web-billing-portal`). Show a blocked row (`harbor-bakery` has no lockfile, `legacy-portal` has no way to
   rebuild `build/`) and clear one folder to the Trash with Undo. Use the recipe above to show the tracked-file
   refusal.
