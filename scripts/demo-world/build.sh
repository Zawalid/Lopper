#!/usr/bin/env bash
# Builds the Lopper "demo world": five workspace folders with sixteen real git repositories that look like a
# developer's machine, every verdict and agent state Lopper knows, and a past undo history that really restores.
#
# Usage:  scripts/demo-world/build.sh <target dir> [--force]
#
# - Refuses to run when <target> exists and is not empty. --force deletes <target> itself (and only that), and
#   only when it carries the marker this script leaves behind.
# - No network, no sudo. Git identity and config are isolated, nothing in the real git config is touched.
# - Everything is dated relative to now, so "3 days ago" stays true whenever the world is rebuilt.
# - Writes <target>-support (a sibling folder) with settings.json and undo-log.jsonl for LOPPER_SUPPORT_DIR.
# - See scripts/demo-world/README.md for every scenario and the verdict Lopper should show for it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

FORCE=0
TARGET_ARG=""
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    -*) die "unknown option $arg" ;;
    *) [ -z "$TARGET_ARG" ] || die "only one target directory is accepted"; TARGET_ARG=$arg ;;
  esac
done
[ -n "$TARGET_ARG" ] || die "usage: build.sh <target dir> [--force]"

# ---- the target ------------------------------------------------------------------------------------------------
PARENT_DIR="$(dirname "$TARGET_ARG")"
mkdir -p "$PARENT_DIR"
PARENT_DIR="$(cd "$PARENT_DIR" && pwd -P)"
TARGET="$PARENT_DIR/$(basename "$TARGET_ARG")"
echo "target: $TARGET"

