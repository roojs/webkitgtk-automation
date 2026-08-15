#!/usr/bin/env bash
# Read .github/pinned-webkit-version for a SERIES.

read_pinned_webkit_version() {
  local series="$1" file="${PINNED_WEBKIT_VERSION_FILE:-}"
  local line version

  if [[ -z "$file" ]]; then
    file="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.github/pinned-webkit-version"
  fi
  if [[ ! -f "$file" ]]; then
    echo "error: missing pinned webkit version file: $file" >&2
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] || continue
    if [[ "$line" == "${series}="* ]]; then
      version="${line#*=}"
      version="${version#"${version%%[![:space:]]*}"}"
      version="${version%"${version##*[![:space:]]}"}"
      if [[ -n "$version" ]]; then
        echo "$version"
        return 0
      fi
    fi
  done <"$file"

  echo "error: no pinned webkit2gtk version for series=$series in $file" >&2
  return 1
}
