#!/usr/bin/env bash
# Simulate webkit2gtk build-dep against archive.ubuntu.com for one series (~1–3 min).
# Does not dist-upgrade the host — catches missing/broken archive deps, not post-upgrade
# libx11 skew on a GHA runner (that still needs the full stonking job once).
#
# Usage: ./scripts/probe-archive-build-dep.sh stonking
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/archive-apt.sh
source "$REPO_ROOT/scripts/lib/archive-apt.sh"
# shellcheck source=scripts/lib/series-registry.sh
source "$REPO_ROOT/scripts/lib/series-registry.sh"

SERIES="${1:?series required}"
series_registered "$SERIES" || {
  echo "error: unknown series=$SERIES" >&2
  exit 1
}

APT_BASE="${PROBE_ARCHIVE_APT_BASE:-$REPO_ROOT/.ci-cache/probe-archive-apt-$SERIES}"
mkdir -p "$APT_BASE"

echo "==> probe archive build-dep: series=$SERIES base=$APT_BASE"
archive_apt_init "$SERIES" "$APT_BASE"
archive_apt_update
archive_apt build-dep -s -y webkit2gtk
echo "==> probe archive build-dep OK for $SERIES"
