#!/usr/bin/env bash
# Upgrade a GitHub Actions runner from its base Ubuntu series to TARGET_SERIES.
#
# Used by build-questing.yml: ubuntu-24.04 (noble) → questing (25.10).
# Two-pass dist-upgrade: first on the base release, then after rewriting apt sources.
#
# Env:
#   TARGET_SERIES   Required Ubuntu codename (e.g. questing)
#   BASE_SERIES     Source codename on the runner (default: host VERSION_CODENAME)
#   APT_CACHE_DIR   Optional apt archive cache directory
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=()
else
  SUDO=(sudo)
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

TARGET_SERIES="${TARGET_SERIES:?TARGET_SERIES is required}"
APT_CACHE_DIR="${APT_CACHE_DIR:-}"

# shellcheck source=scripts/lib/host-series.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/host-series.sh"
BASE_SERIES="${BASE_SERIES:-$(host_series)}"

if [[ -z "$BASE_SERIES" ]]; then
  echo "error: could not detect BASE_SERIES" >&2
  exit 1
fi

if [[ "$BASE_SERIES" == "$TARGET_SERIES" ]]; then
  echo "==> runner already on $TARGET_SERIES"
  exit 0
fi

apt_archive_opts() {
  if [[ -n "$APT_CACHE_DIR" ]]; then
    mkdir -p "$APT_CACHE_DIR/partial"
    APT_CACHE_DIR="$(cd "$APT_CACHE_DIR" && pwd)"
    echo "-o" "Dir::Cache::archives=$APT_CACHE_DIR"
  fi
}

prepare_workspace_apt_cache() {
  [[ -n "$APT_CACHE_DIR" ]] || return 0
  mkdir -p "$APT_CACHE_DIR/partial"
  APT_CACHE_DIR="$(cd "$APT_CACHE_DIR" && pwd)"
  "${SUDO[@]}" chown -R _apt:root "$APT_CACHE_DIR"
  "${SUDO[@]}" chmod -R u+rwX,g+rwX "$APT_CACHE_DIR"
}

finalize_workspace_apt_cache() {
  [[ -n "$APT_CACHE_DIR" ]] || return 0
  local cache_dir="$APT_CACHE_DIR"
  "${SUDO[@]}" rm -rf "$cache_dir/partial" "$cache_dir/lock" 2>/dev/null || true
  if [[ "$(id -u)" -ne 0 ]]; then
    "${SUDO[@]}" chown -R "$(id -u):$(id -g)" "$cache_dir"
  fi
}

apt_get() {
  prepare_workspace_apt_cache
  # shellcheck disable=SC2046
  "${SUDO[@]}" apt-get $(apt_archive_opts) "$@"
  local rc=$?
  finalize_workspace_apt_cache
  return "$rc"
}

remove_preinstalled_tool() {
  local path="$1"
  if [[ -f "$path" ]]; then
    echo "    removing preinstalled tool: $path"
    "${SUDO[@]}" rm -f "$path"
  fi
}

strip_conflicting_runner_tools() {
  echo "==> removing GHA preinstalled build tools (use Ubuntu archive packages)"
  for tool in cmake cpack ctest ninja ccmake; do
    remove_preinstalled_tool "/usr/local/bin/$tool"
  done
}

