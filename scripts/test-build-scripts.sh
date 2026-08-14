#!/usr/bin/env bash
# Fast validation for build.sh helpers, packaging flow, and work-cache — no WebKit compile.
#
# Usage:
#   ./scripts/test-build-scripts.sh           # host / SERIES=noble
#   SERIES=noble ./scripts/test-build-scripts.sh
#
# Requires: bash, patch, tar, zstd, fakeroot, devscripts (for debian/rules control target).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH="$REPO_ROOT/patches/enable-webdriver-gtk4.patch"
COMPILE_CACHE_KEY_FILE="$REPO_ROOT/.github/compile-cache-key"
MARKER_NAME=".webkitgtk-automation-prepared"
# shellcheck source=scripts/lib/debian-tarball.sh
source "$REPO_ROOT/scripts/lib/debian-tarball.sh"

host_series() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "${VERSION_CODENAME:-}"
  fi
}

SERIES="${SERIES:-$(host_series)}"
SERIES="${SERIES:-noble}"

pass() { echo "  ok: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

read_compile_cache_key() {
  local file="$1" key
  key="$(
    awk '
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*$/ { next }
      { gsub(/[[:space:]]/, "", $0); key = $0 }
      END { print key }
    ' "$file"
  )"
  if [[ -z "$key" ]]; then
    fail "no version line in $file"
  fi
  echo "$key"
}

test_shell_syntax() {
  echo "==> shell syntax"
  local f
  for f in \
    "$REPO_ROOT/build.sh" \
    "$REPO_ROOT/scripts/pretest-patch.sh" \
    "$REPO_ROOT/scripts/lib/debian-tarball.sh" \
    "$REPO_ROOT/scripts/test-build-scripts.sh" \
    "$REPO_ROOT/.github/scripts/work-cache.sh" \
    "$REPO_ROOT/.github/scripts/free-runner-disk.sh" \
    "$REPO_ROOT/.github/scripts/prepare-ci-runner.sh"
  do
    bash -n "$f" || fail "bash -n $f"
    pass "$(basename "$f")"
  done
}

test_compile_cache_key_pipefail() {
  echo "==> compile-cache-key parsing (set -o pipefail)"
  local key
  (
    set -euo pipefail
    key="$(read_compile_cache_key "$COMPILE_CACHE_KEY_FILE")"
    [[ "$key" == "v1" ]] || exit 1
  ) || fail "expected compile cache key v1 under pipefail"
  pass "key=v1"

  echo "==> compile-cache-key regression (broken tr|grep pipeline must fail)"
  if (
    set -euo pipefail
    # Old bug: tr joins comment + version into one # line; grep exits 1 → silent build.sh death.
    read_compile_cache_key_broken() {
      tr -d '[:space:]' < "$COMPILE_CACHE_KEY_FILE" | grep -v '^#' | tail -n 1
    }
    [[ -n "$(read_compile_cache_key_broken)" ]]
  ); then
    fail "broken tr|grep pipeline should not yield a key"
  else
    pass "broken pipeline fails as expected"
  fi
}

test_marker_matching() {
  echo "==> work-tree marker matching"
  local tmp marker
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/webkitgtk-marker.XXXXXX")"
  marker="$tmp/$MARKER_NAME"
  trap 'rm -rf "$tmp"' RETURN

  marker_matches() {
    local marker_file="$1" series="$2" suffix="$3" compile_key="$4"
    grep -qx "SERIES=$series" "$marker_file" || return 1
    grep -qx "SUFFIX=$suffix" "$marker_file" || return 1
    if grep -qx "COMPILE_CACHE_KEY=$compile_key" "$marker_file"; then
      return 0
    fi
    if ! grep -q '^COMPILE_CACHE_KEY=' "$marker_file"; then
      return 0
    fi
    return 1
  }

  cat >"$marker" <<EOF
SERIES=noble
SUFFIX=+webkitgtk1
COMPILE_CACHE_KEY=v1
PATCH_SHA256=abc
EOF
  marker_matches "$marker" noble '+webkitgtk1' v1 || fail "new marker should match"
  marker_matches "$marker" noble '+webkitgtk1' v2 && fail "wrong compile key should not match"
  pass "new marker"

  cat >"$marker" <<EOF
SERIES=noble
SUFFIX=+webkitgtk1
PATCH_SHA256=abc
EOF
  marker_matches "$marker" noble '+webkitgtk1' v1 || fail "legacy marker should match"
  pass "legacy marker"
  trap - RETURN
}