# A mistyped path must never be able to wipe a real folder.
case "$TARGET" in
  /|"$HOME"|/Users|/private|/Volumes|"$HOME"/Library|"$HOME"/Library/*) die "refusing to use $TARGET" ;;
  /System/*|/usr/*|/bin/*|/sbin/*|/etc/*|/Library/*|/Applications/*) die "refusing to use $TARGET" ;;
esac
[ "$(printf '%s' "$TARGET" | awk -F/ '{print NF}')" -ge 4 ] || die "refusing to use $TARGET (too close to the root)"
[ ! -L "$TARGET" ] || die "$TARGET is a symbolic link"

if [ -e "$TARGET" ] && [ -n "$(ls -A "$TARGET" 2>/dev/null)" ]; then
  [ "$FORCE" = 1 ] || die "$TARGET already exists and is not empty (pass --force to rebuild it)"
  [ -f "$TARGET/.demo-world/MARKER" ] || die "--force refused: $TARGET was not created by this script"
  echo "removing the previous world at $TARGET"
  rm -rf "$TARGET"
fi

SUPPORT="$TARGET-support"
UNDO_LOG="$SUPPORT/undo-log.jsonl"
REMOTES="$TARGET/.remotes"
META="$TARGET/.demo-world"
mkdir -p "$TARGET" "$REMOTES" "$META" "$SUPPORT"
for ws in $WORKSPACES; do mkdir -p "$TARGET/$ws"; done
: > "$UNDO_LOG"
printf 'created by scripts/demo-world/build.sh on %s\n' "$(date)" > "$META/MARKER"
: > "$META/active-worktrees.txt"

# ---- isolated git ----------------------------------------------------------------------------------------------
CFG="$(mktemp -d)"
trap 'rm -rf "$CFG"' EXIT
export GIT_CONFIG_GLOBAL="$CFG/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
export XDG_CONFIG_HOME="$CFG/xdg"
export GIT_EDITOR=true GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat
git config --global user.name "Amira Benali"
git config --global user.email "amira@acme.dev"
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global tag.gpgsign false
git config --global core.hooksPath /dev/null
git config --global core.excludesFile /dev/null
git config --global gc.auto 0
git config --global advice.detachedHead false
git config --global advice.addIgnoredFile false
git config --global pull.rebase false

START_SECONDS=$SECONDS

# mark_active <worktree dir>: remember worktrees that must look "touched a few minutes ago" (run.sh refreshes them).
mark_active() { echo "$1" >> "$META/active-worktrees.txt"; }

# ============================================================================================================
# startup-saas: a product team. GitHub organisation "acme".
# ============================================================================================================

# --- web: the busy product repository. Every kind of branch, three user worktrees, a stash.
build_web() {
  new_repo startup-saas web web acme "Customer dashboard and marketing site for Acme Cloud."
  seed "$R" 172 74 <<'EOF'
amira|package.json|chore: initialise next.js app with typescript and eslint
amira|.gitignore|chore: ignore build output and local env files
amira|README.md|docs: describe local setup and environment variables
jonas|src/app/layout.tsx|feat: root layout with navigation shell
jonas|src/app/page.tsx|feat: marketing landing page
priya|src/lib/auth.ts|feat: session based authentication helpers
priya|src/app/login/page.tsx|feat: login and sign up forms
amira|src/app/dashboard/page.tsx|feat: dashboard overview with usage cards
jonas|src/components/button.tsx|refactor: extract shared button component
priya|src/lib/api-client.ts|feat: typed client for the public api
amira|src/app/settings/page.tsx|feat: account settings page
jonas|src/lib/format.ts|fix: format currency with the user locale
priya|src/app/pricing/page.tsx|feat: pricing table with annual toggle
amira|.github/workflows/ci.yml|ci: run lint and tests on pull requests
jonas|src/lib/analytics.ts|feat: product analytics events
EOF
  origin_init

  # Long-lived branches, protected by name (develop, release/*, hotfix/*).
  branch_work develop priya 52 6 "src/lib/feature-flags.ts|feat: feature flag helpers" \
    "src/components/flag-badge.tsx|feat: show active flags in the footer"
  branch_work release/1.x jonas 62 1 "src/lib/cookie-flags.ts|fix: backport secure cookie flags to 1.x"

  # Unmerged and stale: 4 commits, last one 64 days ago, never pushed.
  branch_work feature/dark-mode priya 68 1 \
    "src/styles/theme.ts|feat: theme tokens for dark mode" \
    "src/components/theme-toggle.tsx|feat: theme toggle in the header" \
    "src/app/dark-preview/page.tsx|wip: dark mode preview page" \
    "src/styles/dark.css|style: dark palette for charts"
  # Merged with a merge commit, remote branch deleted afterwards; later checked out in a worktree.
  branch_work feature/billing-portal amira 58 2 \
    "src/app/billing/page.tsx|feat: billing page with invoice list" \
    "src/lib/stripe.ts|feat: stripe customer portal session" \
    "src/components/invoice-table.tsx|feat: sortable invoice table"
  origin_push feature/billing-portal
  # Squash merged, remote branch deleted.
  branch_work fix/login-redirect-loop jonas 46 1 \
    "src/lib/redirect.ts|fix: stop redirect loop when the session cookie is stale" \
    "src/lib/redirect-guard.ts|test: cover redirect guard"
  origin_push fix/login-redirect-loop
  # Merged with a merge commit; later has a worktree with a checklist of untracked files.
  branch_work feature/onboarding-checklist priya 47 2 \
    "src/app/onboarding/page.tsx|feat: onboarding checklist" \
    "src/components/checklist.tsx|feat: checklist item component" \
    "src/lib/onboarding-state.ts|feat: persist onboarding progress"
  # Rebase merged (same patches, new commits on main).
  branch_work chore/upgrade-next-14 amira 40 1 \
    "package.json|chore: upgrade next to 14.2" \
    "src/lib/next-compat.ts|chore: adapt to the 14.2 metadata api"
  # Merged, but a stash entry still belongs to it.
  branch_work chore/lint-cleanup priya 30 1 "src/lib/lint-rules.ts|chore: tighten eslint rules"
  branch_work fix/avatar-upload jonas 36 1 \
    "src/components/avatar-upload.tsx|feat: crop avatar before upload" \
    "src/lib/avatar.ts|fix: reject files over 5 MB"
  branch_work hotfix/csrf-token amira 25 1 "src/lib/csrf.ts|fix: rotate csrf token on login"
  # Created from main and never committed to: "no commits of its own".
  git -C "$R" branch feature/empty-spike main
  # Pushed, then the remote branch was deleted without a merge: "remote gone, nothing proves it merged".
  branch_work experiment/edge-runtime jonas 22 1 \
    "src/middleware.ts|experiment: run middleware on the edge runtime" \
    "src/lib/edge-session.ts|experiment: stateless sessions" \
    "src/lib/edge-cache.ts|experiment: cache headers at the edge"
  origin_push experiment/edge-runtime
  # Recent unmerged work with a live upstream; one commit is not pushed yet.
  branch_work feature/team-invitations priya 9 2 \
    "src/app/team/page.tsx|feat: team members page" \
    "src/lib/invitations.ts|feat: invitation tokens with expiry" \
    "src/components/invite-form.tsx|feat: invite form" \
    "src/app/invite/accept/page.tsx|feat: accept invitation page"
  origin_push feature/team-invitations
  # A branch for the History scenario: merged, worktree removed by Lopper a day ago.
  branch_work feature/search-filters amira 14 1 \
    "src/lib/search-filters.ts|feat: filter model for the search page" \
    "src/components/filter-bar.tsx|feat: filter bar" \
    "src/app/search/page.tsx|feat: wire filters into search"
  origin_push feature/search-filters

  # Landing the work, newest last.
  merge_pr feature/billing-portal 118 50 merge amira
  main_commit jonas 48 src/lib/billing-limits.ts "feat: enforce seat limits on the free plan"
  merge_pr fix/login-redirect-loop 121 44 squash jonas
  merge_pr feature/onboarding-checklist 123 41 merge priya
  main_commit priya 38 src/lib/seat-usage.ts "feat: show seat usage on the dashboard"
  merge_pr chore/upgrade-next-14 124 36 rebase amira
  merge_pr fix/avatar-upload 125 33 merge jonas
  merge_pr chore/lint-cleanup 126 29 merge priya
  merge_pr hotfix/csrf-token 127 24 merge amira
  main_commit jonas 18 src/lib/rate-limit-headers.ts "fix: surface rate limit headers in the client"
  merge_pr feature/search-filters 128 11 merge amira
  main_commit priya 9 src/app/status/page.tsx "feat: status page with incident banner"
  main_commit amira 4 src/lib/i18n.ts "feat: first pass at translations"
  main_commit jonas 1 src/lib/feature-gates.ts "chore: read feature gates from the api"
  git -C "$R" push -q origin main
  origin_drop feature/billing-portal
  origin_drop fix/login-redirect-loop
  origin_drop experiment/edge-runtime
  origin_drop feature/search-filters

  # team-invitations: one more commit after the push.
  who priya; when 1 16 40
  gx -C "$R" switch -q feature/team-invitations
  commit "$R" "wip: resend invitation" src/lib/resend-invitation.ts
  gx -C "$R" switch -q main
  # dark-mode: stale commits, but somebody looked at it two days ago (the reflog knows).
  who amira; when 2 15 5
  gx -C "$R" switch -q feature/dark-mode
  when 2 15 12
  gx -C "$R" switch -q main
  # lint-cleanup: a stash made while that branch was checked out.
  who priya; when 3 17 30
  gx -C "$R" switch -q chore/lint-cleanup
  printf '// try stricter import ordering\n' >> "$R/src/lib/lint-rules.ts"
  gx -C "$R" stash push -q -m "try stricter import order"
  gx -C "$R" switch -q main

  # Worktrees made by hand, next to the repository.
  local wt="$TARGET/startup-saas"
  # Merged and clean, with a big pile of disposable folders (the "reclaim space" case).
  wt_existing "$wt/web-billing-portal" feature/billing-portal
  bulk "$wt/web-billing-portal" 150 40 0
  age_wt "$wt/web-billing-portal" 50
  # Merged, but a tracked file was edited and not committed.
  wt_existing "$wt/web-avatar-upload" fix/avatar-upload
  printf '// TODO: square crop only\n' >> "$wt/web-avatar-upload/src/components/avatar-upload.tsx"
  bulk "$wt/web-avatar-upload" 20 0 0
  age_wt "$wt/web-avatar-upload" 3
  # Merged, with an untracked notes file and an ignored .env.local.
  wt_existing "$wt/web-onboarding-checklist" feature/onboarding-checklist
  printf 'NEXT_PUBLIC_API_URL=http://localhost:4000\nSTRIPE_SECRET_KEY=sk_test_demo_only\n' \
    > "$wt/web-onboarding-checklist/.env.local"
  printf '# Notes\n\n- ask design about the empty state\n- confetti on completion?\n' \
    > "$wt/web-onboarding-checklist/NOTES.md"
  age_wt "$wt/web-onboarding-checklist" 6
  # History: the search-filters worktree and branch were removed by Lopper yesterday.
  wt_existing "$wt/web-search-filters" feature/search-filters
  bulk "$wt/web-search-filters" 55 15 0
  age_wt "$wt/web-search-filters" 11
  remove_and_log web-search-filters 1 17 feature/search-filters "$wt/web-search-filters" \
    "Merged via PR #128" origin/feature/search-filters completed

  # Checks.
  assert "billing-portal merged" is_ancestor feature/billing-portal
  assert "billing-portal remote gone" is_gone feature/billing-portal
  assert "login squash merged" is_content_included fix/login-redirect-loop
  assert "login not an ancestor" not_ancestor fix/login-redirect-loop
  assert "login remote gone" is_gone fix/login-redirect-loop
  assert "upgrade-next rebase merged" is_content_included chore/upgrade-next-14
  assert "upgrade-next not an ancestor" not_ancestor chore/upgrade-next-14
  assert "lint-cleanup merged" is_ancestor chore/lint-cleanup
  assert "lint-cleanup has a stash" has_stash_for chore/lint-cleanup
  assert "empty-spike has no commits" is_ancestor feature/empty-spike
  assert "edge-runtime unmerged" not_content_included experiment/edge-runtime
  assert "edge-runtime remote gone" is_gone experiment/edge-runtime
  assert "dark-mode unmerged" not_content_included feature/dark-mode
  assert "dark-mode never pushed" no_upstream feature/dark-mode
  assert "team-invitations live upstream" has_live_upstream feature/team-invitations
  assert "team-invitations ahead" ahead_of_default feature/team-invitations 5
  assert "billing worktree clean" is_clean "$wt/web-billing-portal"
  assert "avatar worktree dirty" is_dirty "$wt/web-avatar-upload"
  assert "onboarding worktree untracked" has_untracked "$wt/web-onboarding-checklist"
  assert "search-filters branch removed" test -z "$(git -C "$R" branch --list feature/search-filters)"
  origin_finish git@github.com:acme/web.git
}

# --- api: Go service. Protected-heavy, a locked worktree, a rebase stopped on a conflict, main checkout on a feature.
build_api() {
  new_repo startup-saas api go acme "Public REST API for Acme Cloud."
  seed "$R" 165 78 <<'EOF'
amira|go.mod|chore: initialise go module
amira|README.md|docs: api overview and local development
jonas|cmd/api/main.go|feat: http server with graceful shutdown
priya|internal/http/router.go|feat: chi router and health endpoint
jonas|internal/auth/tokens.go|feat: jwt access and refresh tokens
priya|internal/store/postgres.go|feat: postgres store with migrations
amira|internal/http/projects.go|feat: project endpoints
jonas|internal/http/errors.go|refactor: consistent error envelope
priya|internal/billing/usage.go|feat: usage metering
amira|.github/workflows/ci.yml|ci: go vet and the race detector
jonas|internal/http/middleware.go|feat: request id and structured logging
EOF
  origin_init
  branch_work develop priya 50 8 "internal/http/v2/routes.go|feat: v2 route table" \
    "internal/http/v2/handlers.go|feat: v2 handlers"
  branch_work release/2.0 jonas 70 1 "internal/auth/legacy.go|fix: keep legacy token claims for 2.0"
  branch_work release/1.x jonas 74 1 "internal/auth/v1.go|fix: backport token revocation to 1.x"
  branch_work hotfix/auth-bypass jonas 56 0 "internal/auth/guard.go|fix: reject tokens signed with none"
  branch_work perf/benchmark-harness jonas 40 1 "bench/harness.go|perf: benchmark harness for the list endpoints"
  branch_work fix/token-expiry jonas 33 1 "internal/auth/expiry.go|fix: refresh tokens expire after 30 days" \
    "internal/auth/expiry_test.go|test: expiry boundaries"
  origin_push fix/token-expiry
  branch_work refactor/handlers-split amira 26 1 "internal/http/projects_list.go|refactor: split project handlers" \
    "internal/http/projects_write.go|refactor: move write handlers"
  branch_work feature/webhooks-v2 priya 20 3 \
    "internal/webhooks/queue.go|feat: delivery queue with retries" \
    "internal/webhooks/signer.go|feat: signed payloads" \
    "internal/webhooks/replay.go|feat: replay failed deliveries" \
    "internal/webhooks/dashboard.go|feat: delivery log endpoint" \
    "internal/webhooks/limits.go|feat: per-endpoint rate limits"
  origin_push feature/webhooks-v2
  branch_work feature/pagination priya 16 1 "internal/http/pagination.go|feat: cursor pagination for list endpoints"
  branch_work feature/rate-limiting amira 6 1 \
    "internal/ratelimit/limiter.go|feat: token bucket limiter" \
    "internal/ratelimit/redis.go|feat: redis backed buckets" \
    "internal/http/ratelimit_middleware.go|feat: apply limits per api key"

  merge_pr hotfix/auth-bypass 74 55 merge jonas
  merge_pr perf/benchmark-harness 76 38 merge jonas
  merge_pr fix/token-expiry 77 31 merge jonas
  merge_pr refactor/handlers-split 81 22 squash amira
  main_commit jonas 12 internal/http/pagination.go "refactor: shared pagination helper"
  main_commit priya 7 internal/http/healthz.go "feat: readiness probe checks the database"
  main_commit amira 2 internal/http/openapi.go "docs: publish the openapi document"
  git -C "$R" push -q origin main
  origin_drop fix/token-expiry

  who priya; when 3 11 20
  gx -C "$R" switch -q feature/webhooks-v2
  commit "$R" "wip: webhook delivery metrics" internal/webhooks/metrics.go
  gx -C "$R" switch -q main

  local wt="$TARGET/startup-saas"
  # Locked worktree on a merged branch: only the lock stands in the way.
  wt_existing "$wt/api-benchmarks" perf/benchmark-harness
  gx -C "$R" worktree lock --reason "benchmark run in progress" "$wt/api-benchmarks"
  age_wt "$wt/api-benchmarks" 20
  # A rebase that stopped on a conflict (detached HEAD, conflict markers in the folder).
  wt_existing "$wt/api-pagination" feature/pagination
  who priya; when 2 10 5
  gx -C "$wt/api-pagination" rebase main >/dev/null 2>&1 || true
  age_wt "$wt/api-pagination" 2
  # The main working directory sits on a feature branch, as it often does.
  who amira; when 1 9 15
  gx -C "$R" switch -q feature/rate-limiting

  assert "token-expiry merged" is_ancestor fix/token-expiry
  assert "token-expiry remote gone" is_gone fix/token-expiry
  assert "handlers-split squash merged" is_content_included refactor/handlers-split
  assert "webhooks live upstream" has_live_upstream feature/webhooks-v2
  assert "webhooks ahead" ahead_of_default feature/webhooks-v2 6
  assert "benchmark worktree locked" is_locked "$wt/api-benchmarks"
  assert "pagination rebase in progress" op_in_progress "$wt/api-pagination"
  assert "main working directory on a feature branch" test "$(git -C "$R" branch --show-current)" = feature/rate-limiting
  origin_finish git@github.com:acme/api.git
}

# --- mobile: a pile of old branches, a ghost worktree registration, two past cleanups.
build_mobile() {
  new_repo startup-saas mobile mobile acme "iOS app for Acme Cloud."
  seed "$R" 175 105 <<'EOF'
amira|Package.swift|chore: create swift package and app target
amira|README.md|docs: build instructions and test devices
jonas|Sources/Mobile/AppEntry.swift|feat: app entry point and dependency container
priya|Sources/Mobile/Views/HomeView.swift|feat: home feed
jonas|Sources/Mobile/Networking/APIClient.swift|feat: async api client with token refresh
priya|Sources/Mobile/Views/ProfileView.swift|feat: profile screen
amira|Sources/Mobile/Storage/Cache.swift|feat: disk cache for feed items
jonas|Sources/Mobile/Views/SettingsView.swift|feat: settings screen with notifications toggle
priya|MobileTests/APIClientTests.swift|test: cover token refresh paths
amira|.github/workflows/ci.yml|ci: build and test on macos runners
EOF
  origin_init
  branch_work develop jonas 70 5 "Sources/Mobile/Views/ExperimentsView.swift|feat: experiments screen"
  branch_work spike/widgetkit priya 100 0 "Sources/Mobile/Widgets/FeedWidget.swift|spike: home screen widget"
  branch_work spike/watchos-companion jonas 97 0 "Sources/Mobile/Watch/Complication.swift|spike: watch complication"
  branch_work spike/lottie-splash jonas 86 0 "Sources/Mobile/Views/SplashView.swift|spike: lottie splash animation"
  branch_work spike/swiftui-charts priya 88 0 "Sources/Mobile/Views/UsageChart.swift|spike: usage chart with swift charts"
  branch_work feature/offline-mode amira 80 3 \
    "Sources/Mobile/Sync/OfflineQueue.swift|feat: queue writes while offline" \
    "Sources/Mobile/Sync/Reachability.swift|feat: reachability monitor" \
    "Sources/Mobile/Sync/ConflictResolver.swift|wip: conflict resolution"
  branch_work feature/onboarding-v2 priya 82 2 \
    "Sources/Mobile/Onboarding/WelcomeView.swift|feat: welcome carousel" \
    "Sources/Mobile/Onboarding/PermissionsView.swift|feat: permission primer screens" \
    "Sources/Mobile/Onboarding/OnboardingFlow.swift|feat: onboarding state machine"
  branch_work feature/push-notifications jonas 74 1 \
    "Sources/Mobile/Push/PushRegistrar.swift|feat: register for remote notifications" \
    "Sources/Mobile/Push/PushRouter.swift|feat: route notification taps"
  branch_work feature/dark-icons priya 63 0 "Sources/Mobile/Resources/AppIconDark.swift|feat: dark app icon variants"
  branch_work fix/crash-on-launch amira 66 0 "Sources/Mobile/Storage/Migration.swift|fix: crash when the cache schema is older than v3"
  branch_work fix/keyboard-overlap priya 60 0 "Sources/Mobile/Views/KeyboardGuide.swift|fix: keyboard covers the comment field"
  branch_work fix/ios17-layout jonas 56 0 "Sources/Mobile/Views/SafeAreaFix.swift|fix: safe area insets on ios 17"
  branch_work chore/bump-xcode-15 amira 30 0 "Sources/Mobile/Build/Settings.swift|chore: build with xcode 15.3"
  origin_push chore/bump-xcode-15
  branch_work chore/swiftlint-0-54 amira 45 0 "Sources/Mobile/Build/Lint.swift|chore: swiftlint 0.54 rules"
  origin_push chore/swiftlint-0-54
  branch_work feature/apple-pay jonas 11 2 \
    "Sources/Mobile/Payments/ApplePayButton.swift|feat: apple pay button" \
    "Sources/Mobile/Payments/PaymentSheet.swift|feat: payment sheet" \
    "Sources/Mobile/Payments/Receipts.swift|feat: receipt storage"
  origin_push feature/apple-pay

  merge_pr feature/onboarding-v2 44 75 merge priya
  merge_pr feature/push-notifications 47 70 squash jonas
  main_commit amira 67 Sources/Mobile/Views/EmptyState.swift "feat: shared empty state view"
  merge_pr fix/crash-on-launch 49 64 rebase amira
  merge_pr feature/dark-icons 50 61 squash priya
  merge_pr fix/keyboard-overlap 51 58 merge priya
  merge_pr fix/ios17-layout 52 54 merge jonas
  main_commit jonas 26 Sources/Mobile/Views/FeedSkeleton.swift "feat: skeleton loading state for the feed"
  main_commit priya 8 Sources/Mobile/Views/Banner.swift "feat: in-app banner for outages"
  git -C "$R" push -q origin main
  origin_drop chore/bump-xcode-15
  origin_drop chore/swiftlint-0-54

  # History: two cleanups of old branches (three nine days ago, two that expired 41 days ago).
  remove_and_log cleanup-spikes 9 10 spike/lottie-splash - "No merge evidence" - completed
  remove_and_log cleanup-spikes 9 10 feature/dark-icons - "Content already in the default branch (squash or rebase merge)" - completed
  remove_and_log cleanup-spikes 9 10 chore/swiftlint-0-54 - "Remote branch was deleted" origin/chore/swiftlint-0-54 completed
  remove_and_log cleanup-old 41 9 spike/widgetkit - "No merge evidence" - expired
  remove_and_log cleanup-old 41 9 spike/watchos-companion - "No merge evidence" - expired

  # A worktree whose folder was deleted by hand: git still lists it ("prunable"), nothing is left on disk.
  local wt="$TARGET/startup-saas/mobile-ios17-fixes"
  wt_existing "$wt" fix/ios17-layout
  age_wt "$wt" 54
  rm -rf "$wt"

  assert "onboarding merged" is_ancestor feature/onboarding-v2
  assert "push squash merged" is_content_included feature/push-notifications
  assert "crash rebase merged" is_content_included fix/crash-on-launch
  assert "crash not an ancestor" not_ancestor fix/crash-on-launch
  assert "offline-mode unmerged" not_content_included feature/offline-mode
  assert "xcode remote gone, unmerged" is_gone chore/bump-xcode-15
  assert "apple-pay live upstream" has_live_upstream feature/apple-pay
  assert "ghost worktree prunable" is_prunable "$wt"
  assert "ghost folder missing" test ! -e "$wt"
  assert "expired keep-alive ref gone" test -z "$(git -C "$R" for-each-ref 'refs/lopper/trash/*/spike/widgetkit')"
  assert "recent keep-alive ref exists" test -n "$(git -C "$R" for-each-ref 'refs/lopper/trash/*/spike/lottie-splash')"
  origin_finish git@github.com:acme/mobile.git
}

