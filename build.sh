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
#   - Patch uses -fuse-ld=lld (less RAM linking libjavascriptcoregtk) and -g0
#   - GTK4-only build (soup3 skipped); system webkitgtk-webdriver is kept
set -euo pipefail

host_series() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "${VERSION_CODENAME:-}"
  fi
}

HOST_SERIES="$(host_series)"
DEFAULT_SERIES="${HOST_SERIES:-noble}"
SERIES="${SERIES:-${1:-$DEFAULT_SERIES}}"
SUFFIX="${SUFFIX:-${2:-+webkitgtk1}}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$REPO_ROOT/patches/enable-webdriver-gtk4.patch"
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

usage() {
  cat <<'EOF'
Usage: ./build.sh [SERIES] [SUFFIX]

Env:
  SERIES              Ubuntu series (default: host VERSION_CODENAME, else noble)
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

PATCH_SHA256="$(sha256sum "$PATCH" | awk '{print $1}')"

echo "==> series=$SERIES suffix=$SUFFIX (host=${HOST_SERIES:-unknown})"
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

if [[ "$APT_UPGRADE" == "1" ]]; then
  echo "==> apt-get upgrade (archives → ${APT_CACHE_DIR:-system})"
  apt_get upgrade -y
fi

apt_get install -y \
  devscripts \
  quilt \
  dpkg-dev \
  ubuntu-dev-tools \
  patch \
  ca-certificates \
  ccache \
  lld

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

find_src_dir() {
  # Prefer -print -quit over `find | head` (pipefail + SIGPIPE → bogus failures).
  find "$WORK_DIR" -maxdepth 1 -type d -name 'webkit2gtk-*' ! -name 'webkit2gtk-*.orig' -print -quit 2>/dev/null || true
}

marker_matches() {
  local src="$1"
  local marker="$src/$MARKER_NAME"
  [[ -f "$marker" ]] || return 1
  grep -qx "SERIES=$SERIES" "$marker" \
    && grep -qx "SUFFIX=$SUFFIX" "$marker" \
    && grep -qx "PATCH_SHA256=$PATCH_SHA256" "$marker"
}

write_marker() {
  local src="$1"
  cat >"$src/$MARKER_NAME" <<EOF
SERIES=$SERIES
SUFFIX=$SUFFIX
PATCH_SHA256=$PATCH_SHA256
PREPARED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

SRC_DIR="$(find_src_dir)"
RESUME=0

if [[ -n "$SRC_DIR" && -d "$SRC_DIR" ]] && marker_matches "$SRC_DIR"; then
  RESUME=1
  echo "==> resuming existing tree: $SRC_DIR"
else
  if [[ -n "$SRC_DIR" && -d "$SRC_DIR" ]]; then
    echo "==> existing tree does not match series/suffix/patch; refreshing work dir"
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
  fi

  cd "$WORK_DIR"
  echo "==> pulling webkit2gtk source for $SERIES"
  if command -v pull-lp-source >/dev/null 2>&1; then
    pull-lp-source webkit2gtk "$SERIES"
  else
    apt_get source webkit2gtk
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
dpkg-buildpackage "${BUILD_ARGS[@]}"

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
