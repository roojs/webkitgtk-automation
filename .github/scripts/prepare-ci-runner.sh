#!/usr/bin/env bash
# Hosted-runner hardening for multi-hour WebKit package builds.
#
# - Adds swap for linker RAM spikes (OOM killer is a common silent failure mode).
# - Prints CPU/RAM/disk headroom so logs show whether limits were hit.
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=()
else
  SUDO=(sudo)
fi

SWAP_FILE="${SWAP_FILE:-/swapfile}"
SWAP_GB="${SWAP_GB:-8}"

echo "==> runner resources (before swap)"
nproc || true
free -h || true
df -h / || true

if swapon --show 2>/dev/null | grep -q .; then
  echo "==> swap already active:"
  swapon --show || true
else
  echo "==> adding ${SWAP_GB}G swap at $SWAP_FILE (linker RAM headroom)"
  if [[ ! -f "$SWAP_FILE" ]]; then
    if ! "${SUDO[@]}" fallocate -l "${SWAP_GB}G" "$SWAP_FILE" 2>/dev/null; then
      "${SUDO[@]}" dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$((SWAP_GB * 1024)) status=progress
    fi
    "${SUDO[@]}" chmod 600 "$SWAP_FILE"
    "${SUDO[@]}" mkswap "$SWAP_FILE"
  fi
  "${SUDO[@]}" swapon "$SWAP_FILE" || echo "warning: swapon failed (continuing)" >&2
fi

echo "==> runner resources (after swap)"
free -h || true
df -h / || true
