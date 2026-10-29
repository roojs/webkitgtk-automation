#!/usr/bin/env bash
# libx11-dev pins an exact libx11-6 (= …) from release. After dist-upgrade the
# runner often has a newer SRU libx11-6, which makes apt-get build-dep fail.
#
# Usage: align_libx11_for_builddep  (function when sourced)
#        .github/scripts/align-libx11-for-builddep.sh  (standalone)
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=()
else
  SUDO=(sudo)
fi

export DEBIAN_FRONTEND=noninteractive

align_libx11_for_builddep() {
  local pin installed
  pin="$(
    apt-cache show libx11-dev 2>/dev/null \
      | sed -n 's/^Depends:.*libx11-6 (= \([^)]*\)).*/\1/p;q'
  )"
  if [[ -z "$pin" ]]; then
    echo "==> align libx11: no libx11-dev candidate (skip)"
    return 0
  fi

  installed="$(dpkg-query -W -f '${Version}' libx11-6 2>/dev/null || true)"
  if [[ "$installed" == "$pin" ]]; then
    echo "==> align libx11: libx11-6 already $pin"
    return 0
  fi

  echo "==> align libx11: libx11-6 ${installed:-<none>} -> $pin (match libx11-dev)"
  if ! "${SUDO[@]}" apt-get install -y --allow-downgrades \
    "libx11-6=$pin" "libx11-dev=$pin"; then
    echo "==> align libx11: retry after purge" >&2
    "${SUDO[@]}" apt-get remove -y libx11-dev libx11-6 || true
    "${SUDO[@]}" apt-get install -y --allow-downgrades \
      "libx11-6=$pin" "libx11-dev=$pin"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  align_libx11_for_builddep
fi
