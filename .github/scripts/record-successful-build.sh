#!/usr/bin/env bash
# After a successful tag-triggered package build, record the upstream version on main.
#
# Tag checkouts are detached HEAD — `git push origin HEAD` cannot create a branch
# ref. Always commit on top of origin/main and push refs/heads/main.
#
# Env:
#   SERIES   Ubuntu series that just built (required)
#   SUFFIX   Debian version suffix (default: +webkitgtk1)
#   MONITOR_SERIES  Series whose version the upstream monitor tracks (default: resolute)
set -euo pipefail

SERIES="${SERIES:?SERIES is required}"
SUFFIX="${SUFFIX:-+webkitgtk1}"
MONITOR_SERIES="${MONITOR_SERIES:-resolute}"

if [[ "$SERIES" != "$MONITOR_SERIES" ]]; then
  echo "==> skip tracked-version update (built $SERIES; monitor tracks $MONITOR_SERIES)"
  exit 0
fi

shopt -s nullglob
DEBS=(dist/libwebkitgtk-6.0-4_*.deb)
if [[ ${#DEBS[@]} -eq 0 ]]; then
  echo "error: no runtime .deb for tracked version update" >&2
  exit 1
fi

pkg_version="$(dpkg-deb -f "${DEBS[0]}" Version)"
upstream="${pkg_version%"$SUFFIX"}"
if [[ "$upstream" == "$pkg_version" ]]; then
  echo "warning: package version $pkg_version did not end with suffix $SUFFIX" >&2
  upstream="${pkg_version%%+*}"
fi

echo "==> recording tracked upstream webkit2gtk version: $upstream"

git fetch origin main
git checkout -B main origin/main

{
  echo '# Last upstream webkit2gtk source version we successfully built and released.'
  echo '# Updated automatically when a tag-triggered build publishes .debs.'
  echo "$upstream"
} >.github/tracked-upstream-version
{
  echo '# Upstream webkit2gtk version queued for an in-flight auto-build (empty = none).'
  echo
} >.github/pending-upstream-version

git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git add .github/tracked-upstream-version .github/pending-upstream-version
if git diff --staged --quiet; then
  echo "==> tracked upstream version unchanged"
  exit 0
fi
git commit -m "Track upstream webkit2gtk $upstream after successful build"
git push origin HEAD:refs/heads/main
echo "==> pushed tracked version $upstream to main"
