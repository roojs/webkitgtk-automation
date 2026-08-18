#!/usr/bin/env bash
# Pack / unpack the incremental WebKit work tree for GitHub Actions cache.
#
# We cache enough to resume `dpkg-buildpackage -nc` after an interrupt:
#   work/webkit2gtk-*/          (unpacked source + debian/ + build-gtk4/)
# and drop re-downloadable / disposable bulk:
#   work/*.orig.tar.*  work/*.dsc  work/*.debian.tar.*  work/*.deb  …
#
# Usage:
#   work-cache.sh pack
#   work-cache.sh unpack
#   work-cache.sh size
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/gtk4-build-state.sh
source "$REPO_ROOT/scripts/lib/gtk4-build-state.sh"
WORK_DIR="${WORK_DIR:-$REPO_ROOT/work}"
CACHE_ROOT="${WORK_CACHE_DIR:-$REPO_ROOT/.ci-cache/work}"
ARCHIVE="$CACHE_ROOT/work-incremental.tar.zst"
# Soft limit before upload (Actions entries are large but repo quota is finite).
MAX_BYTES="${WORK_CACHE_MAX_BYTES:-$((10 * 1024 * 1024 * 1024))}"
MARKER_NAME=".webkitgtk-automation-prepared"

mkdir -p "$CACHE_ROOT"

cmd="${1:-}"

find_src_dir() {
  # Prefer -print -quit over `find | head` (pipefail + SIGPIPE → bogus exit 1).
  find "$WORK_DIR" -maxdepth 1 -type d -name 'webkit2gtk-*' ! -name 'webkit2gtk-*.orig' -print -quit 2>/dev/null || true
}

human_bytes() {
  local b="$1"
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec --suffix=B "$b"
  else
    echo "${b}B"
  fi
}

cmd_size() {
  local src total=0
  src="$(find_src_dir)"
  if [[ -z "$src" || ! -d "$src" ]]; then
    echo "0"
    return 0
  fi
  total="$(du -sb "$src" | awk '{print $1}')"
  echo "$total"
}

cmd_pack() {
  local src name
  src="$(find_src_dir)"
  if [[ -z "$src" || ! -d "$src" ]]; then
    echo "work-cache: nothing to pack (no work/webkit2gtk-* tree)"
    exit 0
  fi
  if [[ ! -f "$src/$MARKER_NAME" ]]; then
    echo "work-cache: refusing to pack — missing $MARKER_NAME (tree not prepared by build.sh)" >&2
    exit 2
  fi
  if [[ -d "$src/build-gtk4" ]] && ! gtk4_build_tree_looks_complete "$src"; then
    echo "work-cache: refusing to pack — build-gtk4 is not resumable (would poison the work cache)" >&2
    exit 0
  fi

  name="$(basename "$src")"
  local bytes
  bytes="$(du -sb "$src" | awk '{print $1}')"
  echo "work-cache: packing $name ($(human_bytes "$bytes")) → $ARCHIVE"

  if [[ "$bytes" -gt "$MAX_BYTES" ]]; then
    echo "work-cache: warning: tree is $(human_bytes "$bytes") which exceeds WORK_CACHE_MAX_BYTES=$(human_bytes "$MAX_BYTES")" >&2
    echo "work-cache: will still pack; Actions cache save may fail or evict other entries." >&2
  fi

  rm -f "$ARCHIVE"
  # Exclude disposable / regenerable bulk inside the tree.
  tar -C "$WORK_DIR" \
    --exclude="$name/debian/tmp" \
    --exclude="$name/debian/tmp.*" \
    --exclude="$name/ccache" \
    --zstd -cf "$ARCHIVE" \
    "$name"

  local out
  out="$(du -sb "$ARCHIVE" | awk '{print $1}')"
  echo "work-cache: archive $(human_bytes "$out") at $ARCHIVE"

  if [[ "$out" -gt "$MAX_BYTES" ]]; then
    echo "work-cache: archive still over limit; removing archive so cache save is skipped" >&2
    rm -f "$ARCHIVE"
    exit 3
  fi
}

cmd_unpack() {
  if [[ ! -f "$ARCHIVE" ]]; then
    echo "work-cache: no archive at $ARCHIVE (cold start)" >&2
    exit 0
  fi

  local out
  out="$(du -sb "$ARCHIVE" | awk '{print $1}')"
  echo "work-cache: unpacking $(human_bytes "$out") → $WORK_DIR"

  mkdir -p "$WORK_DIR"
  tar -C "$WORK_DIR" --zstd -xf "$ARCHIVE"

  local src
  src="$(find_src_dir)"
  if [[ -z "$src" || ! -f "$src/$MARKER_NAME" ]]; then
    echo "work-cache: unpack did not yield a prepared tree; wiping work/" >&2
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    exit 1
  fi

  echo "work-cache: restored $src"
  if [[ -d "$src/build-gtk4" ]]; then
    echo "work-cache: build-gtk4 present — build.sh can resume with -nc"
  else
    echo "work-cache: build-gtk4 missing — configure/build will start after restore"
  fi
}

case "$cmd" in
  pack) cmd_pack ;;
  unpack) cmd_unpack ;;
  size) cmd_size ;;
  *)
    echo "Usage: $0 pack|unpack|size" >&2
    exit 1
    ;;
esac
