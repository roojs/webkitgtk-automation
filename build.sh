#!/usr/bin/env bash
# Rebuild Ubuntu libwebkitgtk-6.0-webdriver (WebKit #318171 + #165269).
#
# Resume / caching:
#   - Reuses work/<tree> when already prepared (skip fetch/patch).
#   - Uses dpkg-buildpackage -nc so ninja/cmake object dirs survive interrupts.
#   - Keeps a persistent ccache under cache/ccache (survives debian/rules clean).
#   - CLEAN=1 wipes the work tree; CLEAN_CACHE=1 also wipes ccache.
#
# Apt archive cache (CI):
#   - Set APT_CACHE_DIR to a workspace path (e.g. .ci-cache/apt).
#   - All apt-get install/upgrade/build-dep calls use Dir::Cache::archives there.
#
# CI resource knobs (defaults are CI-friendly):
#   - DEB_BUILD_OPTIONS includes noautodbgsym (no huge .ddeb packages)
#   - Patch uses -g0; gold linker (-fuse-ld=gold) via binutils-gold; strips BFD-only --reduce-memory-overheads
#   - GTK4-only build (gtk3 skipped); system webkitgtk-webdriver is kept
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/host-series.sh
source "$REPO_ROOT/scripts/lib/host-series.sh"
# shellcheck source=scripts/lib/series-registry.sh
source "$REPO_ROOT/scripts/lib/series-registry.sh"
# shellcheck source=scripts/lib/rewrite-webdriver-packaging-metadata.sh
source "$REPO_ROOT/scripts/lib/rewrite-webdriver-packaging-metadata.sh"
# shellcheck source=scripts/lib/webdriver-revision.sh
source "$REPO_ROOT/scripts/lib/webdriver-revision.sh"

HOST_SERIES="$(host_series)"
DEFAULT_SERIES="$HOST_SERIES"
if [[ -z "$DEFAULT_SERIES" ]] || ! series_registered "$DEFAULT_SERIES"; then
  DEFAULT_SERIES="resolute"
fi

STAGE_MODE="all"
if [[ "${1:-}" == "compile" || "${1:-}" == "package" ]]; then
  STAGE_MODE="$1"
  shift
fi

SERIES="${SERIES:-${1:-$DEFAULT_SERIES}}"
if [[ -n "${2:-}" ]]; then
  SUFFIX="$2"
elif [[ -z "${SUFFIX:-}" ]]; then
  SUFFIX="$(next_webdriver_suffix "$SERIES")"
fi
SUFFIX="${SUFFIX:-+webdriver1}"
PATCH="$(patch_file_for_series "$SERIES")"
CMAKE_PATCH="$REPO_ROOT/patches/webkitgtk-variant-suffix.patch"
WEBKIT_INTERACTIONS_PATCH="$REPO_ROOT/patches/webkit-318171-webdriver-interactions.patch"
WEBKIT_POLICY_PATCH="$(webkit_policy_patch_for_series "$SERIES")"
COMPILE_CACHE_KEY_FILE="$REPO_ROOT/.github/compile-cache-key"
# shellcheck source=scripts/lib/debian-tarball.sh
source "$REPO_ROOT/scripts/lib/debian-tarball.sh"
# shellcheck source=scripts/lib/pinned-webkit-version.sh
source "$REPO_ROOT/scripts/lib/pinned-webkit-version.sh"
# shellcheck source=scripts/lib/gtk4-build-state.sh
source "$REPO_ROOT/scripts/lib/gtk4-build-state.sh"
WORK_DIR="${WORK_DIR:-$REPO_ROOT/work}"
DIST_DIR="$REPO_ROOT/dist"
CACHE_DIR="${CACHE_DIR:-$REPO_ROOT/cache}"
CCACHE_DIR="${CCACHE_DIR:-$CACHE_DIR/ccache}"
CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-8G}"
# Workspace apt .deb archive cache (OLLMchat-style). Empty = system default.
APT_CACHE_DIR="${APT_CACHE_DIR:-}"
APT_UPGRADE="${APT_UPGRADE:-0}"
CLEAN="${CLEAN:-0}"
CLEAN_CACHE="${CLEAN_CACHE:-0}"
MARKER_NAME=".webkitgtk-automation-prepared"
# noautodbgsym: do not build separate debug-symbol packages (disk + time).
# nodoc/nocheck: skip docs and tests.
: "${DEB_BUILD_OPTIONS:=noautodbgsym nodoc nocheck}"
# Cap ninja parallelism on hosted CI to reduce OOM risk (override with BUILD_PARALLEL_JOBS).
BUILD_PARALLEL_JOBS="${BUILD_PARALLEL_JOBS:-}"
QUIET_BUILD="${QUIET_BUILD:-0}"