# --- docs: small and tidy; one branch that Lopper once deleted and the user restored.
build_docs() {
  new_repo startup-saas docs docs acme "Developer documentation for Acme Cloud."
  seed "$R" 150 70 <<'EOF'
priya|README.md|docs: initial docs structure
priya|docs/introduction.md|docs: introduction and concepts
amira|docs/getting-started.md|docs: getting started guide
jonas|docs/authentication.md|docs: authentication guide
priya|docs/api/projects.md|docs: projects api reference
amira|docs/api/errors.md|docs: error codes
jonas|docs/guides/webhooks.md|docs: webhook delivery and retries
priya|docs/changelog.md|docs: changelog for 1.4
amira|package.json|chore: build the site with docusaurus
EOF
  origin_init
  branch_work docs/migration-guide priya 56 1 "docs/guides/migration.md|docs: migrating from the v1 api" \
    "docs/guides/migration-faq.md|docs: migration faq"
  branch_work docs/getting-started-rewrite amira 40 1 "docs/getting-started-v2.md|docs: rewrite the getting started guide" \
    "docs/quickstart.md|docs: five minute quickstart"
  branch_work docs/api-v2-reference jonas 28 1 "docs/api/v2/overview.md|docs: v2 api overview" \
    "docs/api/v2/pagination.md|docs: pagination in v2"
  origin_push docs/api-v2-reference
  branch_work docs/changelog-2.0 priya 5 1 "docs/changelog-2.0.md|docs: draft changelog for 2.0" \
    "docs/upgrade-2.0.md|docs: upgrade notes for 2.0" "docs/deprecations.md|docs: list deprecations"
  merge_pr docs/migration-guide 15 52 merge priya
  merge_pr docs/getting-started-rewrite 17 36 merge amira
  merge_pr docs/api-v2-reference 19 24 squash jonas
  main_commit amira 10 docs/support.md "docs: how to reach support"
  git -C "$R" push -q origin main
  origin_drop docs/api-v2-reference
  # History: Lopper removed docs/migration-guide 17 days ago, the user restored it the next day.
  remove_and_log restored-guide 17 11 docs/migration-guide - "Merged via PR #15" - restored

  assert "migration-guide restored and merged" is_ancestor docs/migration-guide
  assert "getting-started merged" is_ancestor docs/getting-started-rewrite
  assert "api-v2 squash merged" is_content_included docs/api-v2-reference
  assert "changelog unmerged" not_content_included docs/changelog-2.0
  origin_finish git@github.com:acme/docs.git
}

