#!/usr/bin/env bash
# Simulate the CI package stage with stub files — no WebKit compile.
#
# What this exercises (same path as CI after a warm compile cache):
#   1. Regenerate debian/*.install manifests (override_dh_auto_configure header, no cmake)
#   2. Populate debian/tmp with empty stubs matching the install manifest
#   3. Run override_dh_auto_install cleanup (locale/header/GIR stripping)
#   4. Optionally dh_install + dh_missing, or full ./build.sh package
#
# Requirements: host series must match SERIES; devscripts, fakeroot, debhelper,
# dpkg-dev, apt deb-src for the series.
#
# Usage:
#   SERIES=resolute ./scripts/simulate-package-stage.sh prepare
#   SERIES=resolute ./scripts/simulate-package-stage.sh dh-check
#   SERIES=resolute ./scripts/simulate-package-stage.sh package   # runs ./build.sh package
#
# prepare  — fetch+patch tree, fake build-gtk4/, STAGE=compiled marker, install manifests
# dh-check — prepare (if needed) + stub debian/tmp + cleanup + dh_install/dh_missing
# package  — prepare + ./build.sh package (needs build-dep; skips ninja via stubs — may
#            still fail if dh_auto_install runs ninja; use dh-check for packaging only)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/host-series.sh
source "$REPO_ROOT/scripts/lib/host-series.sh"
# shellcheck source=scripts/lib/series-registry.sh
source "$REPO_ROOT/scripts/lib/series-registry.sh"
# shellcheck source=scripts/lib/pinned-webkit-version.sh
source "$REPO_ROOT/scripts/lib/pinned-webkit-version.sh"
# shellcheck source=scripts/lib/package-stage-fixture.sh
source "$REPO_ROOT/scripts/lib/package-stage-fixture.sh"

SERIES="${SERIES:-$(host_series)}"
SERIES="${SERIES:-resolute}"
SUFFIX="${SUFFIX:-+webdriver1}"
WORK_DIR="${WORK_DIR:-$REPO_ROOT/work}"
COMPILE_CACHE_KEY_FILE="$REPO_ROOT/.github/compile-cache-key"
PATCH="$(patch_file_for_series "$SERIES")"
CMAKE_PATCH="$REPO_ROOT/patches/webkitgtk-variant-suffix.patch"
MODE="${1:-dh-check}"

usage() {
  cat <<EOF
Usage: ./scripts/simulate-package-stage.sh [MODE]

MODE:
  prepare   Fake compiled tree + install manifests only
  dh-check  prepare + stub debian/tmp + cleanup + dh_install/dh_missing
  package   prepare then ./build.sh package (full debian/rules binary)

Env: SERIES, SUFFIX, WORK_DIR (default ./work)
EOF
}

read_compile_cache_key() {
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    { gsub(/[[:space:]]/, "", $0); key = $0 }
    END { print key }
  ' "$COMPILE_CACHE_KEY_FILE"
}

find_src_dir() {
  find "$WORK_DIR" -maxdepth 1 -type d -name 'webkit2gtk-*' ! -name 'webkit2gtk-*.orig' -print -quit 2>/dev/null || true
}