usage() {
  cat <<'EOF'
Usage: ./build.sh [STAGE] [SERIES] [SUFFIX]

STAGE:
  all       compile then package (default)
  compile   prepare source tree and run debian/rules build (gtk4 only)
  package   skip compile when STAGE=compiled; run dpkg-buildpackage

Env:
  SERIES              Ubuntu series (default: host VERSION_CODENAME, else resolute)
  SUFFIX              Debian package suffix (default: next +webdriverN from .github/webdriver-revision)
  WORK_DIR            Unpacked source + object dirs (default: ./work)
  CACHE_DIR           Persistent caches (default: ./cache)
  CCACHE_DIR          ccache directory (default: ./cache/ccache)
  CCACHE_MAXSIZE      ccache -M size (default: 8G)
  APT_CACHE_DIR       Workspace dir for apt .deb archives (CI cache)
  APT_UPGRADE=1       Run apt-get upgrade before installing build deps
  CLEAN=1             Wipe WORK_DIR and start fresh (keeps ccache)
  CLEAN_CACHE=1       Also wipe CCACHE_DIR
  DEB_BUILD_OPTIONS   Default: "noautodbgsym nodoc nocheck"
  BUILD_PARALLEL_JOBS Cap ninja/cmake jobs (auto 2 on GitHub Actions)
  QUIET_BUILD=1       Filter verbose compile lines (auto on GitHub Actions)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ ! -f "$PATCH" ]]; then
  echo "error: missing patch: $PATCH" >&2
  exit 1
fi

if [[ ! -f "$WEBKIT_INTERACTIONS_PATCH" || ! -f "$WEBKIT_POLICY_PATCH" ]]; then
  echo "error: missing WebKit source patch" >&2
  exit 1
fi

if [[ ! -f "$CMAKE_PATCH" ]]; then
  echo "error: missing cmake patch: $CMAKE_PATCH" >&2
  exit 1
fi

if [[ ! -f "$COMPILE_CACHE_KEY_FILE" ]]; then
  echo "error: missing compile cache key: $COMPILE_CACHE_KEY_FILE" >&2
  exit 1
fi

COMPILE_CACHE_KEY="$(
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    { gsub(/[[:space:]]/, "", $0); key = $0 }
    END { print key }
  ' "$COMPILE_CACHE_KEY_FILE"
)"
if [[ -z "$COMPILE_CACHE_KEY" ]]; then
  echo "error: $COMPILE_CACHE_KEY_FILE has no version line" >&2
  exit 1
fi

if [[ -n "$HOST_SERIES" && "$SERIES" != "$HOST_SERIES" ]]; then
  echo "error: SERIES=$SERIES does not match host Ubuntu series ($HOST_SERIES)." >&2
  echo "       Native builds must use the runner/host release (no Docker/chroot)." >&2
  exit 1
fi

if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=()
else
  SUDO=(sudo)
fi

export DEBIAN_FRONTEND=noninteractive

