#!/usr/bin/env bash
# Helpers for scripts/demo-world/build.sh. Sourced, never run on its own. Works with the bash 3.2 that ships
# with macOS (no associative arrays, no mapfile, no ${var^}).
#
# Conventions used by every scenario:
#   R          the repository being built (absolute path of its main working directory)
#   REPO_NAME  its folder name, REPO_KIND picks the file templates, ORG is the GitHub organisation of its remote
#   WHEN       the epoch every git command stamps its author and committer date with (set by `when`)
#   WHO_*      the identity every git command uses (set by `who`)

NOW=$(date +%s)
TZ_OFF=$(date +%z)
SEQ=0
WHEN=$NOW
WHO_NAME="Amira Benali"
WHO_EMAIL="amira@acme.dev"
DEFAULT=main
REPO_COUNT=0

die() { echo "demo-world: $*" >&2; exit 1; }

# ---- time -------------------------------------------------------------------------------------------------

# when <days ago> [hour] [minute]: set the clock for the next git commands. Never in the future.
when() {
  local d=$1 h=${2:-10} m=${3:-0}
  WHEN=$(date -v-"${d}"d -v"${h}"H -v"${m}"M -v0S +%s)
  if [ "$WHEN" -gt $((NOW - 60)) ]; then WHEN=$((NOW - 60)); fi
}

# when_minutes <minutes ago>: for anything that must count as "just now".
when_minutes() { WHEN=$((NOW - $1 * 60)); }

# ---- identities (four people, used across all repositories) --------------------------------------------------

who() {
  case "$1" in
    amira) WHO_NAME="Amira Benali"; WHO_EMAIL="amira@acme.dev" ;;
    jonas) WHO_NAME="Jonas Keller"; WHO_EMAIL="jonas@acme.dev" ;;
    priya) WHO_NAME="Priya Raman"; WHO_EMAIL="priya@acme.dev" ;;
    tomas) WHO_NAME="Tomás Ruiz"; WHO_EMAIL="tomas@northpine.studio" ;;
    *) die "unknown author $1" ;;
  esac
}

# gx <git args>: git with the current identity and the current fake clock.
gx() {
  GIT_AUTHOR_NAME="$WHO_NAME" GIT_AUTHOR_EMAIL="$WHO_EMAIL" \
    GIT_COMMITTER_NAME="$WHO_NAME" GIT_COMMITTER_EMAIL="$WHO_EMAIL" \
    GIT_AUTHOR_DATE="$WHEN $TZ_OFF" GIT_COMMITTER_DATE="$WHEN $TZ_OFF" \
    git "$@"
}

# ---- file content --------------------------------------------------------------------------------------------

# camel <name>: "search-box" -> "searchBox"
camel() {
  printf '%s' "$1" | awk -F'[^A-Za-z0-9]+' '{o=$1; for(i=2;i<=NF;i++) o=o toupper(substr($i,1,1)) substr($i,2); print o}'
}

# pascal <name>: "search-box" -> "SearchBox"
pascal() {
  printf '%s' "$1" | awk -F'[^A-Za-z0-9]+' '{o=""; for(i=1;i<=NF;i++) o=o toupper(substr($i,1,1)) substr($i,2); print o}'
}

