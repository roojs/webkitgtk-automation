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
    mkdir -p "$APT_CACHE_DIR"
    APT_CACHE_DIR="$(cd "$APT_CACHE_DIR" && pwd)"
    echo "-o" "Dir::Cache::archives=$APT_CACHE_DIR"
  fi
}

apt_get() {
  # shellcheck disable=SC2046
  "${SUDO[@]}" apt-get $(apt_archive_opts) "$@"
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

ubuntu_archive_source_file() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  grep -qE 'archive\.ubuntu\.com|azure\.archive\.ubuntu\.com|security\.ubuntu\.com|ports\.ubuntu\.com' "$f"
}

rewrite_sources_to_series() {
  local from="$1" to="$2"
  echo "==> rewriting Ubuntu archive apt sources $from → $to"
  local f
  shopt -s nullglob
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -f "$f" ]] || continue
    ubuntu_archive_source_file "$f" || continue
    "${SUDO[@]}" sed -i \
      -e "s/${from}/${to}/g" \
      -e "s/${from}-security/${to}-security/g" \
      -e "s/${from}-updates/${to}-updates/g" \
      -e "s/${to}-security-security/${to}-security/g" \
      -e "s/${to}-updates-updates/${to}-updates/g" \
      "$f"
  done
  shopt -u nullglob
}

enable_deb_src() {
  local f changed=0
  for f in /etc/apt/sources.list.d/*.sources; do
    [[ -f "$f" ]] || continue
    if grep -q '^Types: deb$' "$f" && ! grep -q '^Types:.*deb-src' "$f"; then
      "${SUDO[@]}" sed -i 's/^Types: deb$/Types: deb deb-src/' "$f"
      changed=1
    fi
  done
  if [[ -f /etc/apt/sources.list ]] && grep -qE '^#\s*deb-src ' /etc/apt/sources.list; then
    "${SUDO[@]}" sed -i -E 's/^#\s*deb-src /deb-src /' /etc/apt/sources.list
    changed=1
  fi
  if [[ "$changed" -eq 1 ]]; then
    apt_get update -qq
  fi
}

install_orchestration_packages() {
  local archive_cmake archive_cmake_data
  local -a pkgs=(
    build-essential
    ca-certificates
    ccache
    binutils-gold
    devscripts
    dpkg-dev
    fakeroot
    ninja-build
    patch
    quilt
    ubuntu-dev-tools
    zstd
  )

  archive_cmake="$(apt-cache madison cmake 2>/dev/null | awk '/ubuntu/ { print $3; exit }')"
  archive_cmake_data="$(apt-cache madison cmake-data 2>/dev/null | awk -v want="$archive_cmake" '$3 == want { print $3; exit }')"
  if [[ -z "$archive_cmake" ]]; then
    echo "error: could not resolve archive cmake version for $TARGET_SERIES" >&2
    exit 1
  fi
  [[ -n "$archive_cmake_data" ]] || archive_cmake_data="$archive_cmake"

  echo "==> installing orchestration packages + archive cmake=${archive_cmake}"
  apt_get install -y --allow-downgrades \
    "${pkgs[@]}" \
    "cmake=${archive_cmake}" \
    "cmake-data=${archive_cmake_data}"

  "${SUDO[@]}" apt-mark hold cmake cmake-data >/dev/null

  if [[ -n "$APT_CACHE_DIR" ]]; then
    "${SUDO[@]}" rm -rf "$APT_CACHE_DIR/partial" "$APT_CACHE_DIR/lock"
    if [[ "$(id -u)" -ne 0 ]]; then
      "${SUDO[@]}" chown -R "$(id -u):$(id -g)" "$APT_CACHE_DIR"
    fi
  fi
}

verify_toolchain() {
  export PATH="/usr/bin:/bin:${PATH}"
  hash -r

  echo "==> toolchain after upgrade"
  echo "    series: $(host_series) (target=$TARGET_SERIES)"
  echo "    cmake: $(command -v cmake) ($(cmake --version | head -n 1))"
  echo "    ninja: $(command -v ninja 2>/dev/null || echo missing)"

  if [[ "$(host_series)" != "$TARGET_SERIES" ]]; then
    echo "error: host series $(host_series) != TARGET_SERIES=$TARGET_SERIES after upgrade" >&2
    exit 1
  fi

  if cmake --version | grep -qE 'cmake version 4\.4'; then
    echo "error: cmake 4.4.x still active after upgrade" >&2
    exit 1
  fi

  if [[ -n "${GITHUB_ENV:-}" && -w "${GITHUB_ENV}" ]]; then
    echo "PATH=/usr/bin:/bin:${PATH}" >>"$GITHUB_ENV"
  fi
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

prepare_apt_cache_dir() {
  [[ -n "$APT_CACHE_DIR" ]] || return 0
  mkdir -p "$APT_CACHE_DIR/partial"
  APT_CACHE_DIR="$(cd "$APT_CACHE_DIR" && pwd)"
  # _apt must read the workspace cache when apt runs via sudo.
  "${SUDO[@]}" chown -R _apt:root "$APT_CACHE_DIR"
  "${SUDO[@]}" chmod -R u+rwX,g+rwX "$APT_CACHE_DIR"
}

main() {
  echo "==> upgrade-runner-to-series: $BASE_SERIES → $TARGET_SERIES"
  add_swap
  strip_conflicting_runner_tools
  strip_third_party_apt_sources
  prepare_apt_cache_dir

  echo "==> pass 1: update/upgrade/dist-upgrade on $BASE_SERIES"
  apt_get update -qq
  apt_get upgrade -y
  apt_get dist-upgrade -y

  rewrite_sources_to_series "$BASE_SERIES" "$TARGET_SERIES"

  echo "==> pass 2: dist-upgrade to $TARGET_SERIES"
  apt_get update -qq
  apt_get dist-upgrade -y

  install_orchestration_packages
  enable_deb_src
  verify_toolchain

  echo "==> upgrade-runner-to-series done ($(host_series))"
}

main "$@"
