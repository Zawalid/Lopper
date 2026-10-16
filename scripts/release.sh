#!/usr/bin/env bash
# Cuts a release: bumps the version, writes the changelog entry, commits and tags. It never pushes.
#
#   scripts/release.sh 0.2.0              cut v0.2.0
#   scripts/release.sh 0.2.0 --dry-run    show what would change and the release notes, change nothing
#   SKIP_TESTS=1 scripts/release.sh 0.2.0 skip the engine tests (CI has already run them)
#
# The notes for the new version are the hand-written entries under "Unreleased" in CHANGELOG.md. When that section
# is empty, they are generated from the commit subjects since the previous tag (feat, fix, perf, refactor).
# Afterwards: git push origin main --follow-tags. The tag triggers .github/workflows/release.yml.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
DRY=0
[ "${2:-}" = "--dry-run" ] && DRY=1
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "usage: scripts/release.sh <x.y.z> [--dry-run]" >&2; exit 2; }
TAG="v$VERSION"

[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || { echo "release from main (you are on $(git rev-parse --abbrev-ref HEAD))" >&2; exit 1; }
if [ "$DRY" = 0 ]; then
  [ -z "$(git status --porcelain)" ] || { echo "the working tree is not clean; commit or stash first" >&2; exit 1; }
fi
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "tag $TAG already exists" >&2; exit 1; }

PREVIOUS="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
echo "releasing $TAG (previous: ${PREVIOUS:-none})"

if [ "$DRY" = 0 ] && [ "${SKIP_TESTS:-0}" != 1 ]; then
  echo "running the engine tests"
  swift test 2>&1 | tail -3
fi

NOTES="$(VERSION="$VERSION" PREVIOUS="$PREVIOUS" python3 - <<'PY'
import os, re, subprocess, datetime
version, previous = os.environ["VERSION"], os.environ["PREVIOUS"]
text = open("CHANGELOG.md").read()
m = re.search(r"## \[Unreleased\]\n(.*?)(?=\n## \[|\Z)", text, re.S)
body = m.group(1).strip() if m else ""
if not body:
    rng = f"{previous}..HEAD" if previous else "HEAD"
    subjects = subprocess.run(["git", "log", rng, "--format=%s"], capture_output=True, text=True).stdout.splitlines()
    groups = {"feat": ("Added", []), "fix": ("Fixed", []), "perf": ("Changed", []), "refactor": ("Changed", [])}
    for s in subjects:
        k = re.match(r"(\w+)(\([^)]*\))?!?:\s*(.+)", s)
        if k and k.group(1) in groups:
            groups[k.group(1)][1].append(k.group(3))
    out = {}
    for title, items in groups.values():
        out.setdefault(title, []).extend(items)
    parts = [f"### {t}\n" + "\n".join(f"- {i}" for i in items) for t, items in out.items() if items]
    body = "\n\n".join(parts) or "- Maintenance release."
print(body)
PY
)"

if [ "$DRY" = 1 ]; then
  echo; echo "---- release notes for $TAG ----"; echo "$NOTES"; echo "--------------------------------"
  echo "(dry run: nothing changed)"; exit 0
fi

VERSION="$VERSION" NOTES="$NOTES" python3 - <<'PY'
import os, re, datetime
version, notes = os.environ["VERSION"], os.environ["NOTES"]
text = open("CHANGELOG.md").read()
today = datetime.date.today().isoformat()
text = re.sub(r"## \[Unreleased\]\n.*?(?=\n## \[|\Z)", f"## [Unreleased]\n\n## [{version}] - {today}\n\n{notes}\n", text, count=1, flags=re.S)
open("CHANGELOG.md", "w").write(text)
y = open("App/project.yml").read()
y = re.sub(r"(MARKETING_VERSION: )\S+", rf"\g<1>{version}", y, count=1)
open("App/project.yml", "w").write(y)
PY

git add CHANGELOG.md App/project.yml
git commit -q -m "chore: release $TAG"
git tag -a "$TAG" -m "Lopper $VERSION"
echo "tagged $TAG. Review with: git show $TAG --stat"
echo "Publish with:   git push origin main --follow-tags"