# ============================================================================================================
# client-work: a small agency. GitHub organisation "northpine-agency"; one site has no remote at all.
# ============================================================================================================

# --- bluebird-studio: staging branch, a detached worktree with a commit nobody else has.
build_bluebird() {
  new_repo client-work bluebird-studio site northpine-agency "Marketing site for Bluebird Studio."
  seed "$R" 165 85 <<'EOF'
tomas|package.json|chore: scaffold the site
tomas|.gitignore|chore: ignore build output
tomas|README.md|docs: deploy and content editing notes
amira|src/layouts/base.html|feat: base layout with seo meta
tomas|src/pages/index.html|feat: home page
tomas|src/pages/about.html|feat: about page
amira|src/styles/global.css|style: typography and spacing scale
tomas|src/pages/services.html|feat: services page
amira|src/scripts/nav.js|feat: accessible mobile navigation
EOF
  origin_init
  branch_work feature/contact-form tomas 78 1 "src/pages/contact.html|feat: contact page" \
    "src/scripts/contact-form.js|feat: contact form with honeypot"
  branch_work feature/case-studies amira 50 2 "src/pages/work.html|feat: case study index" \
    "src/pages/work-detail.html|feat: case study template" "src/styles/work.css|style: case study grid"
  origin_push feature/case-studies
  branch_work fix/hero-image-crop tomas 34 0 "src/styles/hero.css|fix: hero image cropped on small screens"
  branch_work staging tomas 12 6 "src/pages/pricing.html|feat: pricing page preview" \
    "src/styles/pricing.css|style: pricing cards"
  origin_push staging
  branch_work content/spring-campaign amira 9 3 "src/pages/spring.html|content: spring campaign landing page" \
    "src/styles/spring.css|style: campaign colours" "src/scripts/countdown.js|feat: launch countdown" \
    "src/pages/spring-faq.html|content: campaign faq"
  origin_push content/spring-campaign
  merge_pr feature/contact-form 31 74 merge tomas
  merge_pr feature/case-studies 34 41 merge amira
  merge_pr fix/hero-image-crop 36 30 squash tomas
  main_commit tomas 15 src/pages/privacy.html "content: privacy policy update"
  git -C "$R" push -q origin main
  origin_drop feature/case-studies

  # A detached worktree with a commit no branch holds: easy to lose.
  local wt="$TARGET/client-work/bluebird-studio-redesign"
  wt_new "$wt" -
  who tomas; when 12 16 10
  commit "$wt" "try: full bleed hero with video background" src/pages/redesign.html
  age_wt "$wt" 12

  assert "contact-form merged" is_ancestor feature/contact-form
  assert "case-studies merged and remote gone" is_gone feature/case-studies
  assert "hero squash merged" is_content_included fix/hero-image-crop
  assert "staging ahead with live upstream" has_live_upstream staging
  assert "redesign detached" is_detached "$wt"
  assert "redesign has a unique commit" test "$(git -C "$wt" rev-list --count "main..HEAD")" -ge 1
  origin_finish git@github.com:northpine-agency/bluebird-studio.git
}