# devscripts/pbuilder postinst prompts for a mirror in non-interactive CI/shells.
preseed_pbuilder_mirror() {
  local mirror="${PBUILDER_MIRROR:-http://archive.ubuntu.com/ubuntu}"
  if command -v debconf-set-selections >/dev/null 2>&1; then
    echo "pbuilder pbuilder/default_mirror string $mirror" | "${SUDO[@]}" debconf-set-selections
    echo "pbuilder pbuilder/override_mirror boolean false" | "${SUDO[@]}" debconf-set-selections
  fi
}

export DEBEMAIL="${DEBEMAIL:-alan@roojs.com}"
export DEBFULLNAME="${DEBFULLNAME:-Alan Knowles}"
export CCACHE_DIR
export CCACHE_NOHASHDIR=1
export DEB_BUILD_OPTIONS

APT_ARCHIVE_OPTS=()
if [[ -n "$APT_CACHE_DIR" ]]; then
  mkdir -p "$APT_CACHE_DIR/partial"
  APT_CACHE_DIR="$(cd "$APT_CACHE_DIR" && pwd)"
  APT_ARCHIVE_OPTS=(-o "Dir::Cache::archives=$APT_CACHE_DIR")
fi

prepare_apt_cache() {
  [[ -n "$APT_CACHE_DIR" ]] || return 0
  mkdir -p "$APT_CACHE_DIR/partial"
  APT_CACHE_DIR="$(cd "$APT_CACHE_DIR" && pwd)"
  APT_ARCHIVE_OPTS=(-o "Dir::Cache::archives=$APT_CACHE_DIR")
  if [[ "$(id -u)" -ne 0 ]]; then
    "${SUDO[@]}" chown -R _apt:root "$APT_CACHE_DIR"
    "${SUDO[@]}" chmod -R u+rwX,g+rwX "$APT_CACHE_DIR"
  fi
}

chown_tree_to_builder() {
  local dir="$1"
  if [[ "$(id -u)" -ne 0 ]]; then
    "${SUDO[@]}" chown -R "$(id -u):$(id -g)" "$dir"
  fi
}

apt_get() {
  prepare_apt_cache
  "${SUDO[@]}" apt-get "${APT_ARCHIVE_OPTS[@]}" "$@"
}

finalize_apt_cache() {
  [[ -n "$APT_CACHE_DIR" ]] || return 0
  "${SUDO[@]}" rm -rf "$APT_CACHE_DIR/partial" "$APT_CACHE_DIR/lock"
  if [[ "$(id -u)" -ne 0 ]]; then
    "${SUDO[@]}" chown -R "$(id -u):$(id -g)" "$APT_CACHE_DIR"
  fi
}

apply_ci_build_limits() {
  if [[ -z "${GITHUB_ACTIONS:-}${CI_BUILD_LIMITS:-}" ]]; then
    return 0
  fi
  local jobs="${BUILD_PARALLEL_JOBS:-2}"
  export CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$jobs}"
  export NINJA_STATUS="[%f/%t] "
  if [[ " $DEB_BUILD_OPTIONS " != *" parallel="* ]]; then
    DEB_BUILD_OPTIONS+=" parallel=$jobs"
    export DEB_BUILD_OPTIONS
  fi
  QUIET_BUILD="${QUIET_BUILD:-1}"
  echo "==> CI runner limits: jobs=$jobs CMAKE_BUILD_PARALLEL_LEVEL=$CMAKE_BUILD_PARALLEL_LEVEL DEB_BUILD_OPTIONS=$DEB_BUILD_OPTIONS"
}

filter_build_log() {
  # GitHub Actions truncates very large step logs; keep progress + failures only.
  awk '
    /^\[[0-9]+\/[0-9]+\]/ { print; fflush(); next }
    /error:|FAILED:|fatal error:|collect2: error|undefined reference|Killed|No space left|dh_.*error|dpkg-buildpackage: error/ {
      print; fflush(); next
    }
    /^make(\[[0-9]+\])?: \*\*\*/ { print; fflush(); next }
    /^==>/ { print; fflush(); next }
  '
}