# file_body <path> <commit message>: small, plausible file content. Every commit changes its file, because the
# message and a running number are part of the content.
file_body() {
  local path=$1 msg=$2 base ident type
  base=$(basename "$path")
  base=${base%.*}
  ident=$(camel "$base")
  type=$(pascal "$base")
  case "$path" in
    package.json)
      case "$REPO_KIND" in
        web) cat <<EOF
{
  "name": "$REPO_NAME",
  "version": "0.$((SEQ % 40)).$((SEQ % 7))",
  "private": true,
  "scripts": { "dev": "next dev", "build": "next build", "lint": "next lint", "test": "vitest run" },
  "dependencies": { "next": "14.2.$((SEQ % 20))", "react": "18.3.1", "react-dom": "18.3.1" },
  "devDependencies": { "typescript": "5.4.$((SEQ % 6))", "vitest": "1.6.0", "eslint": "8.57.0" }
}
EOF
          ;;
        site) cat <<EOF
{
  "name": "$REPO_NAME",
  "version": "1.$((SEQ % 30)).0",
  "private": true,
  "scripts": { "dev": "astro dev", "build": "astro build", "preview": "astro preview" },
  "dependencies": { "astro": "4.5.$((SEQ % 15))" }
}
EOF
          ;;
        *) cat <<EOF
{
  "name": "$REPO_NAME",
  "version": "$((SEQ / 20)).$((SEQ % 20)).0",
  "main": "dist/index.js",
  "types": "dist/index.d.ts",
  "scripts": { "build": "tsup src/index.ts --dts", "test": "vitest run", "lint": "eslint src" },
  "devDependencies": { "tsup": "8.0.2", "typescript": "5.4.$((SEQ % 6))", "vitest": "1.6.0" },
  "license": "MIT"
}
EOF
          ;;
      esac ;;
    .gitignore)
      printf '%s\n' node_modules .next dist build out coverage .turbo .cache .env .env.* '!.env.example' \
        .venv __pycache__ '*.pyc' .pytest_cache DerivedData .build .DS_Store '*.tsbuildinfo' ;;
    README.md)
      printf '# %s\n\n%s\n\n## Getting started\n\n```sh\nnpm install\nnpm run dev\n```\n\n## Notes\n\n- %s\n' \
        "$REPO_NAME" "$REPO_DESC" "$msg" ;;
    go.mod) printf 'module github.com/%s/%s\n\ngo 1.22\n\nrequire github.com/go-chi/chi/v5 v5.0.%d\n' "$ORG" "$REPO_NAME" $((SEQ % 12)) ;;
    Package.swift)
      printf '// swift-tools-version: 5.9\nimport PackageDescription\n\nlet package = Package(\n    name: "%s",\n    platforms: [.iOS(.v16)],\n    targets: [.target(name: "%s"), .testTarget(name: "%sTests", dependencies: ["%s"])]\n)\n' \
        "$REPO_NAME" "$REPO_NAME" "$REPO_NAME" "$REPO_NAME" ;;
    pyproject.toml)
      printf '[project]\nname = "%s"\nversion = "0.%d.%d"\ndescription = "%s"\nrequires-python = ">=3.10"\ndependencies = ["httpx>=0.27"]\n' \
        "$REPO_NAME" $((SEQ / 15)) $((SEQ % 15)) "$REPO_DESC" ;;
    *.yml|*.yaml)
      printf '# %s\nname: %s\non: [pull_request]\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n      - run: npm ci && npm test\n' "$msg" "$base" ;;
    *.tsx)
      printf '// %s\nexport default function %s() {\n  return <section data-testid="%s">%s</section>;\n}\n' \
        "$msg" "$type" "$base" "$type" ;;
    *.ts|*.js|*.mjs)
      printf '// %s\nexport function %s(input: string): string {\n  return input.trim().toLowerCase();\n}\n' "$msg" "$ident" ;;
    *.go)
      printf '// %s\npackage %s\n\nfunc %s(value string) string {\n\treturn value\n}\n' "$msg" "$(printf '%s' "$ident" | tr 'A-Z' 'a-z')" "$type" ;;
    *.swift)
      printf '// %s\nimport Foundation\n\nstruct %s {\n    var id = UUID()\n\n    func run() -> String { "%s" }\n}\n' "$msg" "$type" "$base" ;;
    *.py)
      printf '"""%s"""\n\n\ndef %s(value: str) -> str:\n    return value.strip()\n' "$msg" "$(printf '%s' "$base" | tr '-' '_')" ;;
    *.php)
      printf '<?php\n// %s\nfunction %s($value) {\n    return trim($value);\n}\n' "$msg" "$ident" ;;
    *.css)
      printf '/* %s */\n.%s {\n  display: grid;\n  gap: 1rem;\n}\n' "$msg" "$base" ;;
    *.html)
      printf '<!-- %s -->\n<main class="%s">\n  <h1>%s</h1>\n</main>\n' "$msg" "$base" "$type" ;;
    *.md)
      printf '# %s\n\n%s\n' "$type" "$msg" ;;
    *.json)
      printf '{\n  "name": "%s",\n  "note": "%s"\n}\n' "$base" "$msg" ;;
    *)
      printf '%s\n' "$msg" ;;
  esac
}

# ---- committing ----------------------------------------------------------------------------------------------