# --- harbor-bakery: local only (no remote, no links), an unreadable worktree folder.
build_harbor() {
  new_repo client-work harbor-bakery site northpine-agency "Online order site for Harbor Bakery."
  seed "$R" 160 95 <<'EOF'
tomas|package.json|chore: scaffold the site
tomas|.gitignore|chore: ignore build output
tomas|README.md|docs: how to update the menu
tomas|src/pages/index.html|feat: home page with opening hours
tomas|src/pages/menu.html|feat: menu page
amira|src/styles/global.css|style: warm palette and type scale
tomas|src/scripts/cart.js|feat: simple cart in local storage
EOF
  branch_work feature/order-form tomas 80 2 "src/pages/order.html|feat: pre-order form" \
    "src/scripts/order-form.js|feat: validate pickup time" "src/styles/order.css|style: order form"
  branch_work feature/old-theme-revert tomas 90 0 "src/styles/theme-2022.css|chore: bring back the 2022 colours for the holidays"
  branch_work fix/mobile-nav tomas 55 0 "src/scripts/mobile-nav.js|fix: menu does not close after navigating"
  branch_work feature/seasonal-menu tomas 50 2 "src/pages/seasonal.html|feat: seasonal menu page" \
    "src/styles/seasonal.css|style: seasonal banner"
  merge_pr feature/old-theme-revert 0 88 merge tomas
  merge_pr feature/order-form 0 72 merge tomas
  merge_pr fix/mobile-nav 0 52 squash tomas
  main_commit tomas 20 src/pages/jobs.html "content: we are hiring a weekend baker"

  # A folder that was copied away from its repository: the .git link is gone, git still lists it.
  local wt="$TARGET/client-work/harbor-bakery-old-theme"
  wt_existing "$wt" feature/old-theme-revert
  age_wt "$wt" 88
  rm -f "$wt/.git"

  assert "no remote" test -z "$(git -C "$R" remote)"
  assert "order-form merged" is_ancestor feature/order-form
  assert "mobile-nav squash merged" is_content_included fix/mobile-nav
  assert "seasonal-menu unmerged" not_content_included feature/seasonal-menu
  assert "old-theme worktree unreadable" is_prunable "$wt"
  assert "old-theme folder still exists" test -d "$wt"
}

# --- atelier-noir: the default branch is "trunk" and there is no origin, so Lopper cannot know where work lands.
build_atelier() {
  new_repo client-work atelier-noir site northpine-agency "Portfolio site for the photographer Camille Noir."
  git -C "$R" symbolic-ref HEAD refs/heads/trunk
  DEFAULT=trunk
  seed "$R" 150 100 <<'EOF'
tomas|package.json|chore: scaffold the site
tomas|.gitignore|chore: ignore build output
tomas|README.md|docs: how to add a new gallery
tomas|src/pages/index.html|feat: home page with featured series
tomas|src/pages/gallery.html|feat: gallery grid
amira|src/styles/global.css|style: monochrome palette
tomas|src/scripts/lightbox.js|feat: lightbox for gallery images
EOF
  agent_repo
  branch_work redesign/gallery tomas 70 2 "src/pages/gallery-v2.html|feat: masonry gallery" \
    "src/styles/gallery-v2.css|style: masonry columns" "src/scripts/masonry.js|feat: lazy load gallery images"
  branch_work fix/lightbox-focus tomas 48 0 "src/scripts/lightbox-focus.js|fix: trap focus inside the lightbox"
  branch_work feature/booking-widget tomas 70 1 "src/pages/booking.html|feat: booking request form" \
    "src/scripts/booking.js|feat: availability calendar"
  merge_pr redesign/gallery 0 62 merge tomas
  merge_pr fix/lightbox-focus 0 45 squash tomas
  main_commit tomas 20 src/pages/prints.html "content: print shop page"

  # Claude Code worktree in a repository whose default branch is unknown.
  local wt="$R/.claude/worktrees/seo-meta-tags"
  wt_new "$wt" claude/seo-meta-tags trunk
  who tomas; when 3 11 30
  commit "$wt" "feat: open graph and meta description for every page" src/layouts/meta.html
  merge_pr claude/seo-meta-tags 0 3 merge tomas
  age_wt "$wt" 3

  assert "trunk is the head" test "$(git -C "$R" branch --show-current)" = trunk
  assert "no main branch" test -z "$(git -C "$R" branch --list main master)"
  assert "no origin/HEAD" test -z "$(git -C "$R" for-each-ref refs/remotes/origin/HEAD)"
  assert "gallery merged into trunk" is_ancestor redesign/gallery trunk
  assert "seo worktree merged into trunk" is_ancestor claude/seo-meta-tags trunk
  DEFAULT=main
}

# ============================================================================================================
# open-source: two libraries with release branches and tags.
# ============================================================================================================

# --- fastcsv: TypeScript library. Release branches, tags, a bot branch whose remote vanished.
build_fastcsv() {
  new_repo open-source fastcsv lib amirabenali "A small, fast, RFC 4180 compliant CSV parser for TypeScript."
  seed "$R" 170 90 <<'EOF'
amira|package.json|chore: set up typescript library with tsup and vitest
amira|README.md|docs: usage and api overview
amira|.gitignore|chore: ignore build output
amira|src/index.ts|feat: public entry point
amira|src/parser.ts|feat: rfc 4180 compliant parser
priya|src/stringify.ts|feat: stringify with custom delimiters
jonas|src/options.ts|feat: typed options and defaults
amira|test/parser.test.ts|test: parser edge cases
priya|.github/workflows/ci.yml|ci: node 18, 20 and 22 matrix
amira|docs/api.md|docs: api reference
EOF
  who amira; when 150 12 0
  gx -C "$R" tag -a v1.0.0 -m "1.0.0" "main~7"
  when 90 17 30
  gx -C "$R" tag -a v2.0.0 -m "2.0.0" main
  origin_init
  git -C "$R" push -q origin --tags
  BRANCH_BASE=main~3
  branch_work release/1.x amira 100 1 "src/compat-v1.ts|fix: keep the 1.x entry point working"
  unset BRANCH_BASE
  who amira; when 100 18 0
  gx -C "$R" tag -a v1.4.2 -m "1.4.2" release/1.x
  branch_work release/2.x amira 60 1 "src/compat.ts|fix: keep the 2.0 api surface stable"
  branch_work chore/bump-deps jonas 54 0 "src/deps.ts|chore: bump dev dependencies"
  origin_push chore/bump-deps
  branch_work fix/bom-handling jonas 52 1 "src/bom.ts|fix: strip the utf-8 byte order mark" \
    "test/bom.test.ts|test: files with and without a bom"
  origin_push fix/bom-handling
  branch_work fix/quoted-newlines priya 36 0 "src/quoted.ts|fix: newlines inside quoted fields"
  branch_work dependabot/npm_and_yarn/vitest-1.6.0 jonas 18 0 "package-lock.json|build(deps-dev): bump vitest from 1.5.0 to 1.6.0"
  origin_push dependabot/npm_and_yarn/vitest-1.6.0
  branch_work feat/streaming-parser amira 26 3 \
    "src/stream.ts|feat: streaming parser" "src/stream-options.ts|feat: highWaterMark option" \
    "src/node-stream.ts|feat: node transform stream adapter" "src/web-stream.ts|feat: web streams adapter" \
    "test/stream.test.ts|test: chunk boundaries" "docs/streaming.md|docs: streaming guide"
  origin_push feat/streaming-parser

  merge_pr chore/bump-deps 141 50 merge jonas
  merge_pr fix/bom-handling 142 48 merge jonas
  main_commit priya 40 src/bench.ts "perf: avoid regex in the hot path"
  who amira; when 40 18 0
  gx -C "$R" tag -a v2.1.0 -m "2.1.0" main
  merge_pr fix/quoted-newlines 145 31 squash priya
  main_commit amira 14 docs/migrating.md "docs: migrating from 1.x"
  git -C "$R" push -q origin main --tags
  origin_drop fix/bom-handling
  origin_drop dependabot/npm_and_yarn/vitest-1.6.0
  origin_drop chore/bump-deps
  # History: chore/bump-deps was removed 28 days ago, two days before its keep-alive ref expires.
  remove_and_log bump-deps 28 12 chore/bump-deps - "Merged via PR #141" origin/chore/bump-deps completed

  local wt="$TARGET/open-source/fastcsv-release-2.x"
  wt_existing "$wt" release/2.x
  age_wt "$wt" 20

  assert "bom merged" is_ancestor fix/bom-handling
  assert "quoted-newlines squash merged" is_content_included fix/quoted-newlines
  assert "dependabot remote gone" is_gone dependabot/npm_and_yarn/vitest-1.6.0
  assert "dependabot unmerged" not_content_included dependabot/npm_and_yarn/vitest-1.6.0
  assert "streaming live upstream" has_live_upstream feat/streaming-parser
  assert "streaming ahead" ahead_of_default feat/streaming-parser 6
  assert "tags exist" test "$(git -C "$R" tag | wc -l)" -ge 3
  assert "bump-deps removed" test -z "$(git -C "$R" branch --list chore/bump-deps)"
  origin_finish git@github.com:amirabenali/fastcsv.git
}

