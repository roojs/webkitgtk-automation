#!/usr/bin/env bash
# Rebuild Ubuntu libwebkitgtk-6.0 with ENABLE_WEBDRIVER for GTK4 (WebKit #318171).
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

HOST_SERIES="$(host_series)"
DEFAULT_SERIES="$HOST_SERIES"
if [[ -z "$DEFAULT_SERIES" ]] || ! series_registered "$DEFAULT_SERIES"; then
  DEFAULT_SERIES="resolute"
fi
SERIES="${SERIES:-${1:-$DEFAULT_SERIES}}"
SUFFIX="${SUFFIX:-${2:-+webkitgtk1}}"
PATCH="$(patch_file_for_series "$SERIES")"
COMPILE_CACHE_KEY_FILE="$REPO_ROOT/.github/compile-cache-key"
# shellcheck source=scripts/lib/debian-tarball.sh
source "$REPO_ROOT/scripts/lib/debian-tarball.sh"
# shellcheck source=scripts/lib/pinned-webkit-version.sh
source "$REPO_ROOT/scripts/lib/pinned-webkit-version.sh"
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
Usage: ./build.sh [SERIES] [SUFFIX]

Env:
  SERIES              Ubuntu series (default: host VERSION_CODENAME, else resolute)
  SUFFIX              Version suffix (default: +webkitgtk1)
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

export DEBEMAIL="${DEBEMAIL:-webkitgtk-automation@localhost}"
export DEBFULLNAME="${DEBFULLNAME:-webkitgtk-automation}"
export CCACHE_DIR
export CCACHE_NOHASHDIR=1
export DEB_BUILD_OPTIONS

APT_ARCHIVE_OPTS=()
if [[ -n "$APT_CACHE_DIR" ]]; then
  mkdir -p "$APT_CACHE_DIR"
  # Resolve to absolute path — apt runs as root and relative paths are fragile.
  APT_CACHE_DIR="$(cd "$APT_CACHE_DIR" && pwd)"
  APT_ARCHIVE_OPTS=(-o "Dir::Cache::archives=$APT_CACHE_DIR")
fi

apt_get() {
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

PATCH_SHA256="$(sha256sum "$PATCH" | awk '{print $1}')"

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
}

marker_patch_sha256() {
  local src="$1"
  local marker="$src/$MARKER_NAME"
  [[ -f "$marker" ]] || return 1
  awk -F= '/^PATCH_SHA256=/ { print $2; exit }' "$marker"
}

echo "==> series=$SERIES suffix=$SUFFIX (host=${HOST_SERIES:-unknown})"
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

apt_get build-dep -y webkit2gtk
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