# commit <dir> <message> <path> [content]: write one file and commit just that file, with the current clock
# and identity.
commit() {
  local dir=$1 msg=$2 path=$3
  mkdir -p "$(dirname "$dir/$path")"
  SEQ=$((SEQ + 1))
  if [ $# -ge 4 ]; then
    printf '%s\n' "$4" > "$dir/$path"
  else
    file_body "$path" "$msg" > "$dir/$path"
  fi
  gx -C "$dir" add -- "$path"
  gx -C "$dir" commit -q -m "$msg"
}

# seed <dir> <from days ago> <to days ago>, lines "author|path|message" on stdin: a linear history spread
# evenly between the two dates, with working-hours timestamps.
seed() {
  local dir=$1 from=$2 to=$3 line i=0 n d a path msg
  local lines=()
  while IFS= read -r line; do
    if [ -n "$line" ]; then lines+=("$line"); fi
  done
  n=${#lines[@]}
  for line in "${lines[@]}"; do
    d=$((from - (from - to) * i / (n > 1 ? n - 1 : 1)))
    IFS='|' read -r a path msg <<<"$line"
    who "$a"
    when "$d" $((9 + (i * 5) % 9)) $(((i * 13) % 60))
    commit "$dir" "$msg" "$path"
    i=$((i + 1))
  done
}

# ---- repositories ---------------------------------------------------------------------------------------------

# new_repo <workspace> <name> <kind> <org> <description>: an empty repository on main, R set to it.
new_repo() {
  WS=$1
  REPO_NAME=$2
  REPO_KIND=$3
  ORG=$4
  REPO_DESC=$5
  R="$TARGET/$WS/$REPO_NAME"
  mkdir -p "$R"
  git init -q -b main "$R"
  DEFAULT=main
  REPO_COUNT=$((REPO_COUNT + 1))
}

# agent_repo: keep Claude Code's folder out of `git status`, like Claude Code itself does.
agent_repo() { printf '.claude/\n' >> "$R/.git/info/exclude"; }

# branch_work <name> <author> <first commit days ago> <days between commits> "path|message"...
# A branch off main (or off $BRANCH_BASE when set) with one commit per spec. Main stays checked out afterwards.
branch_work() {
  local name=$1 author=$2 start=$3 step=$4 spec i=0 d path msg
  shift 4
  who "$author"
  when "$start" 9 30
  gx -C "$R" switch -q -c "$name" "${BRANCH_BASE:-$DEFAULT}"
  for spec in "$@"; do
    d=$((start - i * step))
    if [ "$d" -lt 0 ]; then d=0; fi
    when "$d" $((10 + (i * 3) % 7)) $(((i * 17) % 60))
    IFS='|' read -r path msg <<<"$spec"
    commit "$R" "$msg" "$path"
    i=$((i + 1))
  done
  gx -C "$R" switch -q "$DEFAULT"
}

# main_commit <author> <days ago> <path> <message>: a commit straight on main (main must be checked out in R).
main_commit() {
  who "$1"
  when "$2" $((9 + SEQ % 8)) $((SEQ * 7 % 60))
  commit "$R" "$4" "$3"
}

# merge_pr <branch> <PR number | 0> <days ago> merge|squash|rebase [author]: land a branch on main the way GitHub
# does. PR number 0 means a local merge without a pull request ("Merge branch ...").
merge_pr() {
  local br=$1 pr=$2 days=$3 mode=$4 title c
  who "${5:-amira}"
  when "$days" 15 20
  title=$(git -C "$R" log -1 --format=%s "$br")
  case "$mode" in
    merge)
      if [ "$pr" = 0 ]; then
        gx -C "$R" merge -q --no-ff -m "Merge branch '$br'" "$br"
      else
        gx -C "$R" merge -q --no-ff -m "Merge pull request #$pr from $ORG/$br" -m "$title" "$br"
      fi ;;
    squash)
      gx -C "$R" merge -q --squash "$br" >/dev/null 2>&1
      if [ "$pr" = 0 ]; then gx -C "$R" commit -q -m "$title"; else gx -C "$R" commit -q -m "$title (#$pr)"; fi ;;
    rebase)
      for c in $(git -C "$R" rev-list --reverse "$DEFAULT..$br"); do
        gx -C "$R" cherry-pick "$c" >/dev/null
      done ;;
    *) die "unknown merge mode $mode" ;;
  esac
}

# ---- remotes -------------------------------------------------------------------------------------------------
# Real bare repositories live in <target>/.remotes so that pushes, upstream tracking and "remote branch
# deleted" are genuine. origin_finish then rewrites the URL to a GitHub-style address that is never contacted.