# --- pyrate: Python library. A rebase merge, a stale branch with a live upstream, a clean "bisect" worktree.
build_pyrate() {
  new_repo open-source pyrate py amirabenali "A friendly HTTP client with retries and rate limiting."
  seed "$R" 168 80 <<'EOF'
amira|pyproject.toml|chore: set up packaging with hatch
amira|README.md|docs: quickstart
amira|.gitignore|chore: ignore virtualenvs and caches
jonas|src/pyrate/client.py|feat: sync client with connection pooling
jonas|src/pyrate/retry.py|feat: retry with exponential backoff
priya|src/pyrate/errors.py|feat: exception hierarchy
priya|tests/test_client.py|test: client against a local test server
amira|src/pyrate/auth.py|feat: bearer and basic auth helpers
jonas|.github/workflows/ci.yml|ci: python 3.10 to 3.12
priya|docs/index.md|docs: documentation site skeleton
EOF
  origin_init
  branch_work develop jonas 60 7 "src/pyrate/session.py|feat: session objects" "src/pyrate/cookies.py|feat: cookie jar"
  branch_work release/0.4 amira 76 1 "src/pyrate/compat.py|fix: python 3.9 shims for 0.4"
  branch_work fix/retry-backoff jonas 46 0 "src/pyrate/backoff.py|fix: cap the backoff at 60 seconds"
  origin_push fix/retry-backoff
  branch_work docs/api-reference priya 40 1 "docs/api/client.md|docs: client reference" \
    "docs/api/retry.md|docs: retry reference"
  branch_work feature/async-client amira 58 3 "src/pyrate/aio/client.py|feat: asyncio client" \
    "src/pyrate/aio/pool.py|feat: async connection pool" "src/pyrate/aio/retry.py|feat: async retries"
  origin_push feature/async-client

  merge_pr fix/retry-backoff 55 43 merge jonas
  main_commit priya 38 src/pyrate/timeouts.py "feat: per-request timeouts"
  main_commit jonas 30 src/pyrate/proxies.py "feat: proxy support"
  merge_pr docs/api-reference 58 25 rebase priya
  main_commit amira 10 src/pyrate/py.typed "chore: ship type information"
  git -C "$R" push -q origin main
  origin_drop fix/retry-backoff

  local wt="$TARGET/open-source/pyrate-bisect"
  wt_new "$wt" - "main~4"
  age_wt "$wt" 15

  assert "retry-backoff merged" is_ancestor fix/retry-backoff
  assert "docs rebase merged" is_content_included docs/api-reference
  assert "docs not an ancestor" not_ancestor docs/api-reference
  assert "async-client live upstream, unmerged" has_live_upstream feature/async-client
  assert "bisect worktree detached and clean" is_detached "$wt"
  assert "bisect worktree clean" is_clean "$wt"
  origin_finish git@github.com:amirabenali/pyrate.git
}

# ============================================================================================================
# agents-lab: repositories used heavily with AI coding tools. Worktrees in every tool's own layout.
# ============================================================================================================

