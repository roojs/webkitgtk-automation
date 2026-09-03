#!/usr/bin/env bash
# Fast validation for build.sh helpers, packaging flow, and work-cache — no WebKit compile.
#
# Usage:
#   ./scripts/test-build-scripts.sh           # host / SERIES=resolute
#   SERIES=resolute ./scripts/test-build-scripts.sh
#   PRETEST_FAST=1 ./scripts/test-build-scripts.sh   # CI pretest (no apt/dh slow paths)
#
# Requires: bash, patch, tar, zstd, fakeroot, devscripts (for debian/rules control target).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRETEST_FAST="${PRETEST_FAST:-0}"
COMPILE_CACHE_KEY_FILE="$REPO_ROOT/.github/compile-cache-key"
# Keep in sync with .github/compile-cache-key when bumping the cache version.
EXPECTED_COMPILE_CACHE_KEY="v10"
MARKER_NAME=".webkitgtk-automation-prepared"
# shellcheck source=scripts/lib/debian-tarball.sh
source "$REPO_ROOT/scripts/lib/debian-tarball.sh"
# shellcheck source=scripts/lib/pinned-webkit-version.sh
source "$REPO_ROOT/scripts/lib/pinned-webkit-version.sh"
# shellcheck source=scripts/lib/host-series.sh
source "$REPO_ROOT/scripts/lib/host-series.sh"
# shellcheck source=scripts/lib/series-registry.sh
source "$REPO_ROOT/scripts/lib/series-registry.sh"
# shellcheck source=scripts/lib/packaging-checks.sh
source "$REPO_ROOT/scripts/lib/packaging-checks.sh"
# shellcheck source=scripts/lib/rewrite-webdriver-packaging-metadata.sh
source "$REPO_ROOT/scripts/lib/rewrite-webdriver-packaging-metadata.sh"
# shellcheck source=scripts/lib/webdriver-revision.sh
source "$REPO_ROOT/scripts/lib/webdriver-revision.sh"
# shellcheck source=scripts/lib/gtk4-build-state.sh
source "$REPO_ROOT/scripts/lib/gtk4-build-state.sh"
# shellcheck source=scripts/lib/debian-rules-fixture.sh
source "$REPO_ROOT/scripts/lib/debian-rules-fixture.sh"

SERIES="${SERIES:-$(host_series)}"
SERIES="${SERIES:-resolute}"
LAYOUT="$(series_layout "$SERIES")"
PATCH="$(patch_file_for_series "$SERIES")"

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
    "$REPO_ROOT/scripts/run-pretest.sh" \
    "$REPO_ROOT/scripts/upstream-webkit-version.sh" \
    "$REPO_ROOT/scripts/monitor-upstream-build.sh" \
    "$REPO_ROOT/scripts/lib/debian-tarball.sh" \
    "$REPO_ROOT/scripts/lib/pinned-webkit-version.sh" \
    "$REPO_ROOT/scripts/lib/host-series.sh" \
    "$REPO_ROOT/scripts/lib/series-registry.sh" \
    "$REPO_ROOT/scripts/lib/packaging-checks.sh" \
    "$REPO_ROOT/scripts/lib/gtk4-build-state.sh" \
    "$REPO_ROOT/scripts/lib/archive-apt.sh" \
    "$REPO_ROOT/scripts/lib/package-stage-fixture.sh" \
    "$REPO_ROOT/scripts/lib/package-stage-dump.sh" \
    "$REPO_ROOT/scripts/simulate-package-stage.sh" \
    "$REPO_ROOT/scripts/lib/patch-for-series.sh" \
    "$REPO_ROOT/scripts/test-build-scripts.sh" \
    "$REPO_ROOT/.github/scripts/work-cache.sh" \
    "$REPO_ROOT/.github/scripts/free-runner-disk.sh" \
    "$REPO_ROOT/.github/scripts/setup-ci-build-env.sh" \
    "$REPO_ROOT/.github/scripts/upgrade-runner-to-series.sh" \
    "$REPO_ROOT/.github/scripts/strip-third-party-apt-sources.sh" \
    "$REPO_ROOT/.github/scripts/normalize-runner-apt-sources.sh" \
    "$REPO_ROOT/.github/scripts/record-successful-build.sh"
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
    [[ "$key" == "$EXPECTED_COMPILE_CACHE_KEY" ]] || exit 1
  ) || fail "expected compile cache key $EXPECTED_COMPILE_CACHE_KEY under pipefail"
  pass "key=$EXPECTED_COMPILE_CACHE_KEY"

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
SERIES=resolute
SUFFIX=+webkitgtk1
COMPILE_CACHE_KEY=$EXPECTED_COMPILE_CACHE_KEY
PATCH_SHA256=abc
EOF
  marker_matches "$marker" resolute '+webkitgtk1' "$EXPECTED_COMPILE_CACHE_KEY" || fail "new marker should match"
  marker_matches "$marker" resolute '+webkitgtk1' v5 && fail "wrong compile key should not match"
  pass "new marker"

  cat >"$marker" <<EOF