origin_init() {
  ORIGIN_BARE="$REMOTES/$WS-$REPO_NAME.git"
  git init -q --bare -b main "$ORIGIN_BARE"
  git -C "$R" remote add origin "$ORIGIN_BARE"
  git -C "$R" push -q -u origin "$DEFAULT"
  git -C "$R" remote set-head origin "$DEFAULT" >/dev/null
}

# origin_push <branch>: publish a branch and set its upstream.
origin_push() { git -C "$R" push -q -u origin "$1" 2>/dev/null; }

# origin_drop <branch>: the branch disappears on the remote (merged PR with "delete branch"), then a prune.
origin_drop() {
  git -C "$ORIGIN_BARE" branch -q -D "$1"
  git -C "$R" fetch -q --prune origin
}

# origin_finish <url>: from here on the remote is the fake address; nothing may push or fetch any more.
origin_finish() { git -C "$R" remote set-url origin "$1"; }

# ---- worktrees -----------------------------------------------------------------------------------------------

# wt_new <path> <new branch | -> [start point]: a worktree on a new branch (or detached with "-").
wt_new() {
  mkdir -p "$(dirname "$1")"
  if [ "$2" = "-" ]; then
    gx -C "$R" worktree add -q --detach "$1" "${3:-$DEFAULT}"
  else
    gx -C "$R" worktree add -q -b "$2" "$1" "${3:-$DEFAULT}"
  fi
}

# wt_existing <path> <branch>: a worktree on a branch that already exists.
wt_existing() {
  mkdir -p "$(dirname "$1")"
  gx -C "$R" worktree add -q "$1" "$2"
}

# wt_gitdir <worktree dir>: the worktree's entry under .git/worktrees, read from its .git file.
wt_gitdir() { sed -n 's/^gitdir: //p' "$1/.git"; }

# age_wt <dir> <days ago> [hour]: make every file in the worktree and the creation date of its git entry that
# old. Lopper reads both (newest file, creation date) to decide whether an agent is still working.
age_wt() {
  local dir=$1 days=$2 hour=${3:-14} stamp gitdir
  stamp=$(date -v-"$days"d -v"$hour"H -v7M +%Y%m%d%H%M)
  gitdir=$(wt_gitdir "$dir")
  find "$dir" -exec touch -t "$stamp" {} +
  SetFile -d "$(date -v-"$days"d -v"$hour"H -v7M -v0S '+%m/%d/%Y %H:%M:%S')" "$gitdir"
  touch -t "$stamp" "$gitdir"
}

# ---- disk usage ----------------------------------------------------------------------------------------------

# blob <file> <MB>: a file of real bytes (zeros are real allocated blocks on APFS).
blob() {
  mkdir -p "$(dirname "$1")"
  dd if=/dev/zero of="$1" bs=1048576 count="$2" 2>/dev/null
}

# bulk <worktree dir> <node_modules MB> <.next MB> <dist MB>: the disposable folders a front end project leaves.
bulk() {
  local dir=$1 nm=$2 nx=$3 ds=$4 pkg
  for pkg in typescript next react-dom @swc/core-darwin-arm64 esbuild webpack; do
    mkdir -p "$dir/node_modules/$pkg"
    printf '{ "name": "%s", "version": "1.0.0" }\n' "$pkg" > "$dir/node_modules/$pkg/package.json"
    printf 'module.exports = {};\n' > "$dir/node_modules/$pkg/index.js"
  done
  if [ "$nm" -gt 0 ]; then
    blob "$dir/node_modules/typescript/lib/typescript.js" $((nm * 4 / 10 + 1))
    blob "$dir/node_modules/@swc/core-darwin-arm64/swc.node" $((nm * 3 / 10 + 1))
    blob "$dir/node_modules/next/dist/compiled/bundle.js" $((nm * 2 / 10 + 1))
    blob "$dir/node_modules/webpack/lib/bundle.js" $((nm / 10 + 1))
  fi
  if [ "$nx" -gt 0 ]; then
    blob "$dir/.next/cache/webpack/client-production.pack" "$nx"
    printf '{}\n' > "$dir/.next/build-manifest.json"
  fi
  if [ "$ds" -gt 0 ]; then
    blob "$dir/dist/bundle.js" "$ds"
  fi
}

# bytes_of <dir>: allocated bytes on disk, the way the app measures a worktree.
bytes_of() { echo $(($(du -sk "$1" | awk '{print $1}') * 1024)); }

# ---- checks ---------------------------------------------------------------------------------------------------
# Cheap assertions that fail the build loudly when a scenario did not come out as intended.