fetch_debian_tree() {
  local dest="$1"
  local sources lists cache deb_tar
  sources="$dest/apt-sources.list"
  lists="$dest/apt-lists"
  cache="$dest/apt-cache"
  mkdir -p "$lists/partial" "$cache/archives/partial" "$dest/src"

  cat >"$sources" <<SOURCES
deb-src http://archive.ubuntu.com/ubuntu ${SERIES} main universe
deb-src http://archive.ubuntu.com/ubuntu ${SERIES}-updates main universe
deb-src http://archive.ubuntu.com/ubuntu ${SERIES}-security main universe
SOURCES

  {
    apt-get update -qq \
      -o "Dir::Etc::sourcelist=$sources" \
      -o "Dir::Etc::sourceparts=/dev/null" \
      -o "Dir::State::Lists=$lists" \
      -o "Dir::Cache=$cache"

    (
      cd "$dest"
      apt-get source -d -y \
        -o "Dir::Etc::sourcelist=$sources" \
        -o "Dir::Etc::sourceparts=/dev/null" \
        -o "Dir::State::Lists=$lists" \
        -o "Dir::Cache=$cache" \
        webkit2gtk
    )
  } >&2

  deb_tar="$(find "$dest" -maxdepth 1 -type f \( -name '*debian.tar.*' -o -name '*.debian.tar.*' \) -print -quit)"
  [[ -n "$deb_tar" ]] || fail "no debian tarball after apt-get source -d"

  tar -xf "$deb_tar" -C "$dest/src"
  printf '%s\n' "$deb_tar"
}

install_test_deps() {
  command -v dh_listpackages >/dev/null 2>&1 && command -v zstd >/dev/null 2>&1 && return 0
  echo "==> installing test deps (devscripts, zstd)"
  if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq devscripts zstd >/dev/null 2>&1; then
    echo "  warn: could not install devscripts/zstd now (apt busy?); continuing with what is installed" >&2
  fi
}

test_packaging_flow() {
  echo "==> packaging flow (patch, control regen, gtk4-only)"
  local tmp src deb_tar patched_hash restored_hash
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/webkitgtk-packaging.XXXXXX")"
  src="$tmp/src"
  trap 'rm -rf "$tmp"' RETURN

  deb_tar="$(fetch_debian_tree "$tmp")"
  pass "fetched $(basename "$deb_tar")"

  (
    cd "$src"
    patch -p1 < "$PATCH"
  )
  pass "patch applies"

  patched_hash="$(sha256sum "$src/debian/rules" | awk '{print $1}')"

  (
    cd "$src"
    rm -f debian/control
    fakeroot debian/rules debian/control >/dev/null
  )
  [[ -f "$src/debian/control" ]] || fail "debian/control not generated"
  grep -q '^Package: libwebkitgtk-6.0-4$' "$src/debian/control" || fail "gtk4 runtime package missing from control"
  if grep -q '^Package: libwebkit2gtk-4.1' "$src/debian/control"; then
    fail "soup3 binary packages should be absent from regenerated control"
  fi
  pass "debian/control gtk4-only"

  # gtk4-only control must not use -N for soup3 packages that are not listed.
  if grep -q -- '-Nlibwebkit2gtk-4.1-0' "$src/debian/rules"; then
    fail "patched debian/rules must not -N soup3 packages when ENABLE_SOUP3=NO"
  fi
  pass "no invalid soup3 -N skip flags"

  # Simulate refresh_debian_rules_from_patch (build.sh resume path).
  echo "# stale" >>"$src/debian/rules"
  refresh_debian_rules_from_patch "$src" "$PATCH" || fail "rules refresh failed"
  restored_hash="$(sha256sum "$src/debian/rules" | awk '{print $1}')"
  [[ "$restored_hash" == "$patched_hash" ]] || fail "rules refresh did not reproduce patched debian/rules"
  pass "debian/rules refresh from tarball"
  trap - RETURN
}