# --- agent-playground: Claude Code and Cursor worktrees in the states of a normal week.
build_playground() {
  new_repo agents-lab agent-playground web amirabenali "Sandbox for experiments built together with AI coding tools."
  seed "$R" 125 62 <<'EOF'
amira|package.json|chore: playground for ai assisted experiments
amira|.gitignore|chore: ignore build output
amira|README.md|docs: what lives here and how to run it
amira|src/app/layout.tsx|feat: layout
amira|src/app/page.tsx|feat: experiments index
amira|src/components/button.tsx|feat: button
amira|src/lib/format.ts|feat: formatting helpers
amira|src/components/card.tsx|feat: card component
amira|src/app/chat/page.tsx|feat: chat experiment
EOF
  agent_repo
  origin_init
  local cc="$R/.claude/worktrees" cu="$TARGET/agents-lab/.cursor/worktrees/agent-playground"
  mkdir -p "$cc"

  # History: two finished agent worktrees reclaimed four days ago (about 230 MB between them).
  wt_new "$cc/rename-hooks" claude/rename-hooks
  who amira; when 12 10 0
  commit "$cc/rename-hooks" "refactor: rename use-data hook" src/lib/use-data.ts
  merge_pr claude/rename-hooks 28 11 merge amira
  bulk "$cc/rename-hooks" 70 25 0
  age_wt "$cc/rename-hooks" 11
  wt_new "$cc/css-cleanup" claude/css-cleanup
  who amira; when 9 10 0
  commit "$cc/css-cleanup" "style: drop unused css modules" src/styles/cleanup.css
  merge_pr claude/css-cleanup 30 8 squash amira
  bulk "$cc/css-cleanup" 90 30 0
  age_wt "$cc/css-cleanup" 8
  remove_and_log agents-reclaim 4 9 claude/rename-hooks "$cc/rename-hooks" "Merged via PR #28" - completed
  remove_and_log agents-reclaim 4 9 claude/css-cleanup "$cc/css-cleanup" "Merged via PR #30" - completed

  # Finished: squash merged, clean, idle 5 days.
  wt_new "$cc/tidy-imports" claude/tidy-imports
  who amira; when 5 10 10
  commit "$cc/tidy-imports" "chore: sort and prune imports" src/app/page.tsx
  when 5 10 40
  commit "$cc/tidy-imports" "chore: remove unused exports" src/lib/format.ts
  merge_pr claude/tidy-imports 31 5 squash amira
  bulk "$cc/tidy-imports" 45 12 0
  age_wt "$cc/tidy-imports" 5

  # Cursor: <workspace>/.cursor/worktrees/<repo>/<id>, finished.
  wt_new "$cu/9f8e7d" cursor/dark-theme-tokens
  who amira; when 4 13 0
  commit "$cu/9f8e7d" "feat: dark theme tokens" src/styles/tokens.css
  merge_pr cursor/dark-theme-tokens 32 4 merge amira
  bulk "$cu/9f8e7d" 40 0 0
  age_wt "$cu/9f8e7d" 4
  # Finished: merged with a merge commit, clean, idle 3 days.
  wt_new "$cc/fix-typo-readme" claude/fix-typo-readme
  who amira; when 3 11 0
  commit "$cc/fix-typo-readme" "docs: fix typo in README" README.md
  merge_pr claude/fix-typo-readme 33 3 merge amira
  bulk "$cc/fix-typo-readme" 30 0 0
  age_wt "$cc/fix-typo-readme" 3

  # Unmerged: two commits not in main, clean, idle one day.
  wt_new "$cc/refactor-auth" claude/refactor-auth
  who amira; when 1 9 10
  commit "$cc/refactor-auth" "refactor: split auth module" src/lib/auth.ts
  when 1 9 50
  commit "$cc/refactor-auth" "refactor: add session helper" src/lib/session.ts
  bulk "$cc/refactor-auth" 60 18 0
  age_wt "$cc/refactor-auth" 1 10

  # Uncommitted work in the folder: a modified tracked file and an untracked notes file, idle 2 days.
  wt_new "$cc/wip-export" claude/wip-export
  who amira; when 2 15 0
  commit "$cc/wip-export" "wip: export skeleton" src/lib/export.ts
  printf '// unsaved idea: stream the rows\n' >> "$cc/wip-export/src/lib/export.ts"
  printf 'scratch notes about the csv format\n' > "$cc/wip-export/NOTES.txt"
  bulk "$cc/wip-export" 35 0 0
  age_wt "$cc/wip-export" 2

  # Abandoned: committed unmerged work, untouched for 45 days.
  wt_new "$cc/old-websocket-spike" claude/old-websocket-spike
  who amira; when 45 14 0
  commit "$cc/old-websocket-spike" "spike: try websockets for live results" src/lib/ws.ts
  bulk "$cc/old-websocket-spike" 80 0 5
  age_wt "$cc/old-websocket-spike" 45

  # Protected: the branch matches release/*.
  wt_new "$cc/release-prep" release/3.0
  who amira; when 2 10 0
  commit "$cc/release-prep" "chore: bump version to 3.0.0-rc.1" package.json
  age_wt "$cc/release-prep" 2

  # Active: a commit 25 minutes ago and a file edited just now.
  wt_new "$cc/add-search-box" claude/add-search-box
  who amira; when_minutes 25
  commit "$cc/add-search-box" "feat: search box component" src/components/search-box.tsx
  printf '// handle empty query\n' >> "$cc/add-search-box/src/components/search-box.tsx"
  bulk "$cc/add-search-box" 25 6 0
  mark_active "$cc/add-search-box"

  # Cursor, unmerged: two commits, idle 3 days.
  wt_new "$cu/c4b2a1" cursor/form-validation
  who amira; when 3 16 0
  commit "$cu/c4b2a1" "feat: zod schema for the settings form" src/lib/settings-schema.ts
  when 3 16 30
  commit "$cu/c4b2a1" "feat: inline validation messages" src/components/field-error.tsx
  bulk "$cu/c4b2a1" 40 8 0
  age_wt "$cu/c4b2a1" 3

  main_commit amira 2 src/app/about/page.tsx "feat: about page"
  git -C "$R" push -q origin main
  assert "tidy-imports squash merged" is_content_included claude/tidy-imports
  assert "fix-typo merged" is_ancestor claude/fix-typo-readme
  assert "refactor-auth unmerged" not_content_included claude/refactor-auth
  assert "refactor-auth clean" is_clean "$cc/refactor-auth"
  assert "wip-export dirty" is_dirty "$cc/wip-export"
  assert "wip-export untracked" has_untracked "$cc/wip-export"
  assert "old spike unmerged" not_content_included claude/old-websocket-spike
  assert "release-prep on release/3.0" test "$(git -C "$cc/release-prep" branch --show-current)" = release/3.0
  assert "dark-theme-tokens merged" is_ancestor cursor/dark-theme-tokens
  assert "form-validation unmerged" not_content_included cursor/form-validation
  assert "history worktrees removed" test ! -e "$cc/rename-hooks" -a ! -e "$cc/css-cleanup"
  origin_finish git@github.com:amirabenali/agent-playground.git
}

# --- refactor-lab: a monorepo with the big ones: a 350 MB finished worktree, a locked one, detached ones, Conductor.
build_refactor_lab() {
  new_repo agents-lab refactor-lab lib amirabenali "Monorepo used to try large refactors with coding agents."
  seed "$R" 140 50 <<'EOF'
amira|package.json|chore: set up the workspace
amira|.gitignore|chore: ignore build output
amira|README.md|docs: monorepo layout
amira|packages/core/src/index.ts|feat: core package skeleton
jonas|packages/ui/src/index.tsx|feat: ui package
jonas|packages/ui/src/button.tsx|feat: button
priya|packages/config/src/index.ts|feat: shared config
amira|packages/core/src/events.ts|feat: typed event bus
priya|packages/ui/src/modal.tsx|feat: modal
amira|packages/core/src/store.ts|feat: tiny store
EOF
  agent_repo
  origin_init
  local cc="$R/.claude/worktrees"
  mkdir -p "$cc"

  # A branch that only looks like an agent's (codex/ prefix) in an ordinary folder: "Probably Codex".
  local plain="$TARGET/agents-lab/refactor-lab-cleanup"
  wt_new "$plain" codex/cleanup-types
  who amira; when 8 10 0
  commit "$plain" "chore: remove unused type exports" packages/core/src/types.ts
  merge_pr codex/cleanup-types 10 8 merge amira
  age_wt "$plain" 8

  # Finished but locked: Lopper must not touch it.
  wt_new "$cc/locked-docs-sync" claude/locked-docs-sync
  who amira; when 7 11 0
  commit "$cc/locked-docs-sync" "docs: sync package docs" packages/core/docs.md
  merge_pr claude/locked-docs-sync 11 7 squash amira
  gx -C "$R" worktree lock --reason "session still attached" "$cc/locked-docs-sync"
  age_wt "$cc/locked-docs-sync" 6

  # Finished and enormous: merged, clean, node_modules + .next + dist (about 350 MB).
  wt_new "$cc/big-migration" claude/big-migration
  who amira; when 6 10 0
  commit "$cc/big-migration" "refactor: move events to typed channels" packages/core/src/channels.ts
  when 6 12 0
  commit "$cc/big-migration" "refactor: migrate ui to the new channels" packages/ui/src/channels.tsx
  when 5 9 0
  commit "$cc/big-migration" "test: channel ordering" packages/core/src/channels.test.ts
  merge_pr claude/big-migration 12 4 merge amira
  bulk "$cc/big-migration" 220 90 40
  age_wt "$cc/big-migration" 4

  # Detached HEAD with a unique commit, idle 5 days (saved as a branch on removal).
  wt_new "$cc/detached-try" -
  who amira; when 5 15 0
  commit "$cc/detached-try" "try: alternate package layout" packages/core/src/layout.ts
  bulk "$cc/detached-try" 50 0 0
  age_wt "$cc/detached-try" 5
  # Detached, unique commit, idle 70 days (abandoned).
  wt_new "$cc/ancient-detached" - main~6
  who amira; when 70 11 0
  commit "$cc/ancient-detached" "try: bundle everything with esbuild" packages/core/src/esbuild.ts
  age_wt "$cc/ancient-detached" 70

  # Conductor: <workspace>/conductor/workspaces/<repo>/<city>
  local cond="$TARGET/agents-lab/conductor/workspaces/refactor-lab"
  wt_new "$cond/lisbon" amira/lisbon-api-cleanup
  who amira; when 2 14 0
  commit "$cond/lisbon" "refactor: tidy public api surface" packages/core/src/public-api.ts
  bulk "$cond/lisbon" 35 10 0
  age_wt "$cond/lisbon" 2

  main_commit jonas 1 packages/ui/src/tooltip.tsx "feat: tooltip"
  git -C "$R" push -q origin main
  assert "big-migration merged" is_ancestor claude/big-migration
  assert "big-migration clean" is_clean "$cc/big-migration"
  assert "locked-docs-sync squash merged" is_content_included claude/locked-docs-sync
  assert "locked-docs-sync locked" is_locked "$cc/locked-docs-sync"
  assert "detached-try detached" is_detached "$cc/detached-try"
  assert "ancient-detached detached" is_detached "$cc/ancient-detached"
  assert "lisbon unmerged" not_content_included amira/lisbon-api-cleanup
  assert "cleanup-types merged" is_ancestor codex/cleanup-types
  origin_finish git@github.com:amirabenali/refactor-lab.git
}