SERIES=resolute
SUFFIX=+webkitgtk1
PATCH_SHA256=abc
EOF
  marker_matches "$marker" resolute '+webkitgtk1' "$EXPECTED_COMPILE_CACHE_KEY" || fail "legacy marker should match"
  pass "legacy marker"
  trap - RETURN
}

fetch_debian_tree() {
  local dest="$1"
  local src="$dest/src"
  mkdir -p "$src/debian"

  if debian_rules_fixture_ready "$SERIES" "$(read_pinned_webkit_version "$SERIES")"; then
    local pinned deb_tar
    pinned="$(read_pinned_webkit_version "$SERIES")"
    copy_debian_fixture "$SERIES" "$src"
    deb_tar="$dest/webkit2gtk_${pinned}.debian.tar.xz"
    tar -cJf "$deb_tar" -C "$src" debian
    pass "debian/ from local fixture"
    printf '%s\n' "$deb_tar"
    return 0
  fi

  local pinned deb_tar
  local sources lists cache
  pinned="$(read_pinned_webkit_version "$SERIES")"
  sources="$dest/apt-sources.list"
  lists="$dest/apt-lists"
  cache="$dest/apt-cache"
  mkdir -p "$lists/partial" "$cache/archives/partial"

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
        "webkit2gtk=$pinned"
    )
  } >&2

  deb_tar="$(find "$dest" -maxdepth 1 -type f \( -name '*debian.tar.*' -o -name '*.debian.tar.*' \) -print -quit)"
  [[ -n "$deb_tar" ]] || fail "no debian tarball after apt-get source -d"

  tar -xf "$deb_tar" -C "$src" debian/rules
  printf '%s\n' "$deb_tar"
}

install_test_deps() {
  command -v dh_listpackages >/dev/null 2>&1 \
    && command -v dh_install >/dev/null 2>&1 \
    && command -v dpkg-deb >/dev/null 2>&1 \
    && command -v fakeroot >/dev/null 2>&1 \
    && command -v zstd >/dev/null 2>&1 && return 0
  echo "==> installing test deps (devscripts, debhelper, fakeroot, dpkg-dev, zstd)"
  if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    devscripts debhelper fakeroot dpkg-dev zstd >/dev/null 2>&1; then
    echo "  warn: could not install test deps now (apt busy?); continuing with what is installed" >&2
  fi
}

test_packaging_flow() {
  echo "==> packaging flow (patch, control regen, gtk4-only, layout=$LAYOUT)"
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
  assert_patched_rules_markers "$src/debian/rules" "$LAYOUT"

  (
    cd "$src"
    rm -f debian/control
    fakeroot debian/rules debian/control >/dev/null
    rewrite_webdriver_packaging_metadata .
  )
  assert_patched_control_gtk4_only "$src/debian/control" "$LAYOUT"
  assert_webdriver_packaging_metadata "$src/debian/control"
  pass "debian/control gtk4-only"

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

  pinned="$(read_pinned_webkit_version "$SERIES")"
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
    webkit2gtk=$pinned"

  echo "# stale" >>"$src/debian/rules"
  refresh_debian_rules_from_patch "$src" "$PATCH" || fail "refresh without cached tarball failed"
  [[ -n "$(find_debian_tarball "$work_root")" ]] || fail "debian tarball should be downloaded into work/"
  [[ "$(sha256sum "$src/debian/rules" | awk '{print $1}')" == "$patched_hash" ]] \
    || fail "rules refresh without cached tarball did not reproduce patched debian/rules"
  pass "download debian tarball on demand + refresh rules"
  trap - RETURN
}

