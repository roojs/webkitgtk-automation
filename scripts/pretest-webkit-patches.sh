#!/usr/bin/env bash
# Dry-run WebKit source patches against cached minimal source files.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/host-series.sh
source "$REPO_ROOT/scripts/lib/host-series.sh"
# shellcheck source=scripts/lib/series-registry.sh
source "$REPO_ROOT/scripts/lib/series-registry.sh"
# shellcheck source=scripts/lib/pinned-webkit-version.sh
source "$REPO_ROOT/scripts/lib/pinned-webkit-version.sh"
# shellcheck source=scripts/lib/webkit-source-fixture.sh
source "$REPO_ROOT/scripts/lib/webkit-source-fixture.sh"

SERIES="${SERIES:-${1:-$(host_series)}}"
SERIES="${SERIES:-resolute}"
PINNED_WEBKIT_VERSION="$(read_pinned_webkit_version "$SERIES")"
WEBKIT_INTERACTIONS_PATCH="$REPO_ROOT/patches/webkit-318171-webdriver-interactions.patch"
WEBKIT_POLICY_PATCH="$(webkit_policy_patch_for_series "$SERIES")"
WEBKIT_GTK_API_PATCH="$REPO_ROOT/patches/webkit-165269-navigator-webdriver-gtk-api.patch"
CMAKE_PATCH="$REPO_ROOT/patches/webkitgtk-variant-suffix.patch"

if ! webkit_source_fixture_ready "$SERIES" "$PINNED_WEBKIT_VERSION"; then
  echo "error: missing webkit source fixture for $SERIES ($PINNED_WEBKIT_VERSION)" >&2
  echo "       run: ./scripts/fetch-fixtures.sh $SERIES" >&2
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/webkitgtk-webkit-pretest.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

cp -a "$(webkit_source_fixture_dir "$SERIES")/." "$TMP/"
cd "$TMP"

for patch in "$WEBKIT_INTERACTIONS_PATCH" "$WEBKIT_POLICY_PATCH" "$WEBKIT_GTK_API_PATCH" "$CMAKE_PATCH"; do
  echo "==> dry-run $patch"
  patch -p1 --dry-run < "$patch"
done

echo "==> webkit patch pretest OK ($SERIES)"
