#!/usr/bin/env bash
# Return 0 when the libwebkitgtk .so behind PKG-CONFIG module $1 was built with
# WebDriver mouse/keyboard interaction code (SimulatedInputDispatcher present).
#
# Usage: ./scripts/meson/check-webkit-interactions.sh webkitgtk-6.0
#        ./scripts/meson/check-webkit-interactions.sh webkitgtk-6.0-webdriver
set -euo pipefail

pc="${1:?pkg-config module name required}"

if ! pkg-config --exists "$pc"; then
  exit 1
fi

libdir="$(pkg-config --variable=libdir "$pc")"
[[ -n "$libdir" && -d "$libdir" ]] || exit 1

resolve_so() {
  local flag base candidates
  # pkg-config --libs-only-l prints one space-separated line; split to flags.
  while read -r flag; do
    [[ -z "$flag" ]] && continue
    case "$flag" in
      -l:*)
        if [[ -e "$libdir/${flag#-l:}" ]]; then
          echo "$libdir/${flag#-l:}"
          return 0
        fi
        ;;
      -l*)
        base="${flag#-l}"
        for candidates in \
          "$libdir/lib${base}.so" \
          "$libdir/lib${base}.so."*; do
          if [[ -e "$candidates" ]]; then
            echo "$candidates"
            return 0
          fi
        done
        ;;
    esac
  done
  return 1
}

so="$(pkg-config --libs-only-l "$pc" | tr ' ' '\n' | resolve_so)" || exit 1

# SimulatedInputDispatcher is C++ and not exported in the dynamic symbol table, so
# nm -D misses it. grep -a still sees the type/file names in the binary when
# interactions were linked in. When ENABLE_WEBDRIVER_*_INTERACTIONS are off
# (Ubuntu stock GTK4), those strings are absent.
# Prefer grep -a over `strings | grep` so pipefail does not treat SIGPIPE from
# early grep exit as failure.
if grep -aFq 'SimulatedInputDispatcher' "$so"; then
  exit 0
fi

exit 1