run_dpkg_buildpackage() {
  local log="$REPO_ROOT/build.log"
  apply_ci_build_limits
  if [[ "$QUIET_BUILD" == "1" ]]; then
    echo "==> quiet build log → $log (progress + errors only in console)"
    dpkg-buildpackage "${BUILD_ARGS[@]}" 2>&1 | tee "$log" | filter_build_log
    return "${PIPESTATUS[0]}"
  fi
  dpkg-buildpackage "${BUILD_ARGS[@]}"
}

RULES_PATCH_SHA256="$(sha256sum "$PATCH" | awk '{print $1}')"
CMAKE_PATCH_SHA256="$(sha256sum "$CMAKE_PATCH" | awk '{print $1}')"
WEBKIT_PATCH_SHA256="$(cat "$WEBKIT_INTERACTIONS_PATCH" "$WEBKIT_POLICY_PATCH" | sha256sum | awk '{print $1}')"
PATCH_SHA256="$(cat "$PATCH" "$CMAKE_PATCH" "$WEBKIT_INTERACTIONS_PATCH" "$WEBKIT_POLICY_PATCH" | sha256sum | awk '{print $1}')"

apply_rules_patch() {
  echo "==> applying $PATCH"
  patch -p1 < "$PATCH"
}

apply_cmake_patch() {
  if patch -p1 --dry-run < "$CMAKE_PATCH" >/dev/null 2>&1; then
    echo "==> applying $CMAKE_PATCH"
    patch -p1 < "$CMAKE_PATCH"
  else
    echo "==> $CMAKE_PATCH already applied"
  fi
}

revert_cmake_patch_if_applied() {
  if patch -R -p1 --dry-run < "$CMAKE_PATCH" >/dev/null 2>&1; then
    echo "==> reverting previous $CMAKE_PATCH"
    patch -R -p1 < "$CMAKE_PATCH"
  fi
}

apply_source_patch() {
  local patch="$1"
  if patch -p1 --dry-run < "$patch" >/dev/null 2>&1; then
    echo "==> applying $patch"
    patch -p1 < "$patch"
  else
    echo "==> $patch already applied"
  fi
}

apply_all_patches() {
  apply_rules_patch
  apply_source_patch "$WEBKIT_INTERACTIONS_PATCH"
  apply_source_patch "$WEBKIT_POLICY_PATCH"
  apply_cmake_patch
}

ensure_debian_control() {
  # Patched debian/rules enable/disable binary packages; tarball control can be stale.
  rm -f debian/control
  echo "==> regenerating debian/control from debian/rules"
  if ! fakeroot debian/rules debian/control; then
    echo "error: debian/rules debian/control failed" >&2
    exit 1
  fi
  if [[ ! -f debian/control ]]; then
    echo "error: debian/control missing after regeneration" >&2
    exit 1
  fi
  rewrite_webdriver_packaging_metadata .
}

marker_patch_sha256() {
  local src="$1"
  local marker="$src/$MARKER_NAME"
  [[ -f "$marker" ]] || return 1
  awk -F= '/^PATCH_SHA256=/ { print $2; exit }' "$marker"
}

marker_rules_patch_sha256() {
  local src="$1"
  local marker="$src/$MARKER_NAME"
  [[ -f "$marker" ]] || return 1
  awk -F= '/^RULES_PATCH_SHA256=/ { print $2; exit }' "$marker"
}

marker_cmake_patch_sha256() {
  local src="$1"
  local marker="$src/$MARKER_NAME"
  [[ -f "$marker" ]] || return 1
  awk -F= '/^CMAKE_PATCH_SHA256=/ { print $2; exit }' "$marker"
}

marker_stage() {
  local src="$1"
  local marker="$src/$MARKER_NAME"
  [[ -f "$marker" ]] || return 1
  awk -F= '/^STAGE=/ { print $2; exit }' "$marker"
}

