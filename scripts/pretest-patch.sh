#!/usr/bin/env bash
# Preflight: prove the series patch applies to Ubuntu webkit2gtk debian/rules — no compile.
#
# Usage:
#   ./scripts/pretest-patch.sh           # host series (or SERIES=…)
#   ./scripts/pretest-patch.sh questing
#
# Local fixtures (gitignored): fixtures/debian-rules/<series>/debian/rules
# Populate once: ./scripts/fetch-fixtures.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/host-series.sh
source "$REPO_ROOT/scripts/lib/host-series.sh"
# shellcheck source=scripts/lib/series-registry.sh
source "$REPO_ROOT/scripts/lib/series-registry.sh"
# shellcheck source=scripts/lib/packaging-checks.sh
source "$REPO_ROOT/scripts/lib/packaging-checks.sh"
# shellcheck source=scripts/lib/pinned-webkit-version.sh
source "$REPO_ROOT/scripts/lib/pinned-webkit-version.sh"
# shellcheck source=scripts/lib/debian-rules-fixture.sh
source "$REPO_ROOT/scripts/lib/debian-rules-fixture.sh"

SERIES="${SERIES:-${1:-$(host_series)}}"
SERIES="${SERIES:-resolute}"
LAYOUT="$(series_layout "$SERIES")"
PATCH="$(patch_file_for_series "$SERIES")"
PINNED_WEBKIT_VERSION="$(read_pinned_webkit_version "$SERIES")"

if [[ ! -f "$PATCH" ]]; then
  echo "error: missing $PATCH" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "==> pretest series=$SERIES layout=$LAYOUT (pinned webkit2gtk $PINNED_WEBKIT_VERSION)"
echo "==> patch=$PATCH"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/webkitgtk-pretest.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

mkdir -p "$TMP/src/debian"

if debian_rules_fixture_ready "$SERIES" "$PINNED_WEBKIT_VERSION"; then
  echo "==> using local fixture: $(debian_rules_fixture_path "$SERIES")"
  copy_debian_rules_fixture "$SERIES" "$TMP/src/debian/rules"
else
  echo "error: no local debian/rules fixture for $SERIES ($PINNED_WEBKIT_VERSION)" >&2
  echo "       run: ./scripts/fetch-fixtures.sh $SERIES" >&2
  exit 1
fi

echo "==> dry-run patch -p1"
(
  cd "$TMP/src"
  if ! patch -p1 --dry-run < "$PATCH"; then
    echo "error: patch does not apply to $SERIES debian/rules" >&2
    echo "       regenerate $(basename "$PATCH") against that series." >&2
    exit 1
  fi
)

echo "==> applying for real (temp tree only) to confirm"
(
  cd "$TMP/src"
  patch -p1 < "$PATCH" >/dev/null
  assert_patched_rules_markers "$TMP/src/debian/rules" "$LAYOUT"
)

echo "==> linker smoke check (gold)"
if ! command -v ld.gold >/dev/null 2>&1; then
  echo "==> installing binutils-gold for smoke check"
  sudo apt-get install -y binutils-gold
fi
if command -v cc >/dev/null 2>&1 && command -v ld.gold >/dev/null 2>&1; then
  grep -q 'fuse-ld=gold' "$TMP/src/debian/rules"
  echo 'int main(void){return 0;}' | cc -x c - -fuse-ld=gold -o "$TMP/linktest"
  echo "==> gold link smoke OK ($TMP/linktest)"
else
  echo "warning: skipping gold link smoke (cc or ld.gold missing)" >&2
fi

echo "==> pretest OK (patch applies to $SERIES debian/rules)"