prepare_fixture_tree() {
  local host pinned compile_key src parent
  host="$(host_series)"
  if [[ -n "$host" && "$SERIES" != "$host" ]]; then
    echo "error: SERIES=$SERIES must match host ($host) for native simulate" >&2
    exit 1
  fi
  if ! command -v fakeroot >/dev/null 2>&1 || ! command -v dh_install >/dev/null 2>&1; then
    echo "error: need devscripts/fakeroot/debhelper (apt install devscripts)" >&2
    exit 1
  fi

  compile_key="$(read_compile_cache_key)"
  src="$(find_src_dir)"
  if [[ -n "$src" && -f "$src/.webkitgtk-automation-prepared" ]]; then
    echo "==> reusing $src"
  else
    echo "==> fetching webkit2gtk source for $SERIES (apt-get source)"
    pinned="$(read_pinned_webkit_version "$SERIES")"
    mkdir -p "$WORK_DIR"
    parent="$(cd "$WORK_DIR" && pwd)"
    sources="$WORK_DIR/simulate-apt-sources.list"
    lists="$WORK_DIR/simulate-apt-lists"
    cache="$WORK_DIR/simulate-apt-cache"
    mkdir -p "$lists/partial" "$cache/archives/partial"
    cat >"$sources" <<SOURCES
deb-src http://archive.ubuntu.com/ubuntu ${SERIES} main universe
deb-src http://archive.ubuntu.com/ubuntu ${SERIES}-updates main universe
deb-src http://archive.ubuntu.com/ubuntu ${SERIES}-security main universe
SOURCES
    apt-get update -qq \
      -o "Dir::Etc::sourcelist=$sources" \
      -o "Dir::Etc::sourceparts=/dev/null" \
      -o "Dir::State::Lists=$lists" \
      -o "Dir::Cache=$cache"
    (
      cd "$parent"
      apt-get source -y \
        -o "Dir::Etc::sourcelist=$sources" \
        -o "Dir::Etc::sourceparts=/dev/null" \
        -o "Dir::State::Lists=$lists" \
        -o "Dir::Cache=$cache" \
        "webkit2gtk=$pinned"
    )
    src="$(find_src_dir)"
    [[ -n "$src" && -d "$src" ]] || { echo "error: no webkit2gtk-* in $WORK_DIR" >&2; exit 1; }
    echo "==> patching $src"
  (
    cd "$src"
    patch -p1 <"$PATCH"
    if patch -p1 --dry-run <"$CMAKE_PATCH" >/dev/null 2>&1; then
      patch -p1 <"$CMAKE_PATCH"
    fi
    if ! grep -q '+webdriver1' debian/changelog 2>/dev/null; then
      base="$(dpkg-parsechangelog -S Version)"
      dch -v "${base}${SUFFIX}" "simulate-package-stage fixture."
      dch -r --distribution "$SERIES" ""
    fi
  )
  fi

  write_fake_build_gtk4 "$src"
  write_compiled_marker "$src" "$SERIES" "$SUFFIX" "$compile_key" "$PATCH" "$CMAKE_PATCH"
  echo "==> regenerating install manifests (no cmake)"
  regenerate_install_manifests "$src"
  echo "==> fixture ready: $src"
  echo "    install manifest: $src/debian/libwebkitgtk-6.0-webdriver4.install"
  wc -l "$src/debian/libwebkitgtk-6.0-webdriver4.install"
}

run_dh_check() {
  local src
  prepare_fixture_tree
  src="$(find_src_dir)"
  echo "==> stubbing debian/tmp from install manifest"
  rm -rf "$src/debian/tmp"
  populate_debian_tmp_stubs "$src"
  echo "==> override_dh_auto_install cleanup (no ninja install)"
  run_override_dh_auto_install_cleanup "$src"
  echo "==> dh_install + dh_missing"
  run_dh_install_and_missing "$src"
  echo "==> dh-check OK"
}

run_package_via_build_sh() {
  prepare_fixture_tree
  local src
  src="$(find_src_dir)"
  populate_debian_tmp_stubs "$src"
  echo "==> ./build.sh package (dpkg-buildpackage -b -nc; may run dh_auto_install/ninja)"
  export SERIES SUFFIX WORK_DIR
  export DEB_BUILD_OPTIONS="${DEB_BUILD_OPTIONS:-noautodbgsym nodoc nocheck}"
  "$REPO_ROOT/build.sh" package
}

case "$MODE" in
  -h|--help) usage; exit 0 ;;
  prepare) prepare_fixture_tree ;;
  dh-check) run_dh_check ;;
  package) run_package_via_build_sh ;;
  *)
    echo "error: unknown mode: $MODE" >&2
    usage >&2
    exit 1
    ;;
esac