assert() {
  local what=$1
  shift
  if ! "$@" >/dev/null 2>&1; then die "scenario check failed in $REPO_NAME: $what"; fi
}

# These read R and the default branch main.
is_ancestor() { git -C "$R" merge-base --is-ancestor "$1" "${2:-$DEFAULT}"; }
not_ancestor() { ! is_ancestor "$@"; }
is_content_included() {
  local merged tree
  merged=$(git -C "$R" merge-tree --write-tree --no-messages "${2:-$DEFAULT}" "$1" | head -1) || return 1
  tree=$(git -C "$R" rev-parse "${2:-$DEFAULT}^{tree}")
  [ "$merged" = "$tree" ]
}
not_content_included() { ! is_content_included "$@"; }
is_gone() { git -C "$R" for-each-ref --format='%(upstream:track)' "refs/heads/$1" | grep -q gone; }
has_live_upstream() {
  [ -n "$(git -C "$R" for-each-ref --format='%(upstream)' "refs/heads/$1")" ] && ! is_gone "$1"
}
no_upstream() { [ -z "$(git -C "$R" for-each-ref --format='%(upstream)' "refs/heads/$1")" ]; }
ahead_of_default() { [ "$(git -C "$R" rev-list --count "$DEFAULT..$1")" -ge "$2" ]; }
is_dirty() { [ -n "$(git -C "$1" status --porcelain --untracked-files=no)" ]; }
is_clean() { [ -z "$(git -C "$1" status --porcelain)" ]; }
has_untracked() { [ -n "$(git -C "$1" status --porcelain --ignored --untracked-files=normal | grep -E '^(\?\?|!!) ' | grep -v -E 'node_modules|\.next|dist')" ]; }
is_detached() { [ -z "$(git -C "$1" branch --show-current)" ]; }
is_locked() { git -C "$R" worktree list --porcelain | grep -A5 "^worktree $1\$" | grep -q '^locked'; }
is_prunable() { git -C "$R" worktree list --porcelain | grep -A6 "^worktree $1\$" | grep -q '^prunable'; }
op_in_progress() { [ -e "$(git -C "$1" rev-parse --absolute-git-dir)/rebase-merge" ] || [ -e "$(git -C "$1" rev-parse --absolute-git-dir)/MERGE_HEAD" ]; }
has_stash_for() { git -C "$R" stash list --format=%gs | grep -q "^\(WIP on\|On\) $1:"; }
branch_exists() { git -C "$R" rev-parse --verify -q "refs/heads/$1"; }

# ---- remotes that were never pushed to -------------------------------------------------------------------------

# fake_origin <url>: a remote that looks like it was pushed (tracking ref, upstream, origin/HEAD) without a server.
fake_origin() {
  git -C "$R" remote add origin "$1"
  git -C "$R" update-ref "refs/remotes/origin/$DEFAULT" "$DEFAULT"
  git -C "$R" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$DEFAULT"
  git -C "$R" branch -q --set-upstream-to="origin/$DEFAULT" "$DEFAULT"
}

# ---- Lopper's own files ----------------------------------------------------------------------------------------

WORKSPACES="startup-saas client-work open-source agents-lab archive"

# write_settings <support dir> <target>: settings.json (schema 2) listing only the demo workspaces as folders.
write_settings() {
  local support=$1 target=$2 ws sep=""
  mkdir -p "$support"
  {
    printf '{\n  "agentFinishedGraceMinutes" : 120,\n'
    printf '  "disposableNames" : ["node_modules", ".next", ".nuxt", ".turbo", ".cache", "dist", "build", "out", "target", "DerivedData", "Pods", ".gradle", ".venv", "__pycache__", ".pytest_cache", ".ruff_cache", ".mypy_cache", ".tox", ".eslintcache", ".parcel-cache", ".svelte-kit", ".vite", ".angular", "coverage", ".DS_Store", "Thumbs.db", "*.tsbuildinfo", "*.pyc"],\n'
    printf '  "folders" : [\n'
    for ws in $WORKSPACES; do
      printf '%s    { "excludePatterns" : [], "isEnabled" : true, "path" : "file://%s/%s/" }' "$sep" "$target" "$ws"
      sep=$',\n'
    done
    printf '\n  ],\n'
    printf '  "protectedPatterns" : ["main", "master", "develop", "release/*", "hotfix/*"],\n'
    printf '  "repos" : {},\n  "scanDepth" : 4,\n  "schemaVersion" : 2,\n  "staleDays" : 30,\n  "trashRetentionDays" : 30\n}\n'
  } > "$support/settings.json"
}

