#!/usr/bin/env bash
# Remove GitHub Actions runner third-party apt sources (Microsoft, etc.).
# WebKit packaging must use Ubuntu archive mirrors only — not packages.microsoft.com.
#
# Can be sourced (defines strip_third_party_apt_sources) or executed directly.
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=()
else
  SUDO=(sudo)
fi

export DEBIAN_FRONTEND=noninteractive

strip_third_party_apt_sources() {
  echo "==> stripping third-party apt sources (keep Ubuntu archive only)"
  local f base
  shopt -s nullglob
  for f in /etc/apt/sources.list.d/*; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f")"
    case "$base" in
      microsoft*.list|microsoft*.sources|azure-cli*.list|azure-cli*.sources|*microsoft*)
        echo "    removing $f"
        "${SUDO[@]}" rm -f "$f"
        ;;
    esac
    if grep -qE 'packages\.microsoft\.com|repos\.azure\.com' "$f" 2>/dev/null; then
      echo "    removing (microsoft/azure repo): $f"
      "${SUDO[@]}" rm -f "$f"
    fi
  done
  shopt -u nullglob

  if [[ -f /etc/apt/sources.list ]] \
    && grep -qE 'packages\.microsoft\.com|repos\.azure\.com' /etc/apt/sources.list; then
    echo "    filtering microsoft/azure lines from /etc/apt/sources.list"
    "${SUDO[@]}" sed -i \
      '/packages\.microsoft\.com/d;/repos\.azure\.com/d' \
      /etc/apt/sources.list
  fi

  local -a purge_pkgs=(azure-cli microsoft-edge-stable microsoft-edge-stable)
  local -a existing=()
  local pkg
  for pkg in "${purge_pkgs[@]}"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      existing+=("$pkg")
    fi
  done
  if [[ ${#existing[@]} -gt 0 ]]; then
    echo "    purging third-party packages: ${existing[*]}"
    "${SUDO[@]}" apt-get purge -y "${existing[@]}" || true
    "${SUDO[@]}" apt-get autoremove -y --purge || true
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  strip_third_party_apt_sources
  if command -v apt-get >/dev/null 2>&1; then
    "${SUDO[@]}" apt-get update -qq || true
  fi
  echo "==> strip-third-party-apt-sources done"
fi