test_rules_refresh_without_cached_tarball() {
  echo "==> rules refresh after work-cache unpack (no debian tarball in work/)"
  local tmp staging work_root src deb_tar patched_hash apt_sources apt_lists apt_cache
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/webkitgtk-resume.XXXXXX")"
  staging="$tmp/staging"
  work_root="$tmp/work"
  src="$work_root/webkit2gtk-2.52.3"
  trap 'rm -rf "$tmp"' RETURN

  deb_tar="$(fetch_debian_tree "$staging")"
  mkdir -p "$work_root"
  cp -a "$staging/src" "$src"
  (
    cd "$src"
    patch -p1 <"$PATCH"
  )
  patched_hash="$(sha256sum "$src/debian/rules" | awk '{print $1}')"

  # work-cache.sh only packs webkit2gtk-*; tarball must not sit beside it.
  find "$work_root" -maxdepth 1 -type f \( -name '*debian.tar.*' -o -name '*.debian.tar.*' \) -delete
  [[ -z "$(find_debian_tarball "$work_root")" ]] || fail "work dir should have no debian tarball"

  apt_sources="$tmp/apt-sources.list"
  apt_lists="$tmp/apt-lists"
  apt_cache="$tmp/apt-cache"
  mkdir -p "$apt_lists/partial" "$apt_cache/archives/partial"
  cat >"$apt_sources" <<SOURCES
deb-src http://archive.ubuntu.com/ubuntu ${SERIES} main universe
deb-src http://archive.ubuntu.com/ubuntu ${SERIES}-updates main universe
deb-src http://archive.ubuntu.com/ubuntu ${SERIES}-security main universe
SOURCES

  DOWNLOAD_WEBKIT2GTK_SOURCE_CMD="apt-get update -qq \
    -o Dir::Etc::sourcelist=$apt_sources \
    -o Dir::Etc::sourceparts=/dev/null \
    -o Dir::State::Lists=$apt_lists \
    -o Dir::Cache=$apt_cache && \
    apt-get source -d -y \
    -o Dir::Etc::sourcelist=$apt_sources \
    -o Dir::Etc::sourceparts=/dev/null \
    -o Dir::State::Lists=$apt_lists \
    -o Dir::Cache=$apt_cache \
    webkit2gtk"

  echo "# stale" >>"$src/debian/rules"
  refresh_debian_rules_from_patch "$src" "$PATCH" || fail "refresh without cached tarball failed"
  [[ -n "$(find_debian_tarball "$work_root")" ]] || fail "debian tarball should be downloaded into work/"
  [[ "$(sha256sum "$src/debian/rules" | awk '{print $1}')" == "$patched_hash" ]] \
    || fail "rules refresh without cached tarball did not reproduce patched debian/rules"
  pass "download debian tarball on demand + refresh rules"
  trap - RETURN
}

test_work_cache_roundtrip() {
  echo "==> work-cache pack/unpack"
  local tmp work_root cache_root src
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/webkitgtk-workcache.XXXXXX")"
  work_root="$tmp/work"
  cache_root="$tmp/ci-cache/work"
  src="$work_root/webkit2gtk-2.52.3"
  trap 'rm -rf "$tmp"' RETURN

  if ! command -v zstd >/dev/null 2>&1; then
    install_test_deps
  fi

  mkdir -p "$src/build-gtk4" "$cache_root"
  echo "ninja marker" >"$src/build-gtk4/.ninja_log"
  cat >"$src/$MARKER_NAME" <<EOF
SERIES=noble
SUFFIX=+webkitgtk1
COMPILE_CACHE_KEY=v1
PATCH_SHA256=dummy
EOF

  WORK_DIR="$work_root" WORK_CACHE_DIR="$cache_root" \
    "$REPO_ROOT/.github/scripts/work-cache.sh" pack

  rm -rf "$work_root"
  mkdir -p "$work_root"

  WORK_DIR="$work_root" WORK_CACHE_DIR="$cache_root" \
    "$REPO_ROOT/.github/scripts/work-cache.sh" unpack

  [[ -f "$src/$MARKER_NAME" ]] || fail "marker missing after unpack"
  [[ -f "$src/build-gtk4/.ninja_log" ]] || fail "build-gtk4 missing after unpack"
  pass "roundtrip preserved marker and build-gtk4/"
  trap - RETURN
}

main() {
  echo "==> test-build-scripts series=$SERIES"
  [[ -f "$PATCH" ]] || fail "missing $PATCH"
  [[ -f "$COMPILE_CACHE_KEY_FILE" ]] || fail "missing $COMPILE_CACHE_KEY_FILE"

  install_test_deps
  test_shell_syntax
  test_compile_cache_key_pipefail
  test_marker_matching
  test_packaging_flow
  test_rules_refresh_without_cached_tarball
  test_work_cache_roundtrip

  echo "==> pretest-patch.sh (patch apply + markers)"
  "$REPO_ROOT/scripts/pretest-patch.sh" "$SERIES"

  echo "==> all tests passed"
}

main "$@"
