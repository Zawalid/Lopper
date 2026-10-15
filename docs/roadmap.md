# Lopper roadmap

Living document. Status values: `done`, `next`, `planned`, `idea`. Each item gets a one-page design (what,
why, screens, states, data, risks, tests) before any code, then a plan, then a build. We go one at a time.

## 1. Product

**One line:** Lopper keeps a developer's many repositories, branches and worktrees clean, and makes every
removal safe and undoable. Trust is the product: it never removes work that exists nowhere else.

**Who it is for:** developers with several repositories, and especially people running AI coding agents that
leave worktrees behind (Claude Code, Cursor, Codex).

**Business shape (decide later, prepare now):**
- The safety core stays free: scan, explain, clean, undo. People will not pay for a tool they do not trust yet.
- Paid tier sells convenience and scale: automation, the agents and disk pages, remote cleanup, the CLI,
  longer history.
- Prepare now, build the paywall late: a single `Entitlements` seam so features can be gated without a rewrite.

## 2. Information architecture

Sidebar: **Overview**, **Agents**, **Disk**, **History**, then **Repositories**. Footer: Add folder, Settings.

| Page | Purpose | Status |
|---|---|---|
| Overview (cockpit) | One number, one action, repositories that need attention first | done |
| Repository workbench | Table, filters, inspector, clean selection | done |
| History | Every removal, restore a batch or an item | done (basic) |
| Menu bar popover | Same glance, same one-click clean | done |
| Onboarding | Choose folders, first scan | done (basic) |
| Settings | See section 4 | partial |
| Agents | Worktrees made by AI tools: age, unmerged work, size, finished or abandoned, reclaim all finished | planned |
| Disk | Where space goes: biggest worktrees, build folders; reclaim artifacts without removing the worktree | planned |
| Rules and schedule | "Delete branches merged more than 14 days ago", run weekly, digest notification | planned |
| What's new, About, Updates | Release notes, version, check for updates | planned |

## 3. Feature backlog

### Trust and safety (core, free)
- Remote branch cleanup, opt-in, with the same evidence rules and an undo (`planned`)
- Stash awareness and cleanup (`planned`)
- Per-repository protected patterns and default branch override in the UI (`planned`)
- "Explain this verdict" with the exact git evidence, copyable (`idea`)
- Bare repositories and submodules shown correctly (`planned`)
- Git missing and denied-folder setup screens (`planned`)

### Insight
- Work that exists only on this Mac: unpushed commits, unmerged worktrees, one list (`planned`)
- Branch age, ahead and behind, stale threshold used in the UI (`planned`)
- Reclaimed over time, small and honest (`idea`)

### Automation (paid candidates)
- Rules engine and schedule, with a dry-run preview before the first automatic run (`planned`)
- Notifications: weekly digest, "an agent worktree finished" (`planned`)
- Reacting to merges (file-system events) instead of polling (`idea`)
- `lop` command line tool, designed as a first-class product, sharing the engine (`planned`)
- Shortcuts and App Intents (`idea`)

### Integrations
- GitLab and Bitbucket merge detection next to GitHub (`planned`)
- Open in more editors and terminals, user-defined commands (`planned`)

### Platform and business
- Real app icon, bundle identifier, signing, notarization, DMG (`next` when the product is ready to share)
- Auto-update (Sparkle), release notes, appcast hosting (`planned`)
- Licensing and purchase flow, offline-verifiable licence keys (`idea`, after the free app is loved)
- Opt-in diagnostics: log export, crash reports (`planned`)
- Localization: English and French, string catalogs from now on (`planned`)
- Website, docs, privacy statement: no telemetry by default (`planned`)

## 4. Settings design

One window, sidebar of panes. Everything searchable later.

| Pane | Contents |
|---|---|
| General | Open at login, menu bar count, appearance, language |
| Folders | Scanned folders, depth, exclude patterns, per-folder status |
| Safety | Protected patterns (global and per repo), default branch overrides, throwaway names, stale threshold, retention days |
| Tools | Editor, terminal, GitHub CLI status and sign-in hint |
| Notifications | Digest, agent finished (when Rules exist) |
| Automation | Rules and schedule (when they exist) |
| Advanced | Diagnostics, export logs, reset |
| License | Plan, activate, restore purchase (later) |
| About | Version, updates, acknowledgements |

## 5. Foundations to lay before the feature wave

These are cheap now and expensive later.

1. **Settings architecture:** versioned model with migrations (done: slice 1, see `docs/settings-file.md`), a pane-based window (next: slice 2), one place for defaults.
2. **Localization:** string catalogs and no hard-coded user-facing strings in views.
3. **Entitlements seam:** `Entitlements.isEnabled(.feature)` with everything enabled for now.
4. **Diagnostics:** structured logging and "Export logs" so bug reports are one click.
5. **Persistence plan:** the undo log is JSON lines today; History search and rules will want a small
   database. Decide before History grows.
6. **Background work model:** in-app timers first; a login-item helper only if rules need it.
7. **Fast dev loop:** `scripts/dev.sh` and `#Preview` blocks on every screen (done).
8. **Real-window tests:** keep the window-level click tests growing with every page.

## 6. Order of work

| Phase | Goal | Items |
|---|---|---|
| 0, now | Trust the app | Acceptance on real repositories, bug fixes, deferred minors; dev loop and previews (done, see docs/development.md) |
| 1 | Foundations | Settings architecture, localization, entitlements seam, diagnostics, icon and naming check |
| 2 | Differentiators | Agents page, Disk page with in-place artifact cleanup, richer History |
| 3 | Automation | Rules and schedule, notifications, the `lop` CLI |
| 4 | Ship | Signing, notarization, updates, website, licensing, pricing, private beta |
| 5+ | Reach | Remote branches, GitLab, stash, more tools, teams (only if asked for) |

## 7. How we work through it

1. Pick the next item together.
2. I write a one-page design for it in `docs/superpowers/specs/` (screens, states, data, risks, tests).
3. You approve or change it.
4. I write the plan, build it test first, run the real-window tests, and show it in the running app.
5. Review, merge, tick it off here.

## 8. Open decisions

- Name availability check for "Lopper" before any public release.
- Pricing model (one-time versus subscription) and what exactly is free; decided in phase 4, informed by use.
- Whether automation runs only while the app is open, or via a small helper that runs at login.