write_marker() {
  local src="$1"
  local stage="${2:-prepared}"
  cat >"$src/$MARKER_NAME" <<EOF
SERIES=$SERIES
SUFFIX=$SUFFIX
COMPILE_CACHE_KEY=$COMPILE_CACHE_KEY
PATCH_SHA256=$PATCH_SHA256
RULES_PATCH_SHA256=$RULES_PATCH_SHA256
CMAKE_PATCH_SHA256=$CMAKE_PATCH_SHA256
STAGE=$stage
PREPARED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

write_marker_preserving_compiled() {
  local src="$1"
  local stage
  stage="$(marker_stage "$src" || true)"
  if [[ "$stage" == "compiled" ]] && gtk4_build_tree_looks_complete "$src"; then
    write_marker "$src" compiled
  else
    write_marker "$src" prepared
  fi
}

echo "==> stage=$STAGE_MODE series=$SERIES suffix=$SUFFIX (host=${HOST_SERIES:-unknown})"
echo "==> compile cache key: $COMPILE_CACHE_KEY"
echo "==> work dir: $WORK_DIR"
echo "==> ccache:   $CCACHE_DIR (max $CCACHE_MAXSIZE)"
echo "==> apt cache: ${APT_CACHE_DIR:-<system default>}"
echo "==> DEB_BUILD_OPTIONS=$DEB_BUILD_OPTIONS"

if [[ "$CLEAN_CACHE" == "1" ]]; then
  echo "==> CLEAN_CACHE=1: removing $CCACHE_DIR"
  rm -rf "$CCACHE_DIR"
fi

if [[ "$CLEAN" == "1" ]]; then
  echo "==> CLEAN=1: removing $WORK_DIR"
  rm -rf "$WORK_DIR"
fi

apt_get update
preseed_pbuilder_mirror

# CI: setup-ci-build-env.sh pins archive cmake; keep /usr/bin ahead of /usr/local.
if [[ -n "${GITHUB_ACTIONS:-}${CI_BUILD_LIMITS:-}" ]]; then
  export PATH="/usr/bin:/bin:${PATH}"
fi

if [[ "$APT_UPGRADE" == "1" ]]; then
  echo "==> apt-get upgrade (archives → ${APT_CACHE_DIR:-system})"
  apt_get upgrade -y
fi

apt_get install -y \
  devscripts \
  fakeroot \
  quilt \
  dpkg-dev \
  ubuntu-dev-tools \
  patch \
  ca-certificates \
  ccache \
  binutils-gold

enable_deb_src() {
  local changed=0
  local f

  for f in /etc/apt/sources.list.d/*.sources; do
    [[ -f "$f" ]] || continue
    if grep -q '^Types: deb$' "$f" && ! grep -q '^Types:.*deb-src' "$f"; then
      "${SUDO[@]}" sed -i 's/^Types: deb$/Types: deb deb-src/' "$f"
      changed=1
    fi
  done

  if [[ -f /etc/apt/sources.list ]]; then
    if grep -qE '^#\s*deb-src ' /etc/apt/sources.list; then
      "${SUDO[@]}" sed -i -E 's/^#\s*deb-src /deb-src /' /etc/apt/sources.list
      changed=1
    fi
  fi

  if [[ "$changed" -eq 1 ]] || ! apt-cache showsrc webkit2gtk >/dev/null 2>&1; then
    apt_get update
  fi
}

enable_deb_src

if [[ "$STAGE_MODE" != "package" ]]; then
  apt_get build-dep -y webkit2gtk
fi
finalize_apt_cache

mkdir -p "$WORK_DIR" "$DIST_DIR" "$CCACHE_DIR"
# Put ccache wrappers early so clang/gcc invocations from cmake hit the cache.
export PATH="/usr/lib/ccache:${PATH}"
ccache -M "$CCACHE_MAXSIZE" >/dev/null

# Used by scripts/lib/debian-tarball.sh when refreshing debian/rules on resume.
DOWNLOAD_WEBKIT2GTK_SOURCE_CMD='apt_get source -d webkit2gtk'

find_src_dir() {
  # Prefer -print -quit over `find | head` (pipefail + SIGPIPE → bogus failures).
  find "$WORK_DIR" -maxdepth 1 -type d -name 'webkit2gtk-*' ! -name 'webkit2gtk-*.orig' -print -quit 2>/dev/null || true
}

marker_matches() {
  local src="$1"
  local marker="$src/$MARKER_NAME"
  [[ -f "$marker" ]] || return 1
  grep -qx "SERIES=$SERIES" "$marker" || return 1
  grep -qx "SUFFIX=$SUFFIX" "$marker" || return 1
  if grep -qx "COMPILE_CACHE_KEY=$COMPILE_CACHE_KEY" "$marker"; then
    return 0
  fi
  # Legacy markers (before compile-cache-key): resume and upgrade marker in-place.
  if ! grep -q '^COMPILE_CACHE_KEY=' "$marker"; then
    return 0
  fi
  return 1
}

SRC_DIR="$(find_src_dir)"
RESUME=0
RULES_REFRESHED=0
CMAKE_REFRESHED=0

drop_stale_packaging_files_after_rules_refresh() {
  # gtk4-only control omits stock gtk4 binary packages; drop their generated
  # install stubs. Keep webdriver install manifests: override_dh_auto_install
  # corrects them at package time when compile is skipped (STAGE=compiled).
  # Install lists are only created in override_dh_auto_configure (build phase);
  # debian/rules has no separate configure target (dh configure does not exist).
  echo "==> dropping stale stock gtk4 debhelper files after rules refresh"
  rm -f \
    debian/libwebkitgtk-6.0-4.install \
    debian/libwebkitgtk-6.0-dev.install \
    debian/gir1.2-webkit-6.0.install \
    debian/libjavascriptcoregtk-6.0-1.install \
    debian/libjavascriptcoregtk-6.0-dev.install \
    debian/gir1.2-javascriptcoregtk-6.0.install
}

strip_gtk4_cmake_configure_state() {
  # Deleting only CMakeCache.txt leaves build.ninja; ninja install then re-runs cmake
  # without debian's -DPORT=GTK. Drop ninja metadata so override_dh_auto_configure runs.
  rm -f \
    build-gtk4/CMakeCache.txt \
    build-gtk4/build.ninja \
    build-gtk4/.ninja_deps \
    build-gtk4/.ninja_log
}

reconfigure_gtk4_after_cmake_patch_refresh() {
  strip_gtk4_cmake_configure_state
  rm -rf build-gtk4/CMakeFiles
  echo "==> re-running gtk4 configure+build via debian/rules build (cmake+ninja)"
  # override_dh_auto_* alone uses Unix Makefiles; % dh $@ --buildsystem=cmake+ninja
  # is only applied for targets routed through the dispatcher (e.g. build).
  fakeroot debian/rules build
}

repair_gtk4_build_tree_if_needed() {
  if [[ ! -d build-gtk4 ]]; then
    echo "==> build-gtk4 missing; running debian/rules build (cmake+ninja)"
    fakeroot debian/rules build
    return
  fi
  if gtk4_build_tree_looks_complete .; then
    return 0
  fi
  echo "==> build-gtk4 cmake/ninja state incomplete (stale work-cache); repairing"
  reconfigure_gtk4_after_cmake_patch_refresh
}

if [[ -n "$SRC_DIR" && -d "$SRC_DIR" ]] && marker_matches "$SRC_DIR"; then
  RESUME=1
  echo "==> resuming existing tree: $SRC_DIR"
  cd "$SRC_DIR"
  stored_rules="$(marker_rules_patch_sha256 "$SRC_DIR" || true)"
  stored_cmake="$(marker_cmake_patch_sha256 "$SRC_DIR" || true)"
  stored_patch="$(marker_patch_sha256 "$SRC_DIR" || true)"
  if [[ -n "$stored_rules" && -n "$stored_cmake" ]]; then
    if [[ "$stored_rules" != "$RULES_PATCH_SHA256" ]]; then
      refresh_debian_rules_from_patch "$SRC_DIR" "$PATCH" || exit 1
      RULES_REFRESHED=1
    fi
    if [[ "$stored_cmake" != "$CMAKE_PATCH_SHA256" ]]; then
      revert_cmake_patch_if_applied
      apply_cmake_patch
      CMAKE_REFRESHED=1
    fi
  elif [[ -n "$stored_patch" && "$stored_patch" != "$PATCH_SHA256" ]]; then
    echo "==> legacy marker: refreshing debian/rules after combined patch hash change"
    refresh_debian_rules_from_patch "$SRC_DIR" "$PATCH" || exit 1
    RULES_REFRESHED=1
    if patch -p1 --dry-run < "$CMAKE_PATCH" >/dev/null 2>&1; then
      echo "==> legacy marker: cmake patch not yet applied"
      apply_cmake_patch
      CMAKE_REFRESHED=1
    else
      echo "==> cmake patch already applied; skipping cmake refresh (rules-only bump)"
    fi
  elif [[ -n "$stored_patch" && -z "$stored_rules" ]]; then
    echo "==> upgrading work-tree marker (split patch hashes, patches unchanged)"
  fi
  if [[ "$CMAKE_REFRESHED" == "1" ]]; then
    write_marker "$SRC_DIR" prepared
  else
    write_marker_preserving_compiled "$SRC_DIR"
  fi
else
  if [[ -n "$SRC_DIR" && -d "$SRC_DIR" ]]; then
    echo "==> existing tree does not match series/suffix/compile cache key; refreshing work dir"
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
  fi

  cd "$WORK_DIR"
  WEBKIT_SOURCE_VERSION="$("$REPO_ROOT/scripts/upstream-webkit-version.sh" "$SERIES")"
  echo "==> pulling webkit2gtk source for $SERIES (upstream $WEBKIT_SOURCE_VERSION)"
  apt_get source "webkit2gtk=$WEBKIT_SOURCE_VERSION"

  chown_tree_to_builder "$WORK_DIR"

  SRC_DIR="$(find_src_dir)"
  if [[ -z "$SRC_DIR" || ! -d "$SRC_DIR" ]]; then
    echo "error: could not find unpacked webkit2gtk-* tree in $WORK_DIR" >&2
    ls -la "$WORK_DIR" >&2 || true
    exit 1
  fi

  cd "$SRC_DIR"
  echo "==> source tree: $SRC_DIR"

  apply_all_patches

  BASE_VERSION="$(dpkg-parsechangelog -S Version)"
  NEW_VERSION="${BASE_VERSION}${SUFFIX}"
  echo "==> bumping changelog to $NEW_VERSION"
  dch -v "$NEW_VERSION" "Parallel-install libwebkitgtk-6.0-webdriver (WebKit #318171 interactions, #165269 navigator.webdriver policy)."
  dch -r --distribution "$SERIES" ""

  write_marker "$SRC_DIR" prepared
fi

cd "$SRC_DIR"

if [[ "$RULES_REFRESHED" == "1" ]]; then
  drop_stale_packaging_files_after_rules_refresh
fi

ensure_debian_control

post_prepare_build_state() {
  if [[ "$CMAKE_REFRESHED" == "1" ]]; then
    reconfigure_gtk4_after_cmake_patch_refresh
    write_marker "$SRC_DIR" prepared
    return 0
  fi
  if [[ "$STAGE_MODE" == "package" ]]; then
    local stage
    stage="$(marker_stage "$SRC_DIR" || true)"
    if gtk4_build_tree_looks_complete .; then
      if [[ "$stage" != "compiled" ]]; then
        echo "==> package stage: build-gtk4 complete (marker STAGE=$stage)"
      fi
      return 0
    fi
    echo "error: package stage requires a complete build-gtk4 tree (STAGE=$stage)" >&2
    exit 1
  fi
  if [[ "$RESUME" == "1" ]]; then
    repair_gtk4_build_tree_if_needed
  fi
}

run_compile_stage() {
  local stage
  stage="$(marker_stage "$SRC_DIR" || true)"
  # override_dh_auto_configure (install manifests) only runs during debian/rules build.
  # dpkg-buildpackage -b -nc goes straight to binary and never regenerates *.install.
  if [[ "$stage" == "compiled" ]] && gtk4_build_tree_looks_complete .; then
    echo "==> STAGE=compiled: debian/rules build (refresh install manifests; ninja no-op)"
  else
    echo "==> compiling via debian/rules build (gtk4 cmake+ninja; long-running)"
  fi
  apply_ci_build_limits
  fakeroot debian/rules build
  if ! gtk4_build_tree_looks_complete .; then
    echo "error: compile finished but build-gtk4 is incomplete" >&2
    exit 1
  fi
  write_marker "$SRC_DIR" compiled
  echo "==> compile stage complete (STAGE=compiled)"
}

run_package_stage() {
  # Ensure system JSC/GTK are on disk for dpkg-shlibdeps (webdriver links system JSC).
  echo "==> ensuring runtime libs for dpkg-shlibdeps (libjavascriptcoregtk-6.0-1)"
  apt_get install -y --no-install-recommends \
    libjavascriptcoregtk-6.0-1 \
    libwebkitgtk-6.0-4

  # Ensure PATH/ccache still exported for the package build.
  export PATH="/usr/lib/ccache:${PATH}"
  export CCACHE_DIR
  export CCACHE_NOHASHDIR=1
  export DEB_BUILD_OPTIONS

  if [[ "$STAGE_MODE" == "package" ]]; then
    # Standalone package: compile step did not run rules build above.
    echo "==> package-only: debian/rules build (install manifests; ninja no-op if compiled)"
    apply_ci_build_limits
    fakeroot debian/rules build
  fi

  BUILD_ARGS=(-b -us -uc)
  # Always skip pre-clean once the tree is prepared: object dirs (build-gtk4)
  # are what make an interrupted build resumable. Fresh trees have nothing useful
  # to clean anyway.
  BUILD_ARGS+=(-nc)
  if [[ "$RESUME" == "1" ]]; then
    echo "==> dpkg-buildpackage ${BUILD_ARGS[*]} (resume)"
  else
    echo "==> dpkg-buildpackage ${BUILD_ARGS[*]}"
  fi

  echo "==> packaging .deb (install + binary; compile skipped when STAGE=compiled)"
  run_dpkg_buildpackage

  echo "==> ccache stats:"
  ccache -s || true

  PARENT="$(dirname "$SRC_DIR")"
  shopt -s nullglob
  RUNTIME_DEBS=("$PARENT"/libwebkitgtk-6.0-webdriver4_*.deb)
  DEV_DEBS=("$PARENT"/libwebkitgtk-6.0-webdriver-dev_*.deb)
  shopt -u nullglob

  if [[ ${#RUNTIME_DEBS[@]} -eq 0 || ${#DEV_DEBS[@]} -eq 0 ]]; then
    echo "error: expected libwebkitgtk-6.0-webdriver4_*.deb and libwebkitgtk-6.0-webdriver-dev_*.deb in $PARENT" >&2
    ls -la "$PARENT"/*.deb 2>/dev/null || true
    exit 1
  fi

  rm -f "$DIST_DIR"/libwebkitgtk-6.0-webdriver4_*.deb "$DIST_DIR"/libwebkitgtk-6.0-webdriver-dev_*.deb
  cp -a "${RUNTIME_DEBS[@]}" "${DEV_DEBS[@]}" "$DIST_DIR/"

  echo "==> done. packages in $DIST_DIR:"
  ls -la "$DIST_DIR"/libwebkitgtk-6.0-webdriver*.deb
}

if [[ "$STAGE_MODE" == "package" ]]; then
  post_prepare_build_state
  run_package_stage
elif [[ "$STAGE_MODE" == "compile" ]]; then
  post_prepare_build_state
  run_compile_stage
  echo "==> ccache stats:"
  ccache -s || true
else
  post_prepare_build_state
  run_compile_stage
  run_package_stage
fi