write_marker() {
  local src="$1"
  cat >"$src/$MARKER_NAME" <<EOF
SERIES=$SERIES
SUFFIX=$SUFFIX
COMPILE_CACHE_KEY=$COMPILE_CACHE_KEY
PATCH_SHA256=$PATCH_SHA256
PREPARED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

SRC_DIR="$(find_src_dir)"
RESUME=0
RULES_REFRESHED=0

drop_stale_packaging_state_after_rules_refresh() {
  # Packaging-only rules change: gtk4-only control omits gtk3 binaries, so -N gtk3
  # flags are invalid. Regenerated install lists must match patched override_dh_auto_configure.
  echo "==> dropping stale gtk4 debhelper files and cmake cache after rules refresh"
  rm -f \
    debian/libwebkitgtk-6.0-4.install \
    debian/libwebkitgtk-6.0-dev.install \
    debian/gir1.2-webkit-6.0.install \
    debian/libjavascriptcoregtk-6.0-1.install \
    debian/libjavascriptcoregtk-6.0-dev.install \
    debian/gir1.2-javascriptcoregtk-6.0.install \
    debian/clean
  if [[ -f build-gtk4/CMakeCache.txt ]]; then
    rm -f build-gtk4/CMakeCache.txt
  fi
}

if [[ -n "$SRC_DIR" && -d "$SRC_DIR" ]] && marker_matches "$SRC_DIR"; then
  RESUME=1
  echo "==> resuming existing tree: $SRC_DIR"
  cd "$SRC_DIR"
  stored_patch="$(marker_patch_sha256 "$SRC_DIR" || true)"
  if [[ -n "$stored_patch" && "$stored_patch" != "$PATCH_SHA256" ]]; then
    refresh_debian_rules_from_patch "$SRC_DIR" "$PATCH" || exit 1
    RULES_REFRESHED=1
    write_marker "$SRC_DIR"
  else
    write_marker "$SRC_DIR"
  fi
else
  if [[ -n "$SRC_DIR" && -d "$SRC_DIR" ]]; then
    echo "==> existing tree does not match series/suffix/compile cache key; refreshing work dir"
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
  fi

  cd "$WORK_DIR"
  PINNED_WEBKIT_VERSION="$(read_pinned_webkit_version "$SERIES")"
  echo "==> pulling webkit2gtk source for $SERIES (pinned $PINNED_WEBKIT_VERSION)"
  if command -v pull-lp-source >/dev/null 2>&1; then
    # pull-lp-source has no version pin; use apt for reproducible builds.
    apt_get source "webkit2gtk=$PINNED_WEBKIT_VERSION"
  else
    apt_get source "webkit2gtk=$PINNED_WEBKIT_VERSION"
  fi

  SRC_DIR="$(find_src_dir)"
  if [[ -z "$SRC_DIR" || ! -d "$SRC_DIR" ]]; then
    echo "error: could not find unpacked webkit2gtk-* tree in $WORK_DIR" >&2
    ls -la "$WORK_DIR" >&2 || true
    exit 1
  fi

  cd "$SRC_DIR"
  echo "==> source tree: $SRC_DIR"

  echo "==> applying $PATCH"
  patch -p1 < "$PATCH"

  BASE_VERSION="$(dpkg-parsechangelog -S Version)"
  NEW_VERSION="${BASE_VERSION}${SUFFIX}"
  echo "==> bumping changelog to $NEW_VERSION"
  dch -v "$NEW_VERSION" "Enable ENABLE_WEBDRIVER for GTK4/libwebkitgtk-6.0 (WebKit #318171)."
  dch -r --distribution "$SERIES" ""

  write_marker "$SRC_DIR"
fi

cd "$SRC_DIR"

if [[ "$RULES_REFRESHED" == "1" ]]; then
  drop_stale_packaging_state_after_rules_refresh
fi

ensure_debian_control

# Ensure PATH/ccache still exported for the package build.
export PATH="/usr/lib/ccache:${PATH}"
export CCACHE_DIR
export CCACHE_NOHASHDIR=1
export DEB_BUILD_OPTIONS

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

echo "==> building packages (long-running; interrupt-safe if WORK_DIR is kept)"
run_dpkg_buildpackage

echo "==> ccache stats:"
ccache -s || true

PARENT="$(dirname "$SRC_DIR")"
shopt -s nullglob
RUNTIME_DEBS=("$PARENT"/libwebkitgtk-6.0-4_*.deb)
DEV_DEBS=("$PARENT"/libwebkitgtk-6.0-dev_*.deb)
shopt -u nullglob

if [[ ${#RUNTIME_DEBS[@]} -eq 0 || ${#DEV_DEBS[@]} -eq 0 ]]; then
  echo "error: expected libwebkitgtk-6.0-4_*.deb and libwebkitgtk-6.0-dev_*.deb in $PARENT" >&2
  ls -la "$PARENT"/*.deb 2>/dev/null || true
  exit 1
fi

rm -f "$DIST_DIR"/libwebkitgtk-6.0-4_*.deb "$DIST_DIR"/libwebkitgtk-6.0-dev_*.deb
cp -a "${RUNTIME_DEBS[@]}" "${DEV_DEBS[@]}" "$DIST_DIR/"

echo "==> done. packages in $DIST_DIR:"
ls -la "$DIST_DIR"/libwebkitgtk-6.0-*.deb
