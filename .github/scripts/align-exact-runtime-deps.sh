#!/usr/bin/env bash
# After a dist-upgrade, -dev packages often Depends on an exact runtime version
# (libbz2-dev -> libbz2-1.0 (= …), libx11-dev -> libx11-6 (= …)). Apt will not
# downgrade the already-installed runtime unless that version is requested
# explicitly, so build-dep fails with "is not selected for install".
#
# Usage: align_exact_runtime_deps_for_builddep [SERIES]
#        .github/scripts/align-exact-runtime-deps.sh [SERIES]
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=()
else
  SUDO=(sudo)
fi

export DEBIAN_FRONTEND=noninteractive

# Print pkg=version (arch-qualified when apt reported one) that the solver
# refused to select. Prefer "is not selected" lines; fall back to Depends (=).
exact_pins_from_solver_log() {
  local log="$1" pins
  pins="$(
    awk '
      / is not selected for install$/ {
        for (i = 1; i <= NF; i++) {
          if ($i ~ /=/ && (i + 1) <= NF && $(i + 1) == "is") {
            print $i
          }
        }
      }
    ' "$log" | sort -u
  )"
  if [[ -n "$pins" ]]; then
    printf '%s\n' "$pins"
    return 0
  fi
  sed -n 's/.*Depends:\{0,1\} \([^ ]*\) (= \([^)]*\)).*/\1=\2/p' "$log" | sort -u
}

align_exact_runtime_deps_for_builddep() {
  local series="${1:-}"
  local -a apt_opts=()
  if [[ -n "${APT_CACHE_DIR:-}" ]]; then
    mkdir -p "$APT_CACHE_DIR/partial"
    apt_opts+=(-o "Dir::Cache::archives=$APT_CACHE_DIR")
  fi

  local round sim rc
  local -a pins=() install_opts=()
  for round in 1 2 3 4 5 6 7 8; do
    sim="$(mktemp)"
    set +e
    "${SUDO[@]}" apt-get "${apt_opts[@]}" -s build-dep -y webkit2gtk >"$sim" 2>&1
    rc=$?
    set -e
    if [[ "$rc" -eq 0 ]]; then
      echo "==> align exact deps: webkit2gtk build-dep simulation OK"
      rm -f "$sim"
      return 0
    fi

    mapfile -t pins < <(exact_pins_from_solver_log "$sim")
    if ((${#pins[@]} == 0)); then
      echo "error: align exact deps: build-dep simulation failed with no exact version pin to install" >&2
      cat "$sim" >&2
      rm -f "$sim"
      return 1
    fi

    echo "==> align exact deps: round $round installing ${pins[*]}"
    install_opts=(-y --allow-downgrades)
    if [[ -n "$series" ]]; then
      install_opts+=(-t "$series")
    fi
    if ! "${SUDO[@]}" apt-get "${apt_opts[@]}" install "${install_opts[@]}" \
      -o Dpkg::Options::=--force-downgrade "${pins[@]}"; then
      echo "==> align exact deps: retry without target release" >&2
      if ! "${SUDO[@]}" apt-get "${apt_opts[@]}" install -y --allow-downgrades \
        -o Dpkg::Options::=--force-downgrade "${pins[@]}"; then
        echo "error: align exact deps: could not install ${pins[*]}" >&2
        cat "$sim" >&2
        rm -f "$sim"
        return 1
      fi
    fi
    rm -f "$sim"
  done

  echo "error: align exact deps: build-dep still unsatisfied after $round rounds" >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  align_exact_runtime_deps_for_builddep "${1:-}"
fi
