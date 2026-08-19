#!/usr/bin/env bash
# After a successful package build, record published package revision (+webdriverN)
# and (for MONITOR_SERIES) the upstream webkit2gtk source version.
#
# Tag checkouts are detached HEAD — commit on top of origin/main and push refs/heads/main.
#
# Env:
#   SERIES   Ubuntu series that just built (required)
#   SUFFIX   Debian package suffix that was built (required)
#   MONITOR_SERIES  Series whose upstream version the monitor tracks (default: resolute)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/webdriver-revision.sh
source "$REPO_ROOT/scripts/lib/webdriver-revision.sh"

SERIES="${SERIES:?SERIES is required}"
SUFFIX="${SUFFIX:?SUFFIX is required}"
MONITOR_SERIES="${MONITOR_SERIES:-resolute}"

shopt -s nullglob
DEBS=(dist/libwebkitgtk-6.0-webdriver4_*.deb)
if [[ ${#DEBS[@]} -eq 0 ]]; then
  echo "error: no runtime .deb for revision update" >&2
  exit 1
fi

pkg_version="$(dpkg-deb -f "${DEBS[0]}" Version)"
if [[ "$pkg_version" != *"$SUFFIX" ]]; then
  echo "error: built package version $pkg_version does not end with suffix $SUFFIX" >&2
  exit 1
fi

echo "==> recording published package suffix $SUFFIX for $SERIES ($pkg_version)"

git fetch origin main
git checkout -B main origin/main

record_webdriver_revision "$SERIES" "$SUFFIX"

upstream=""
if [[ "$SERIES" == "$MONITOR_SERIES" ]]; then
  upstream="${pkg_version%"$SUFFIX"}"
  echo "==> recording tracked upstream webkit2gtk version: $upstream"
  {
    echo '# Last upstream webkit2gtk source version we successfully built and released.'
    echo '# Updated automatically when a tag-triggered build publishes .debs.'
    echo "$upstream"
  } >.github/tracked-upstream-version
  {
    echo '# Upstream webkit2gtk version queued for an in-flight auto-build (empty = none).'
    echo
  } >.github/pending-upstream-version
fi

git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git add .github/webdriver-revision
if [[ -n "$upstream" ]]; then
  git add .github/tracked-upstream-version .github/pending-upstream-version
fi
if git diff --staged --quiet; then
  echo "==> package revision unchanged"
  exit 0
fi

if [[ -n "$upstream" ]]; then
  git commit -m "Record ${SUFFIX} for ${SERIES}; track upstream webkit2gtk ${upstream}"
else
  git commit -m "Record ${SUFFIX} for ${SERIES} after successful package build"
fi
git push origin HEAD:refs/heads/main
echo "==> pushed package revision for $SERIES ($SUFFIX) to main"
