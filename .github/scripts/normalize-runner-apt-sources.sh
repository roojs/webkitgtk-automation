#!/usr/bin/env bash
# Replace GitHub Actions runner apt sources with plain archive.ubuntu.com deb822.
#
# GHA images use mirror+file:/etc/apt/apt-mirrors.txt (azure.archive.ubuntu.com)
# and assorted third-party .list files. WebKit packaging needs predictable Ubuntu
# archive sources with deb-src enabled.
#
# Can be sourced (defines normalize_runner_apt_sources) or executed:
#   SERIES=resolute .github/scripts/normalize-runner-apt-sources.sh
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=()
else
  SUDO=(sudo)
fi

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
# Managed by webkitgtk-automation normalize-runner-apt-sources.sh
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

normalize_runner_apt_sources() {
  local series="${1:?series codename required}"
  remove_runner_apt_sources
  write_ubuntu_archive_sources "$series"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  series="${SERIES:-}"
  if [[ -z "$series" && -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    series="${VERSION_CODENAME:-}"
  fi
  if [[ -z "$series" ]]; then
    echo "error: set SERIES or run on a host with VERSION_CODENAME" >&2
    exit 1
  fi
  normalize_runner_apt_sources "$series"
  echo "==> normalize-runner-apt-sources done ($series)"
fi