# --- docsbot: Codex worktrees (<workspace>/.codex/worktrees/<hash>/<repo>), detached like Codex makes them.
build_docsbot() {
  new_repo agents-lab docsbot py amirabenali "Answers questions about a documentation site using retrieval."
  seed "$R" 110 40 <<'EOF'
amira|pyproject.toml|chore: set up the project
amira|.gitignore|chore: ignore caches
amira|README.md|docs: how the retrieval pipeline works
jonas|src/docsbot/index.py|feat: build an embedding index from markdown
jonas|src/docsbot/search.py|feat: top-k semantic search
priya|src/docsbot/answer.py|feat: compose answers with citations
amira|tests/test_search.py|test: search ranking
priya|src/docsbot/cli.py|feat: command line interface
EOF
  origin_init
  local cx="$TARGET/agents-lab/.codex/worktrees"

  # Finished: detached at a commit main already contains, clean, idle 3 days.
  wt_new "$cx/a1b2c3d4/docsbot" -
  blob "$cx/a1b2c3d4/docsbot/.venv/lib/python3.12/site-packages/torch/lib/libtorch_cpu.dylib" 70
  age_wt "$cx/a1b2c3d4/docsbot" 3
  # Unmerged: detached with one commit nobody else has, clean, idle 2 days.
  wt_new "$cx/7e9f0a12/docsbot" -
  who amira; when 2 13 0
  commit "$cx/7e9f0a12/docsbot" "codex: add retry helper for embedding calls" src/docsbot/retry.py
  blob "$cx/7e9f0a12/docsbot/.venv/lib/python3.12/site-packages/numpy/core/_multiarray.so" 40
  age_wt "$cx/7e9f0a12/docsbot" 2
  # Uncommitted: a modified tracked file, idle 4 days.
  wt_new "$cx/5f2e1d00/docsbot" -
  printf '# half finished caching idea\n' >> "$cx/5f2e1d00/docsbot/src/docsbot/search.py"
  age_wt "$cx/5f2e1d00/docsbot" 4
  # Active: edited a few minutes ago.
  wt_new "$cx/3c5d6e78/docsbot" -
  who amira; when_minutes 18
  commit "$cx/3c5d6e78/docsbot" "codex: stream answers token by token" src/docsbot/stream.py
  printf '# todo: backpressure\n' >> "$cx/3c5d6e78/docsbot/src/docsbot/stream.py"
  mark_active "$cx/3c5d6e78/docsbot"

  main_commit priya 1 src/docsbot/config.py "feat: read settings from the environment"
  git -C "$R" push -q origin main
  assert "a1b2 detached and merged" is_ancestor "$(git -C "$cx/a1b2c3d4/docsbot" rev-parse HEAD)"
  assert "7e9f detached" is_detached "$cx/7e9f0a12/docsbot"
  assert "7e9f has a unique commit" test "$(git -C "$cx/7e9f0a12/docsbot" rev-list --count "main..HEAD")" -ge 1
  assert "5f2e dirty" is_dirty "$cx/5f2e1d00/docsbot"
  origin_finish git@github.com:amirabenali/docsbot.git
}

# ============================================================================================================
# archive: older repositories, completely tidy (one branch, nothing to clean), and one broken folder.
# ============================================================================================================

build_archive() {
  new_repo archive legacy-portal php acme "The customer portal before the rewrite."
  seed "$R" 430 340 <<'EOF'
jonas|README.md|docs: portal overview
jonas|src/login.php|feat: login with remember me
jonas|src/dashboard.php|feat: account dashboard
priya|src/invoices.php|feat: invoice download
jonas|src/reset.php|feat: password reset by email
priya|src/admin.php|feat: admin user list
jonas|src/export.php|feat: csv export
EOF
  fake_origin git@github.com:acme/legacy-portal.git
  assert "legacy-portal single branch" test "$(git -C "$R" branch | wc -l | tr -d ' ')" = 1

  new_repo archive hackathon-weekend py amira "Weekend hackathon: summarise meeting notes."
  seed "$R" 380 379 <<'EOF'
amira|README.md|docs: the idea
amira|summarise.py|feat: first working summariser
priya|app.py|feat: tiny web ui
priya|slides.md|docs: demo script
amira|cleanup.py|chore: tidy before the demo
EOF
  assert "hackathon single branch" test "$(git -C "$R" branch | wc -l | tr -d ' ')" = 1

  new_repo archive blog-2022 site amira "Personal blog from 2022."
  seed "$R" 520 300 <<'EOF'
amira|README.md|docs: how to publish a post
amira|_posts/hello-world.md|post: hello world
amira|_posts/notes-on-git-worktrees.md|post: notes on git worktrees
amira|_posts/year-in-review.md|post: 2022 in review
amira|assets/site.css|style: new theme
amira|_posts/moving-to-a-new-laptop.md|post: moving to a new laptop
EOF
  fake_origin git@gitlab.com:amira/blog-2022.git
  assert "blog single branch" test "$(git -C "$R" branch | wc -l | tr -d ' ')" = 1

  # A folder restored from a sync backup: the .git directory is corrupted, so Lopper cannot read it.
  local broken="$TARGET/archive/restored-from-backup"
  mkdir -p "$broken/src" "$broken/.git/objects"
  printf '# restored-from-backup\n\nCopied back from the old external drive.\n' > "$broken/README.md"
  printf 'console.log("recovered");\n' > "$broken/src/index.js"
  printf '\000\000\000 sync conflict: HEAD overwritten\n' > "$broken/.git/HEAD"
  printf '[core]\n\trepositoryformatversion = 0\n' > "$broken/.git/config"
  REPO_COUNT=$((REPO_COUNT + 1))
  if git -C "$broken" rev-parse --git-dir >/dev/null 2>&1; then die "the broken repository is readable"; fi
}

# ---- build everything ------------------------------------------------------------------------------------------
build_web
build_api
build_mobile
build_docs
build_bluebird
build_harbor
build_atelier
build_fastcsv
build_pyrate
build_playground
build_refactor_lab
build_docsbot
build_archive

# ---- Lopper's support folder -----------------------------------------------------------------------------------
write_settings "$SUPPORT" "$TARGET"

# ---- summary ---------------------------------------------------------------------------------------------------
branches=0
worktrees=0
for ws in $WORKSPACES; do
  for repo in "$TARGET/$ws"/*/; do
    [ -d "$repo/.git" ] || continue
    if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then continue; fi
    branches=$((branches + $(git -C "$repo" for-each-ref refs/heads | wc -l)))
    worktrees=$((worktrees + $(git -C "$repo" worktree list | wc -l) - 1))
  done
done
echo
echo "demo world ready: $TARGET"
echo "  repositories : $REPO_COUNT (one of them broken on purpose)"
echo "  branches     : $branches"
echo "  worktrees    : $worktrees linked (plus each repository's main working directory)"
echo "  undo history : $(wc -l < "$UNDO_LOG" | tr -d ' ') log lines in $UNDO_LOG"
echo "  disk         : $(du -sh "$TARGET" | awk '{print $1}')"
echo "  built in     : $((SECONDS - START_SECONDS)) s"
echo "  run the app  : scripts/demo-world/run.sh"
