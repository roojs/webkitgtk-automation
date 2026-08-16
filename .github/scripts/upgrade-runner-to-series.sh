#!/usr/bin/env bash
# Upgrade a GitHub Actions runner from its base Ubuntu series to TARGET_SERIES.
#
# Used by build-plucky.yml / build-questing.yml: ubuntu-24.04 (noble) → 25.04/25.10.
#
# GHA noble images ship noble-updates packages (mesa, libdrm) that are newer than
# plucky. dist-upgrade will not replace those. So:
#   1. Purge runner extras that fight a series upgrade
#   2. Reset apt to stock BASE_SERIES *release* (no -updates/-security) and
#      downgrade everything back to baseline 24.04
#   3. Point apt at the target series and dist-upgrade forward
#
# Env:
#   TARGET_SERIES   Required Ubuntu codename (e.g. plucky)
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

# Packages that fight a series upgrade or are GHA extras we do not compile with.
purge_runner_extras() {
  echo "==> purging runner extras (not needed for webkit2gtk)"
  local -a pkgs=(
    sosreport sos ubuntu-server
    docker-ce docker-ce-cli docker-ce-rootless-extras docker-buildx-plugin docker-compose-plugin
    containerd.io moby-engine moby-cli moby-buildx moby-compose
    kubectl
    mysql-server mysql-server-8.0 mysql-client mysql-client-8.0 mysql-server-core-8.0 mysql-client-core-8.0
    azure-cli
    google-chrome-stable microsoft-edge-stable firefox
    powershell
  )
  local -a existing=()
  local pkg
  for pkg in "${pkgs[@]}"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      existing+=("$pkg")
    fi
  done
  if [[ ${#existing[@]} -eq 0 ]]; then
    echo "    none installed"
    return 0
  fi
  echo "    purging: ${existing[*]}"
  apt_get purge -y "${existing[@]}" || true
  apt_get autoremove -y --purge || true
}

unhold_all_packages() {
  local held
  held="$(apt-mark showhold 2>/dev/null || true)"
  if [[ -z "$held" ]]; then
    return 0
  fi
  echo "==> apt-mark unhold: ${held//$'\n'/ }"
  # shellcheck disable=SC2086
  "${SUDO[@]}" apt-mark unhold $held >/dev/null || true
}

# Purging i386/multilib runtimes can leave /lib32 -> usr/lib32 dangling.
# plucky base-files then refuses to unpack (Debian UsrMerge check).
repair_usrmerge_compat_links() {
  echo "==> repairing dangling usr-merge compat links"
  local link dest target
  local repaired=0
  for link in /lib32 /lib64 /libx32; do
    if [[ -L "$link" && ! -e "$link" ]]; then
      dest="$(readlink "$link")"
      if [[ "$dest" == /* ]]; then
        target="$dest"
      else
        target="/$dest"
      fi
      echo "    $link -> $dest is dangling; creating $target"
      "${SUDO[@]}" mkdir -p "$target"
      repaired=1
    fi
  done
  if [[ "$repaired" -eq 0 ]]; then
    echo "    none"
  fi
}

# Updates-only leftovers (gcc-14, mesa from noble-updates) are safe to drop.
# Never purge essential runtimes — a failed suite pin is not a reason to
# remove libgcc-s1 / libstdc++6.
safe_to_purge_sru_leftover() {
  local pkg="$1"
  case "$pkg" in
    libgcc-s1|libstdc++6|libc6|libc-bin|sed|sudo|bash|dash|coreutils|dpkg|apt)
      return 1
      ;;
    mesa-*|libgl*|libgbm*|libdrm*|libllvm*|lib32*|gcc-14*|g++-14*|cpp-14*|gfortran-14*|libgcc-14-dev|libstdc++-14-dev|libgfortran-14-dev|packages-microsoft-prod|azure-vm-utils)
      return 0
      ;;
  esac
  return 1
}

# Noble-updates SRU versions contain "24.04" (e.g. 2.4.125-1ubuntu0.1~24.04.2).
# Stock noble *release* packages do not. After pointing apt at noble release,
# force those leftovers onto the suite version. Purge only updates-only extras.
downgrade_sru_leftovers_to_base_release() {
  local pkg ver
  local -a leftover=()
  echo "==> downgrading leftover *24.04* packages to stock $BASE_SERIES release"
  while read -r pkg ver; do
    [[ -n "$pkg" && -n "$ver" ]] || continue
    [[ "$ver" == *24.04* ]] || continue
    leftover+=("$pkg")
  done < <(dpkg-query -W -f '${Package} ${Version}\n' 2>/dev/null || true)

  if [[ ${#leftover[@]} -eq 0 ]]; then
    echo "    none"
    repair_usrmerge_compat_links
    return 0
  fi

  echo "    leftover: ${leftover[*]}"
  local -a suite_pins=()
  local -a purge=()
  local -a keep=()
  for pkg in "${leftover[@]}"; do
    if apt-cache show "$pkg" >/dev/null 2>&1; then
      suite_pins+=("${pkg}/${BASE_SERIES}")
    elif safe_to_purge_sru_leftover "$pkg"; then
      purge+=("$pkg")
    else
      keep+=("$pkg")
    fi
  done

  if [[ ${#suite_pins[@]} -gt 0 ]]; then
    echo "    installing from ${BASE_SERIES}: ${suite_pins[*]}"
    if ! apt_get install -y --allow-downgrades "${suite_pins[@]}"; then
      echo "    batch suite pin failed; retrying per package"
      for pkg in "${suite_pins[@]}"; do
        if ! apt_get install -y --allow-downgrades "$pkg"; then
          pkg="${pkg%/*}"
          if safe_to_purge_sru_leftover "$pkg"; then
            purge+=("$pkg")
          else
            keep+=("$pkg")
          fi
        fi
      done
    fi
  fi

  if [[ ${#purge[@]} -gt 0 ]]; then
    echo "    purging updates-only leftovers: ${purge[*]}"
    apt_get purge -y "${purge[@]}" || true
  fi
  if [[ ${#keep[@]} -gt 0 ]]; then
    echo "    leaving installed (not safe to purge): ${keep[*]}"
  fi
  repair_usrmerge_compat_links
}

assert_no_sru_canaries() {
  local when="$1"
  local pkg ver
  for pkg in libdrm2 libgl1-mesa-dri mesa-libgallium; do
    ver="$(dpkg-query -W -f '${Version}' "$pkg" 2>/dev/null || true)"
    [[ -n "$ver" ]] || continue
    if [[ "$ver" == *24.04* ]]; then
      echo "error: $pkg still $ver after $when (build-dep will fail)" >&2
      exit 1
    fi
  done
}

# shellcheck source=.github/scripts/normalize-runner-apt-sources.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/normalize-runner-apt-sources.sh"

# Noble-updates can ship higher versions than an older target (plucky mesa
# 25.0.7 vs noble 25.2.8). dist-upgrade will not replace those without this.
apt_dist_upgrade() {
  local rc=0
  set +e
  apt_get \
    -o Acquire::AllowReleaseInfoChange=true \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    dist-upgrade -y --allow-downgrades
  rc=$?
  "${SUDO[@]}" dpkg --configure -a || true
  set -e

  if [[ "$rc" -ne 0 ]]; then
    if "${SUDO[@]}" dpkg --audit 2>/dev/null | grep -q .; then
      echo "==> dist-upgrade left broken packages; dropping sos/ubuntu-server leftovers"
      apt_get purge -y sosreport sos ubuntu-server || true
      "${SUDO[@]}" dpkg --configure -a || true
    fi
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
  unhold_all_packages

  write_ubuntu_archive_sources "$BASE_SERIES"
  echo "==> cleanup: update and purge extras on $BASE_SERIES"
  apt_get update -qq
  disable_needrestart
  purge_runner_extras
  repair_usrmerge_compat_links

  echo "==> reset: stock $BASE_SERIES release (no -updates/-security), allow downgrades"
  write_ubuntu_archive_sources "$BASE_SERIES" release
  apt_get update -qq
  apt_dist_upgrade
  apt_get install -y --fix-broken --allow-downgrades || true
  downgrade_sru_leftovers_to_base_release
  apt_get autoremove -y --purge || true
  assert_no_sru_canaries "stock $BASE_SERIES release reset"

  echo "==> upgrade: dist-upgrade to $TARGET_SERIES (archive.ubuntu.com, allow downgrades)"
  write_ubuntu_archive_sources "$TARGET_SERIES"
  apt_get update -qq
  repair_usrmerge_compat_links
  apt_dist_upgrade
  if [[ "$(host_series)" != "$TARGET_SERIES" ]]; then
    echo "==> still on $(host_series); repairing usr-merge links and retrying $TARGET_SERIES upgrade"
    repair_usrmerge_compat_links
    apt_dist_upgrade
  fi
  apt_get install -y --fix-broken --allow-downgrades || true
  apt_get autoremove -y --purge || true
  apt_get autoclean -y || true
  assert_no_sru_canaries "$TARGET_SERIES upgrade"

  local upgraded_series
  upgraded_series="$(host_series)"
  echo "==> host series after upgrade: ${upgraded_series:-unknown}"
  if [[ "$upgraded_series" != "$TARGET_SERIES" ]]; then
    echo "error: expected VERSION_CODENAME=$TARGET_SERIES after dist-upgrade, got ${upgraded_series:-<empty>}" >&2
    exit 1
  fi

  setup_post_upgrade_build_env

  echo "==> upgrade-runner-to-series done ($(host_series))"
}

main "$@"
