#!/usr/bin/env bash
# Run a command inside the Debian chroot prepared by prepare-debian-chroot.sh.
# Bind-mounts the workspace at the same absolute path so build.sh and caches match.
#
# Usage: .github/scripts/run-in-debian-chroot.sh trixie ./build.sh compile
set -euo pipefail

SERIES="${1:?series required}"
shift
if (($# == 0)); then
  echo "error: command required" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=.github/scripts/prepare-debian-chroot.sh
# Prepare is idempotent; call it so a lone run still bootstraps.
"$REPO_ROOT/.github/scripts/prepare-debian-chroot.sh" "$SERIES"

if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=()
else
  SUDO=(sudo)
fi

ROOT="${DEBIAN_CHROOT_ROOT:-/var/lib/webkitgtk-chroot/${SERIES}}"
WORK_HOST="$(pwd)"
owner="$(stat -c '%u:%g' "$REPO_ROOT")"

mount_one() {
  local src="$1" dest="$2"
  "${SUDO[@]}" mkdir -p "$dest"
  if ! mountpoint -q "$dest"; then
    "${SUDO[@]}" mount --bind "$src" "$dest"
  fi
}

mount_one /proc "$ROOT/proc"
mount_one /sys "$ROOT/sys"
mount_one /dev "$ROOT/dev"
if [[ -d /dev/pts ]]; then
  mount_one /dev/pts "$ROOT/dev/pts"
fi
"${SUDO[@]}" mkdir -p "$ROOT$WORK_HOST"
if ! mountpoint -q "$ROOT$WORK_HOST"; then
  "${SUDO[@]}" mount --bind "$WORK_HOST" "$ROOT$WORK_HOST"
fi

rc=0
"${SUDO[@]}" chroot "$ROOT" /usr/bin/env \
  HOME=/root \
  PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  DEBIAN_FRONTEND=noninteractive \
  SERIES="$SERIES" \
  SUFFIX="${SUFFIX:-}" \
  GITHUB_ACTIONS="${GITHUB_ACTIONS:-}" \
  CI_BUILD_LIMITS="${CI_BUILD_LIMITS:-}" \
  CI_BUILD_DEP_PROBE="${CI_BUILD_DEP_PROBE:-}" \
  APT_CACHE_DIR="${APT_CACHE_DIR:-}" \
  APT_UPGRADE="${APT_UPGRADE:-0}" \
  CLEAN="${CLEAN:-0}" \
  CLEAN_CACHE="${CLEAN_CACHE:-0}" \
  CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-}" \
  BUILD_PARALLEL_JOBS="${BUILD_PARALLEL_JOBS:-}" \
  DEB_BUILD_OPTIONS="${DEB_BUILD_OPTIONS:-}" \
  PBUILDER_MIRROR="${PBUILDER_MIRROR:-http://deb.debian.org/debian}" \
  DEBEMAIL="${DEBEMAIL:-alan@roojs.com}" \
  DEBFULLNAME="${DEBFULLNAME:-Alan Knowles}" \
  /bin/bash -c 'cd "$1" && shift && exec "$@"' _ "$WORK_HOST" "$@" || rc=$?

# Cache save and later steps run as the GitHub runner user.
"${SUDO[@]}" chown -R "$owner" "$REPO_ROOT" || true
exit "$rc"