# uuid_for <seed>: a stable UUID, so rebuilding the world writes the same record ids.
uuid_for() {
  local h
  h=$(printf '%s' "$1" | md5 -q | tr 'a-f' 'A-F')
  echo "${h:0:8}-${h:8:4}-${h:12:4}-${h:16:4}-${h:20:12}"
}

iso_utc() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }

# json_str <value>: JSON string literal.
json_str() { printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"; }

# undo_line <id> <epoch> <repo> <action> <branch> <tip> <upstream> <worktree path> <trash ref> <status> <detail> <batch> <reason> <bytes>
# One UndoRecord as a JSON line (empty arguments are left out, like the app's own encoder does for nil).
undo_line() {
  local out
  out="{\"id\":$(json_str "$1"),\"timestamp\":$(json_str "$(iso_utc "$2")"),\"repoPath\":$(json_str "$3"),\"action\":$(json_str "$4")"
  if [ -n "$5" ]; then out="$out,\"branch\":$(json_str "$5")"; fi
  out="$out,\"tip\":$(json_str "$6")"
  if [ -n "$7" ]; then out="$out,\"upstream\":$(json_str "$7")"; fi
  if [ -n "$8" ]; then out="$out,\"worktreePath\":$(json_str "$8")"; fi
  out="$out,\"trashRef\":$(json_str "$9")"
  out="$out,\"status\":$(json_str "${10}")"
  if [ -n "${11}" ]; then out="$out,\"detail\":$(json_str "${11}")"; fi
  if [ -n "${12}" ]; then out="$out,\"batchID\":$(json_str "${12}")"; fi
  if [ -n "${13}" ]; then out="$out,\"reason\":$(json_str "${13}")"; fi
  if [ -n "${14}" ]; then out="$out,\"bytes\":${14}"; fi
  echo "$out}" >> "$UNDO_LOG"
}

# ---- undo history ----------------------------------------------------------------------------------------------

# remove_and_log <batch> <days ago> <hour> <branch> <worktree dir | -> <reason> <upstream | -> <final status>
# Does what Lopper's Cleaner does, for real, at a past time: keep-alive ref under refs/lopper/trash, remove the
# worktree (if any) and delete the branch, then append the matching undo records. The final status is
# "completed" (restorable), "restored" (the branch is back) or "expired" (older than the retention window, the
# keep-alive ref is gone). Records of one call share a batch id.
remove_and_log() {
  local batch tip epoch bytes="" upstream="" status=$8 ref
  batch=$(uuid_for "batch:$REPO_NAME:$1")
  local days=$2 hour=$3 branch=$4 wt=$5 reason=$6
  if [ "$7" != "-" ]; then upstream=$7; fi
  tip=$(git -C "$R" rev-parse "refs/heads/$branch")
  when "$days" "$hour" 12
  epoch=$WHEN
  if [ "$wt" != "-" ]; then
    bytes=$(bytes_of "$wt")
    ref="refs/lopper/trash/$epoch/$branch"
    git -C "$R" update-ref "$ref" "$tip"
    git -C "$R" worktree remove --force "$wt"
    undo_line "$(uuid_for "wt:$REPO_NAME:$1:$branch")" "$epoch" "$R" removeWorktree "$branch" "$tip" "" "$wt" \
      "$ref" completed "" "$batch" "$reason" "$bytes"
    epoch=$((epoch + 1))
  fi
  ref="refs/lopper/trash/$epoch/$branch"
  git -C "$R" update-ref "$ref" "$tip"
  git -C "$R" branch -q -D "$branch"
  local id
  id=$(uuid_for "br:$REPO_NAME:$1:$branch")
  undo_line "$id" "$epoch" "$R" deleteBranch "$branch" "$tip" "$upstream" "" "$ref" completed "" "$batch" "$reason" ""
  case "$status" in
    restored)
      git -C "$R" branch -q "$branch" "$tip"
      git -C "$R" update-ref -d "$ref"
      undo_line "$id" "$epoch" "$R" deleteBranch "$branch" "$tip" "$upstream" "" "$ref" restored \
        "Restored branch $branch" "$batch" "$reason" "" ;;
    expired)
      git -C "$R" update-ref -d "$ref"
      undo_line "$id" "$epoch" "$R" deleteBranch "$branch" "$tip" "$upstream" "" "$ref" expired "" "$batch" \
        "$reason" "" ;;
  esac
}