remove_runner_apt_sources() {
  echo "==> removing GHA runner apt sources (mirrorlist / azure / third-party)"
  local f
  shopt -s nullglob
  for f in /etc/apt/sources.list.d/*; do
    [[ -f "$f" ]] || continue
    echo "    removing $f"
    "${SUDO[@]}" rm -f "$f"
  done
  shopt -u nullglob
  if [[ -f /etc/apt/sources.list ]]; then
    "${SUDO[@]}" tee /etc/apt/sources.list >/dev/null <<'EOF'
# Managed by webkitgtk-automation upgrade-runner-to-series.sh
EOF
  fi
  if [[ -f /etc/apt/apt-mirrors.txt ]]; then
    echo "    removing /etc/apt/apt-mirrors.txt"
    "${SUDO[@]}" rm -f /etc/apt/apt-mirrors.txt
  fi
  "${SUDO[@]}" rm -rf /var/lib/apt/lists/*
}

write_ubuntu_archive_sources() {
  local series="$1"
  echo "==> writing Ubuntu archive sources for $series (archive.ubuntu.com only)"
  "${SUDO[@]}" tee /etc/apt/sources.list.d/ubuntu.sources >/dev/null <<EOF
Types: deb deb-src
URIs: http://archive.ubuntu.com/ubuntu
Suites: ${series} ${series}-updates ${series}-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
}

apt_dist_upgrade() {
  local rc=0
  set +e
  apt_get \
    -o Acquire::AllowReleaseInfoChange=true \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    dist-upgrade -y
  rc=$?
  "${SUDO[@]}" dpkg --configure -a || true
  set -e

  if [[ "$rc" -ne 0 ]]; then
    if "${SUDO[@]}" dpkg --audit 2>/dev/null | grep -q .; then
      echo "error: dpkg audit reported broken packages after dist-upgrade (apt exit $rc)" >&2
      "${SUDO[@]}" dpkg --audit >&2 || true
      return "$rc"
    fi
    echo "warning: apt-get dist-upgrade exited $rc but dpkg audit is clean; continuing"
    rc=0
  fi
  return "$rc"
}

disable_needrestart() {
  echo "==> disabling needrestart during release upgrade"
  if dpkg -s needrestart >/dev/null 2>&1; then
    apt_get purge -y needrestart || true
  fi
}

setup_post_upgrade_build_env() {
  local setup_script
  setup_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/setup-ci-build-env.sh"
  if [[ ! -x "$setup_script" ]]; then
    chmod +x "$setup_script"
  fi
  echo "==> post-upgrade apt update"
  apt_get update -qq
  echo "==> setup CI build environment on $TARGET_SERIES"
  NEEDRESTART_SUSPEND=1 APT_CACHE_DIR="" "$setup_script"
}

add_swap() {
  local swap_file="${SWAP_FILE:-/swapfile}" swap_gb="${SWAP_GB:-8}"
  if swapon --show 2>/dev/null | grep -q .; then
    return 0
  fi
  echo "==> adding ${swap_gb}G swap at $swap_file"
  if [[ ! -f "$swap_file" ]]; then
    if ! "${SUDO[@]}" fallocate -l "${swap_gb}G" "$swap_file" 2>/dev/null; then
      "${SUDO[@]}" dd if=/dev/zero of="$swap_file" bs=1M count=$((swap_gb * 1024)) status=progress
    fi
    "${SUDO[@]}" chmod 600 "$swap_file"
    "${SUDO[@]}" mkswap "$swap_file"
  fi
  "${SUDO[@]}" swapon "$swap_file" || echo "warning: swapon failed (continuing)" >&2
}

# shellcheck source=.github/scripts/strip-third-party-apt-sources.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/strip-third-party-apt-sources.sh"

main() {
  echo "==> upgrade-runner-to-series: $BASE_SERIES → $TARGET_SERIES"
  if [[ -n "$APT_CACHE_DIR" ]]; then
    echo "==> dist-upgrade archives → $APT_CACHE_DIR"
  else
    echo "==> dist-upgrade uses system apt cache"
  fi
  add_swap
  strip_conflicting_runner_tools
  strip_third_party_apt_sources
  remove_runner_apt_sources
  write_ubuntu_archive_sources "$BASE_SERIES"

  echo "==> pass 1: update/upgrade/dist-upgrade on $BASE_SERIES (archive.ubuntu.com)"
  apt_get update -qq
  disable_needrestart
  apt_get upgrade -y
  apt_dist_upgrade

  write_ubuntu_archive_sources "$TARGET_SERIES"

  echo "==> pass 2: dist-upgrade to $TARGET_SERIES (archive.ubuntu.com)"
  apt_get update -qq
  apt_dist_upgrade

  local upgraded_series
  upgraded_series="$(host_series)"
  echo "==> host series after pass 2: ${upgraded_series:-unknown}"
  if [[ "$upgraded_series" != "$TARGET_SERIES" ]]; then
    echo "error: expected VERSION_CODENAME=$TARGET_SERIES after dist-upgrade, got ${upgraded_series:-<empty>}" >&2
    exit 1
  fi

  setup_post_upgrade_build_env

  echo "==> upgrade-runner-to-series done ($(host_series))"
}

main "$@"
