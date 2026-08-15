#!/usr/bin/env bash
# Minimal CI build environment for native webkit2gtk packaging.
#
# 1. Swap for linker RAM headroom
# 2. Remove GHA preinstalled tools that conflict with Ubuntu archive packages
# 3. apt-get update only (no dist-upgrade — keeps a known, buildable base)
# 4. Install only orchestration packages we need; webkit build-deps come from build.sh
# 5. Pin cmake from the Ubuntu archive (not GHA /usr/local CMake 4.4.x)
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=()
else
  SUDO=(sudo)
fi

export DEBIAN_FRONTEND=noninteractive

SWAP_FILE="${SWAP_FILE:-/swapfile}"
SWAP_GB="${SWAP_GB:-8}"
APT_CACHE_DIR="${APT_CACHE_DIR:-}"

host_series() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "${VERSION_CODENAME:-}"
  fi
}

apt_archive_opts() {
  if [[ -n "$APT_CACHE_DIR" ]]; then
    mkdir -p "$APT_CACHE_DIR/partial"
    APT_CACHE_DIR="$(cd "$APT_CACHE_DIR" && pwd)"
    echo "-o" "Dir::Cache::archives=$APT_CACHE_DIR"
  fi
}

prepare_apt_cache() {
  [[ -n "$APT_CACHE_DIR" ]] || return 0
  mkdir -p "$APT_CACHE_DIR/partial"
  APT_CACHE_DIR="$(cd "$APT_CACHE_DIR" && pwd)"
  "${SUDO[@]}" chown -R _apt:root "$APT_CACHE_DIR"
  "${SUDO[@]}" chmod -R u+rwX,g+rwX "$APT_CACHE_DIR"
}

finalize_apt_cache() {
  [[ -n "$APT_CACHE_DIR" ]] || return 0
  local cache_dir="$APT_CACHE_DIR"
  "${SUDO[@]}" rm -rf "$cache_dir/partial" "$cache_dir/lock" 2>/dev/null || true
  if [[ "$(id -u)" -ne 0 ]]; then
    "${SUDO[@]}" chown -R "$(id -u):$(id -g)" "$cache_dir"
  fi
}

apt_get() {
  prepare_apt_cache
  # shellcheck disable=SC2046
  "${SUDO[@]}" apt-get $(apt_archive_opts) "$@"
  local rc=$?
  finalize_apt_cache
  return "$rc"
}

remove_preinstalled_tool() {
  local path="$1"
  if [[ -f "$path" ]]; then
    echo "    removing preinstalled tool: $path"
    "${SUDO[@]}" rm -f "$path"
  fi
}

add_swap() {
  echo "==> runner resources (before swap)"
  nproc || true
  free -h || true
  df -h / || true

  if swapon --show 2>/dev/null | grep -q .; then
    echo "==> swap already active"
    swapon --show || true
    return 0
  fi

  echo "==> adding ${SWAP_GB}G swap at $SWAP_FILE"
  if [[ ! -f "$SWAP_FILE" ]]; then
    if ! "${SUDO[@]}" fallocate -l "${SWAP_GB}G" "$SWAP_FILE" 2>/dev/null; then
      "${SUDO[@]}" dd if=/dev/zero of="$SWAP_FILE" bs=1M count=$((SWAP_GB * 1024)) status=progress
    fi
    "${SUDO[@]}" chmod 600 "$SWAP_FILE"
    "${SUDO[@]}" mkswap "$SWAP_FILE"
  fi
  "${SUDO[@]}" swapon "$SWAP_FILE" || echo "warning: swapon failed (continuing)" >&2
}

strip_conflicting_runner_tools() {
  echo "==> removing GHA preinstalled build tools (use Ubuntu archive packages)"
  # ubuntu-26.04 images ship CMake 4.4.x here; webkit2gtk 2.52.3 needs archive cmake 4.2.x.
  for tool in cmake cpack ctest ninja ccmake; do
    remove_preinstalled_tool "/usr/local/bin/$tool"
  done
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

install_minimal_packages() {
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

  echo "==> apt-get update (no dist-upgrade)"
  apt_get update -qq

  archive_cmake="$(apt-cache madison cmake 2>/dev/null | awk '/ubuntu/ { print $3; exit }' || true)"
  archive_cmake_data="$(apt-cache madison cmake-data 2>/dev/null | awk -v want="$archive_cmake" '$3 == want { print $3; exit }' || true)"
  if [[ -z "$archive_cmake" ]]; then
    echo "error: could not resolve archive cmake version" >&2
    exit 1
  fi
  [[ -n "$archive_cmake_data" ]] || archive_cmake_data="$archive_cmake"

  echo "==> installing minimal orchestration packages + archive cmake=${archive_cmake}"
  apt_get install -y --allow-downgrades \
    "${pkgs[@]}" \
    "cmake=${archive_cmake}" \
    "cmake-data=${archive_cmake_data}"

  "${SUDO[@]}" apt-mark hold cmake cmake-data >/dev/null
}

verify_toolchain() {
  export PATH="/usr/bin:/bin:${PATH}"
  hash -r

  echo "==> toolchain after setup"
  echo "    cmake: $(command -v cmake) ($(cmake --version | head -n 1))"
  echo "    ninja: $(command -v ninja 2>/dev/null || echo missing)"
  echo "    clang: $(command -v clang 2>/dev/null || echo missing)"
  echo "    series: $(host_series)"

  if cmake --version | grep -qE 'cmake version 4\.4'; then
    echo "error: cmake 4.4.x still active after setup" >&2
    exit 1
  fi

  if [[ -n "${GITHUB_ENV:-}" && -w "${GITHUB_ENV}" ]]; then
    echo "PATH=/usr/bin:/bin:${PATH}" >>"$GITHUB_ENV"
  fi
}

main() {
  local series
  series="$(host_series)"
  if [[ -z "$series" ]]; then
    echo "error: could not detect host Ubuntu series" >&2
    exit 1
  fi

  add_swap
  strip_conflicting_runner_tools

  # shellcheck source=.github/scripts/strip-third-party-apt-sources.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/strip-third-party-apt-sources.sh"
  strip_third_party_apt_sources

  # shellcheck source=.github/scripts/normalize-runner-apt-sources.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/normalize-runner-apt-sources.sh"
  normalize_runner_apt_sources "$series"

  install_minimal_packages
  enable_deb_src
  verify_toolchain

  echo "==> runner resources (after setup)"
  free -h || true
  df -h / || true
  echo "==> setup-ci-build-env done"
}

main "$@"
