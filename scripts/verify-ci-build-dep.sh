#!/usr/bin/env bash
# Exercise the CI runner apt path through webkit2gtk build-dep — no WebKit compile.
#
# On GitHub Actions this is the fast gate (~15–25 min for stonking) before a
# multi-hour compile. Locally you need a matching host (or run via workflow_dispatch).
#
# Usage:
#   ./scripts/verify-ci-build-dep.sh stonking     # ubuntu-26.04 → stonking upgrade
#   ./scripts/verify-ci-build-dep.sh resolute     # native on ubuntu-26.04
#   ./scripts/verify-ci-build-dep.sh questing     # noble → questing (ubuntu-24.04)
#
# Env:
#   SKIP_FREE_DISK=1     Skip free-runner-disk (faster, less like production CI)
#   APT_CACHE_DIR        Same as build workflows (optional)
#   DRY_RUN=1            Only apt-get -s build-dep (after prep), no install
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/host-series.sh
source "$REPO_ROOT/scripts/lib/host-series.sh"
# shellcheck source=scripts/lib/series-registry.sh
source "$REPO_ROOT/scripts/lib/series-registry.sh"

SERIES="${1:?series required (stonking, resolute, questing, plucky)}"
series_registered "$SERIES" || {
  echo "error: unknown series=$SERIES" >&2
  exit 1
}

host="$(host_series)"
APT_CACHE_DIR="${APT_CACHE_DIR:-$REPO_ROOT/.ci-cache/apt-${SERIES}}"

runner_series_for() {
  case "$1" in
    stonking | resolute) echo "resolute" ;;
    questing | plucky) echo "noble" ;;
    *) echo "$1" ;;
  esac
}

expected_runner="$(runner_series_for "$SERIES")"
if [[ -n "$host" && "$host" != "$expected_runner" && "$SERIES" != "$host" ]]; then
  echo "error: verify-ci-build-dep for $SERIES expects host $expected_runner (got ${host:-unknown})" >&2
  echo "hint: run on ubuntu-26.04 for stonking/resolute or ubuntu-24.04 for plucky/questing, or use the Verify CI build-dep workflow." >&2
  exit 1
fi

chmod +x \
  "$REPO_ROOT/build.sh" \
  "$REPO_ROOT/.github/scripts/free-runner-disk.sh" \
  "$REPO_ROOT/.github/scripts/upgrade-runner-to-series.sh" \
  "$REPO_ROOT/.github/scripts/setup-ci-build-env.sh" \
  "$REPO_ROOT/.github/scripts/strip-third-party-apt-sources.sh" \
  "$REPO_ROOT/.github/scripts/normalize-runner-apt-sources.sh" \
  "$REPO_ROOT/.github/scripts/align-libx11-for-builddep.sh"

if [[ "${SKIP_FREE_DISK:-}" != "1" ]]; then
  echo "==> free runner disk (set SKIP_FREE_DISK=1 to skip)"
  "$REPO_ROOT/.github/scripts/free-runner-disk.sh"
fi

case "$SERIES" in
  stonking)
    export TARGET_SERIES=stonking BASE_SERIES=resolute
    echo "==> dist-upgrade $BASE_SERIES → $TARGET_SERIES"
    TARGET_SERIES=stonking BASE_SERIES=resolute APT_CACHE_DIR="$APT_CACHE_DIR" \
      "$REPO_ROOT/.github/scripts/upgrade-runner-to-series.sh"
    ;;
  questing | plucky)
    export TARGET_SERIES="$SERIES" BASE_SERIES=noble
    echo "==> dist-upgrade $BASE_SERIES → $TARGET_SERIES"
    TARGET_SERIES="$SERIES" BASE_SERIES=noble APT_CACHE_DIR="$APT_CACHE_DIR" \
      "$REPO_ROOT/.github/scripts/upgrade-runner-to-series.sh"
    ;;
  resolute)
    echo "==> native $SERIES: setup-ci-build-env"
    APT_CACHE_DIR="$APT_CACHE_DIR" "$REPO_ROOT/.github/scripts/setup-ci-build-env.sh"
    ;;
esac

export SERIES APT_CACHE_DIR
export CI_BUILD_LIMITS=1 GITHUB_ACTIONS=1
export DEB_BUILD_OPTIONS="${DEB_BUILD_OPTIONS:-noautodbgsym nodoc nocheck}"

if [[ "${DRY_RUN:-}" == "1" ]]; then
  echo "==> DRY_RUN=1: apt-get -s build-dep webkit2gtk"
  sudo apt-get update -qq
  # shellcheck source=.github/scripts/align-libx11-for-builddep.sh
  source "$REPO_ROOT/.github/scripts/align-libx11-for-builddep.sh"
  align_libx11_for_builddep "$SERIES"
  sudo apt-get -s build-dep -y webkit2gtk
  echo "==> dry-run build-dep OK"
  exit 0
fi

echo "==> build-dep probe via build.sh (CI_BUILD_DEP_PROBE=1)"
CI_BUILD_DEP_PROBE=1 SERIES="$SERIES" APT_CACHE_DIR="$APT_CACHE_DIR" \
  "$REPO_ROOT/build.sh" compile
echo "==> verify-ci-build-dep OK for $SERIES"
