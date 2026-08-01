#!/usr/bin/env bash
# Bump MARKETING_VERSION in the Xcode project to match a new release tag,
# commit the bump, and create the v<version> tag locally. Neither the commit
# nor the tag is pushed — review with `git log -1` and `git show v<version>`,
# then push with `git push origin main && git push origin v<version>`.
#
# Before tagging it fetches origin and rebases main if it's behind, because CI
# pushes an appcast commit to main on every release. Creating the tag *after*
# that rebase also avoids stranding it on a commit that gets rewritten.
#
# The CI workflow (.github/workflows/release.yml) builds on the tag and
# overrides MARKETING_VERSION/CURRENT_PROJECT_VERSION at archive time, so the
# release artifact carries the tag version regardless. This script's job is
# to keep local/debug builds (About dialog) in sync with the latest tag.
#
# Usage:  scripts/release.sh 1.1.8
#         scripts/release.sh 1.1.8-beta.4

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <version>   e.g. 1.1.8 or 1.1.8-beta.4" >&2
  exit 2
fi

VERSION="$1"

# Loose semver-ish validation: digits.digits.digits with an optional pre-release.
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]; then
  echo "error: version '$VERSION' doesn't look like X.Y.Z or X.Y.Z-pre" >&2
  exit 2
fi

TAG="v$VERSION"
PBXPROJ="StickyDocs/StickyDocs.xcodeproj/project.pbxproj"

cd "$(dirname "$0")/.."

if [ ! -f "$PBXPROJ" ]; then
  echo "error: $PBXPROJ not found — run from repo root" >&2
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "error: working tree is dirty — commit or stash first" >&2
  git status --short >&2
  exit 1
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != "main" ]; then
  echo "error: on branch '$BRANCH', expected main — releases are cut from main" >&2
  exit 1
fi

# Sync with origin before tagging. The release workflow's "Publish appcast"
# step commits docs/appcast.xml back to main, so local main goes stale after
# *every* release. Tagging on a stale main would cut a release that's missing
# the previous release's appcast entry, and the next CI publish would then be
# racing an out-of-date branch. Rebase rather than merge to keep the linear
# history this repo has.
echo "Fetching origin..."
git fetch --prune origin main "refs/tags/*:refs/tags/*"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "error: tag $TAG already exists (local or on origin)" >&2
  exit 1
fi

if ! git merge-base --is-ancestor origin/main HEAD; then
  BEHIND=$(git rev-list --count HEAD..origin/main)
  echo "Local main is $BEHIND commit(s) behind origin/main — rebasing..."
  if ! git rebase origin/main; then
    git rebase --abort 2>/dev/null || true
    echo "error: rebase onto origin/main failed — resolve by hand, then re-run" >&2
    exit 1
  fi
  echo "Rebased onto origin/main."
fi

CURRENT=$(grep -m1 -E "MARKETING_VERSION = " "$PBXPROJ" | sed -E 's/.*MARKETING_VERSION = ([^;]+);.*/\1/')
echo "Bumping MARKETING_VERSION: $CURRENT -> $VERSION"

# All build configurations share the same MARKETING_VERSION line, so
# replace every occurrence in the pbxproj.
sed -i.bak -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $VERSION;/g" "$PBXPROJ"
rm -f "$PBXPROJ.bak"

# Sanity-check: every MARKETING_VERSION line should now read the new value.
if grep -E "MARKETING_VERSION = " "$PBXPROJ" | grep -v "MARKETING_VERSION = $VERSION;" >/dev/null; then
  echo "error: not all MARKETING_VERSION lines were updated" >&2
  git checkout -- "$PBXPROJ"
  exit 1
fi

git add "$PBXPROJ"
git commit -m "Bump MARKETING_VERSION to $VERSION"
git tag -a "$TAG" -m "Release $VERSION"

cat <<EOF

Bumped to $VERSION and created tag $TAG locally.

Next steps:
  git show $TAG          # review the tagged commit
  git push origin main
  git push origin $TAG   # CI builds & publishes once the tag arrives
EOF
