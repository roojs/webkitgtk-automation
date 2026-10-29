#!/usr/bin/env bash
# libx11-dev pins an exact libx11-6 (= …) from release. After dist-upgrade the
# runner often has a newer SRU libx11-6, which makes apt-get build-dep fail.
#
# Usage: align_libx11_for_builddep [SERIES]
#        .github/scripts/align-libx11-for-builddep.sh [SERIES]
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=()
else
  SUDO=(sudo)
fi

export DEBIAN_FRONTEND=noninteractive

depends_libx11_6_pin_from_show() {
  sed -n 's/^Depends:.*libx11-6 (= \([^)]*\)).*/\1/p;q'
}

archive_libx11_dev_runtime_pin() {
  local series="$1" pkgz txt pin
  pkgz="$(mktemp)"
  txt="$(mktemp)"
  trap 'rm -f "$pkgz" "$txt"' RETURN
  curl -fsSL "http://archive.ubuntu.com/ubuntu/dists/${series}/main/binary-amd64/Packages.gz" \
    -o "$pkgz"
  gzip -dc "$pkgz" >"$txt"
  pin="$(
    awk '
        /^Package: / { cur = $2 }
        cur == "libx11-dev" && /^Depends: / && /libx11-6 \(= / {
          line = $0
          sub(/.*libx11-6 \(= /, "", line)
          sub(/\).*/, "", line)
          print line
          exit
        }
      ' "$txt"
  )"
  [[ -n "$pin" ]] && echo "$pin"
}

libx11_dev_runtime_pin() {
  local series="$1" pin ver
  pin="$(
    apt-cache show libx11-dev 2>/dev/null | depends_libx11_6_pin_from_show
  )"
  if [[ -n "$pin" ]]; then
    echo "$pin"
    return 0
  fi
  ver="$(
    apt-cache policy libx11-dev 2>/dev/null \
      | awk '/^[[:space:]]*Candidate:/ { print $2; exit }'
  )"
  if [[ -n "$ver" && "$ver" != "(none)" ]]; then
    pin="$(
      apt-cache show "libx11-dev=$ver" 2>/dev/null | depends_libx11_6_pin_from_show
    )"
    if [[ -n "$pin" ]]; then
      echo "$pin"
      return 0
    fi
  fi
  if [[ -n "$series" ]]; then
    archive_libx11_dev_runtime_pin "$series"
  fi
}

align_libx11_for_builddep() {
  local series="${1:-}" pin installed
  if [[ -z "$series" && -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    series="${VERSION_CODENAME:-}"
  fi

  "${SUDO[@]}" apt-get update -qq

  pin="$(libx11_dev_runtime_pin "$series")"
  if [[ -z "$pin" ]]; then
    echo "error: align libx11: could not resolve libx11-dev runtime pin (series=${series:-unknown})" >&2
    apt-cache policy libx11-6 libx11-dev 2>&1 || true
    return 1
  fi

  installed="$(dpkg-query -W -f '${Version}' libx11-6 2>/dev/null || true)"
  if [[ "$installed" == "$pin" ]]; then
    echo "==> align libx11: libx11-6 already $pin"
    return 0
  fi

  echo "==> align libx11: libx11-6 ${installed:-<none>} -> $pin (libx11-dev pin)"
  apt-cache policy libx11-6 libx11-dev 2>&1 || true

  local -a install_opts=(-y --allow-downgrades)
  if [[ -n "$series" ]]; then
    install_opts+=(-t "$series")
  fi

  if ! "${SUDO[@]}" apt-get install "${install_opts[@]}" \
    -o Dpkg::Options::=--force-downgrade \
    "libx11-6=$pin" "libx11-dev=$pin"; then
    echo "==> align libx11: retry after purge" >&2
    "${SUDO[@]}" apt-get remove -y libx11-dev libx11-6 || true
    "${SUDO[@]}" apt-get install "${install_opts[@]}" \
      -o Dpkg::Options::=--force-downgrade \
      "libx11-6=$pin" "libx11-dev=$pin"
  fi

  installed="$(dpkg-query -W -f '${Version}' libx11-6 2>/dev/null || true)"
  if [[ "$installed" != "$pin" ]]; then
    echo "error: align libx11: libx11-6 is $installed, expected $pin" >&2
    return 1
  fi
  echo "==> align libx11: OK (libx11-6=$installed)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  align_libx11_for_builddep "${1:-}"
fi
