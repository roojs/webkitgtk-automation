#!/usr/bin/env bash
# Bootstrap a Debian chroot on an Ubuntu GitHub runner.
# The Actions agent stays on Ubuntu. The build runs inside this root, where
# /etc/os-release VERSION_CODENAME matches SERIES (native Debian, not a
# dist-upgrade of the host).
#
# Usage: .github/scripts/prepare-debian-chroot.sh trixie
set -euo pipefail

SERIES="${1:?series required}"
case "$SERIES" in
  trixie) ;;
  *)
    echo "error: prepare-debian-chroot supports trixie only (got $SERIES)" >&2
    exit 1
    ;;
esac

if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=()
else
  SUDO=(sudo)
fi

export DEBIAN_FRONTEND=noninteractive
ROOT="${DEBIAN_CHROOT_ROOT:-/var/lib/webkitgtk-chroot/${SERIES}}"
MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
SECURITY_MIRROR="${DEBIAN_SECURITY_MIRROR:-http://deb.debian.org/debian-security}"

echo "==> prepare debian chroot series=$SERIES root=$ROOT"
"${SUDO[@]}" apt-get update -qq
"${SUDO[@]}" apt-get install -y -qq debootstrap debian-archive-keyring

if [[ ! -f "$ROOT/etc/os-release" ]]; then
  echo "==> debootstrap $SERIES"
  "${SUDO[@]}" debootstrap --variant=minbase --include=ca-certificates "$SERIES" "$ROOT" "$MIRROR"
fi

"${SUDO[@]}" tee "$ROOT/etc/apt/sources.list" >/dev/null <<SOURCES
deb ${MIRROR} ${SERIES} main
deb ${MIRROR} ${SERIES}-updates main
deb ${SECURITY_MIRROR} ${SERIES}-security main
deb-src ${MIRROR} ${SERIES} main
deb-src ${MIRROR} ${SERIES}-updates main
deb-src ${SECURITY_MIRROR} ${SERIES}-security main
SOURCES
"${SUDO[@]}" rm -f "$ROOT/etc/apt/sources.list.d/"*.sources "$ROOT/etc/apt/sources.list.d/"*.list || true

if [[ -r /etc/resolv.conf ]]; then
  "${SUDO[@]}" cp /etc/resolv.conf "$ROOT/etc/resolv.conf"
fi

echo "==> prepare-debian-chroot done ($ROOT)"
