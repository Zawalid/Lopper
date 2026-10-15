#!/usr/bin/env bash
# Builds a throwaway "home" with a repository and agent worktrees in every state the Agents page knows:
# finished, active, unmerged, uncommitted, abandoned and detached, in the Claude Code, Codex and Cursor layouts.
#
# Usage:  scripts/make-agent-fixtures.sh <empty scratch directory>
# Then run the app against it without touching real settings or undo history:
#   mkdir <dir>/support && cp <dir>/home/Library/Application\ Support/Lopper/settings.json <dir>/support/
#   LOPPER_SUPPORT_DIR=<dir>/support build/dev/Build/Products/Debug/Lopper.app/Contents/MacOS/Lopper
set -euo pipefail

SCR="$1"
HOME_DIR="$SCR/home"
CODE="$HOME_DIR/code"
REPO="$CODE/agent-demo"

mkdir -p "$REPO" "$HOME_DIR/Library/Application Support/Lopper"

# Never touch the real git config: identity and defaults live in the scratch home.
export GIT_CONFIG_GLOBAL="$HOME_DIR/.gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
git config --global user.name "Demo Author"
git config --global user.email "demo@lopper.invalid"
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global core.hooksPath /dev/null

days_ago() { date -v-"$1"d "+%Y-%m-%dT%H:%M:%S"; }

# commit <dir> <message> <file> <content> <days ago>
commit() {
  local dir="$1" message="$2" file="$3" content="$4" days="$5" when
  when="$(days_ago "$days")"
  mkdir -p "$(dirname "$dir/$file")"
  printf '%s\n' "$content" > "$dir/$file"
  git -C "$dir" add -A
  GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git -C "$dir" commit -q -m "$message"
}

# age <worktree dir> <worktree git name> <days ago>: make every file and the worktree's creation date old.
age() {
  local dir="$1" name="$2" days="$3" stamp
  stamp="$(date -v-"$days"d +%Y%m%d%H%M)"
  find "$dir" -exec touch -t "$stamp" {} +
  local gitdir="$REPO/.git/worktrees/$name"
  if [ -d "$gitdir" ]; then
    SetFile -d "$(date -v-"$days"d "+%m/%d/%Y %H:%M:%S")" "$gitdir"
    touch -t "$stamp" "$gitdir"
  fi
}

cd "$REPO"
git init -q -b main
printf '.claude/\n' >> .git/info/exclude
commit "$REPO" "initial commit" README.md "# agent-demo" 60
commit "$REPO" "add app entry" src/app.ts "export const app = 1" 59
commit "$REPO" "add config" src/config.ts "export const config = {}" 58

WT="$REPO/.claude/worktrees"
mkdir -p "$WT"

# 1. finished: merged into main, clean, idle for days
git worktree add -q -b claude/fix-typo "$WT/fix-typo" main
commit "$WT/fix-typo" "fix: typo in README" README.md "# agent-demo (fixed)" 3
git merge -q --ff-only claude/fix-typo
age "$WT/fix-typo" fix-typo 3

# 2. active: unmerged, edited just now (inside the grace period)
git worktree add -q -b claude/add-search "$WT/add-search" main
commit "$WT/add-search" "feat: search box" src/search.ts "export const search = 1" 0
printf 'export const search = 2\n' > "$WT/add-search/src/search.ts"

# 3. unmerged: two commits not in main, clean, idle for a day
git worktree add -q -b claude/refactor-auth "$WT/refactor-auth" main
commit "$WT/refactor-auth" "refactor: split auth module" src/auth.ts "export const auth = 1" 1
commit "$WT/refactor-auth" "refactor: add session helper" src/session.ts "export const session = 1" 1
age "$WT/refactor-auth" refactor-auth 1

# 4. uncommitted work only in the folder: modified tracked file plus an untracked file
git worktree add -q -b claude/wip-export "$WT/wip-export" main
commit "$WT/wip-export" "wip: export skeleton" src/export.ts "export const x = 1" 2
printf 'export const x = 2 // unsaved idea\n' > "$WT/wip-export/src/export.ts"
printf 'scratch notes\n' > "$WT/wip-export/NOTES.txt"
age "$WT/wip-export" wip-export 2

# 5. abandoned: committed unmerged work, untouched for 45 days
git worktree add -q -b claude/old-spike "$WT/old-spike" main
commit "$WT/old-spike" "spike: try websockets" src/ws.ts "export const ws = 1" 45
age "$WT/old-spike" old-spike 45

# 6. detached HEAD with a commit no branch holds (Claude Code style folder)
git worktree add -q --detach "$WT/detached-try" main
commit "$WT/detached-try" "try: alternate layout" src/layout.ts "export const layout = 1" 5
age "$WT/detached-try" detached-try 5

# 7. Codex: ~/.codex/worktrees/<hash>/<repo>, detached, one unique commit
CODEX="$HOME_DIR/.codex/worktrees/a1b2c3d4"
mkdir -p "$CODEX"
git worktree add -q --detach "$CODEX/agent-demo" main
commit "$CODEX/agent-demo" "codex: add retry helper" src/retry.ts "export const retry = 3" 2
age "$CODEX/agent-demo" agent-demo 2

# 8. Cursor: ~/.cursor/worktrees/<repo>/<id>, merged, clean
CURSOR="$HOME_DIR/.cursor/worktrees/agent-demo"
mkdir -p "$CURSOR"
git worktree add -q -b cursor/tidy-imports "$CURSOR/9f8e7d" main
commit "$CURSOR/9f8e7d" "chore: tidy imports" src/app.ts "export const app = 2" 4
git merge -q --ff-only cursor/tidy-imports
age "$CURSOR/9f8e7d" 9f8e7d 4

# Lopper settings pointing only at the scratch code folder
cat > "$HOME_DIR/Library/Application Support/Lopper/settings.json" <<EOF
{
  "agentFinishedGraceMinutes" : 120,
  "disposableNames" : ["node_modules", ".next", "dist", "build", ".turbo", ".cache"],
  "folders" : [
    { "excludePatterns" : [], "isEnabled" : true, "path" : "file://$CODE/" }
  ],
  "protectedPatterns" : ["main", "master", "develop", "release/*"],
  "repos" : {},
  "scanDepth" : 3,
  "schemaVersion" : 2,
  "staleDays" : 30,
  "trashRetentionDays" : 30
}
EOF

echo "fixtures ready in $HOME_DIR"
git worktree list