test_marker_stage_compiled() {
  echo "==> marker STAGE=compiled + build-gtk4 completeness"
  local tmp src marker
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/webkitgtk-stage.XXXXXX")"
  src="$tmp/webkit2gtk-2.52.3"
  marker="$src/$MARKER_NAME"
  trap 'rm -rf "$tmp"' RETURN

  marker_stage_from_file() {
    awk -F= '/^STAGE=/ { print $2; exit }' "$1"
  }

  mkdir -p "$src/build-gtk4/CMakeFiles"
  echo 'CMAKE_GENERATOR:INTERNAL=Ninja' >"$src/build-gtk4/CMakeCache.txt"
  touch "$src/build-gtk4/build.ninja" "$src/build-gtk4/CMakeFiles/VerifyGlobs.cmake"

  gtk4_build_tree_looks_complete "$src" || fail "complete gtk4 tree fixture"
  pass "gtk4_build_tree_looks_complete"

  cat >"$marker" <<EOF
SERIES=resolute
SUFFIX=+webkitgtk1
COMPILE_CACHE_KEY=$EXPECTED_COMPILE_CACHE_KEY
STAGE=compiled
PATCH_SHA256=dummy
EOF
  [[ "$(marker_stage_from_file "$marker")" == "compiled" ]] || fail "STAGE=compiled not read"
  pass "STAGE=compiled marker"

  rm -f "$src/build-gtk4/build.ninja"
  gtk4_build_tree_looks_complete "$src" && fail "incomplete tree should not look complete"
  pass "incomplete tree rejected"
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

  mkdir -p "$src/build-gtk4/CMakeFiles" "$cache_root"
  echo 'ninja marker' >"$src/build-gtk4/.ninja_log"
  echo 'CMAKE_GENERATOR:INTERNAL=Ninja' >"$src/build-gtk4/CMakeCache.txt"
  touch "$src/build-gtk4/build.ninja" "$src/build-gtk4/CMakeFiles/VerifyGlobs.cmake"
  cat >"$src/$MARKER_NAME" <<EOF
SERIES=resolute
SUFFIX=+webkitgtk1
COMPILE_CACHE_KEY=$EXPECTED_COMPILE_CACHE_KEY
STAGE=compiled
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

test_work_cache_refuses_corrupt_tree() {
  echo "==> work-cache refuses non-resumable build-gtk4"
  local tmp work_root cache_root src archive
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/webkitgtk-workcache-corrupt.XXXXXX")"
  work_root="$tmp/work"
  cache_root="$tmp/ci-cache/work"
  archive="$cache_root/work-incremental.tar.zst"
  src="$work_root/webkit2gtk-2.52.3"
  trap 'rm -rf "$tmp"' RETURN

  mkdir -p "$src/build-gtk4" "$cache_root"
  cat >"$src/$MARKER_NAME" <<EOF
SERIES=resolute
SUFFIX=+webkitgtk1
COMPILE_CACHE_KEY=$EXPECTED_COMPILE_CACHE_KEY
STAGE=compiled
PATCH_SHA256=dummy
EOF

  WORK_DIR="$work_root" WORK_CACHE_DIR="$cache_root" \
    "$REPO_ROOT/.github/scripts/work-cache.sh" pack
  [[ ! -f "$archive" ]] || fail "corrupt build-gtk4 should not be packed"
  pass "skipped pack for corrupt tree"
  trap - RETURN
}

test_webdriver_package_revision() {
  echo "==> webdriver package revision (+webdriverN)"
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp" <<'EOF'
plucky=1
questing=1
resolute=1
EOF
  local next
  next="$(WEBDRIVER_REVISION_FILE="$tmp" next_webdriver_suffix questing)"
  [[ "$next" == "+webdriver2" ]] || fail "expected +webdriver2 from revision=1, got $next"
  WEBDRIVER_REVISION_FILE="$tmp" record_webdriver_revision questing "$next"
  next="$(WEBDRIVER_REVISION_FILE="$tmp" next_webdriver_suffix questing)"
  [[ "$next" == "+webdriver3" ]] || fail "expected +webdriver3 after record, got $next"
  rm -f "$tmp"
  pass "package revision increments per series"
}

test_debian_fixture_ready() {
  echo "==> debian fixture completeness"
  if ! debian_rules_fixture_ready "$SERIES" "$(read_pinned_webkit_version "$SERIES")"; then
    fail "incomplete debian fixture for $SERIES (need full debian/ from debian.tar; run ./scripts/fetch-fixtures.sh $SERIES)"
  fi
  pass "debian fixture has packaging inputs"
}

test_pinned_webkit_version() {
  echo "==> pinned webkit2gtk version"
  local pinned
  pinned="$(read_pinned_webkit_version "$SERIES")"
  [[ "$pinned" =~ ^2\. ]] || fail "unexpected pinned version: $pinned"
  pass "$SERIES=$pinned"
}

test_upstream_version_probe() {
  echo "==> upstream webkit2gtk version probe"
  local ver
  ver="$("$REPO_ROOT/scripts/upstream-webkit-version.sh" "$SERIES")"
  [[ "$ver" =~ ^[0-9] ]] || fail "unexpected upstream version: $ver"
  pass "archive version $ver"
}

test_simulate_package_stage_dh_check() {
  echo "==> simulate-package-stage dh-check (stock Ubuntu .debs + dh_install + dh_shlibdeps)"
  install_test_deps
  if ! command -v dh_install >/dev/null 2>&1 || ! command -v fakeroot >/dev/null 2>&1; then
    fail "simulate dh-check needs debhelper and fakeroot (apt install debhelper fakeroot)"
  fi
  local tmp host
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/webkitgtk-simulate.XXXXXX")"
  trap 'rm -rf "$tmp"' RETURN
  host="$(host_series)"
  if [[ -n "$host" && "$SERIES" != "$host" ]]; then
    SIMULATE_ALLOW_CROSS_SERIES=1 WORK_DIR="$tmp/work" SERIES="$SERIES" \
      "$REPO_ROOT/scripts/simulate-package-stage.sh" dh-check
  else
    WORK_DIR="$tmp/work" SERIES="$SERIES" \
      "$REPO_ROOT/scripts/simulate-package-stage.sh" dh-check
  fi
  pass "simulate dh-check"
  trap - RETURN
}

skip_slow() {
  echo "  skip: $1 (set PRETEST_FAST=0 to run)"
}

main() {
  echo "==> test-build-scripts series=$SERIES layout=$LAYOUT pretest_fast=$PRETEST_FAST"
  [[ -f "$PATCH" ]] || fail "missing $PATCH"
  [[ -f "$COMPILE_CACHE_KEY_FILE" ]] || fail "missing $COMPILE_CACHE_KEY_FILE"

  install_test_deps
  test_shell_syntax
  test_compile_cache_key_pipefail
  test_marker_matching
  test_marker_stage_compiled
  test_webdriver_package_revision
  test_debian_fixture_ready
  test_pinned_webkit_version
  test_packaging_flow
  test_work_cache_roundtrip
  test_work_cache_refuses_corrupt_tree
  if [[ "$PRETEST_FAST" == "1" ]]; then
    skip_slow "upstream webkit2gtk version probe"
    skip_slow "rules refresh without cached debian tarball"
    skip_slow "simulate-package-stage dh-check"
  else
    test_upstream_version_probe
    test_rules_refresh_without_cached_tarball
    test_simulate_package_stage_dh_check
  fi

  echo "==> pretest-patch.sh (patch apply + markers)"
  "$REPO_ROOT/scripts/pretest-patch.sh" "$SERIES"

  echo "==> pretest-webkit-patches.sh"
  chmod +x "$REPO_ROOT/scripts/pretest-webkit-patches.sh"
  "$REPO_ROOT/scripts/pretest-webkit-patches.sh" "$SERIES"

  echo "==> all tests passed"
}

main "$@"
