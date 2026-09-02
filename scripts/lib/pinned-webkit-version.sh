#!/usr/bin/env bash
# Read/write .github/pinned-webkit-version for a SERIES.
# Updated automatically by monitor-upstream-build.sh to match archive upstream.

pinned_webkit_version_file() {
  if [[ -n "${PINNED_WEBKIT_VERSION_FILE:-}" ]]; then
    echo "$PINNED_WEBKIT_VERSION_FILE"
    return 0
  fi
  echo "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.github/pinned-webkit-version"
}

read_pinned_webkit_version() {
  local series="$1" file line version
  file="$(pinned_webkit_version_file)"
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

write_pinned_webkit_version() {
  local series="$1" version="$2" file tmp found=0
  file="$(pinned_webkit_version_file)"
  [[ -f "$file" ]] || {
    echo "error: missing pinned webkit version file: $file" >&2
    return 1
  }
  tmp="$(mktemp "${TMPDIR:-/tmp}/pinned-webkit-version.XXXXXX")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "${line//[[:space:]]/}" ]]; then
      printf '%s\n' "$line"
      continue
    fi
    if [[ "$line" == "${series}="* ]]; then
      printf '%s=%s\n' "$series" "$version"
      found=1
    else
      printf '%s\n' "$line"
    fi
  done <"$file" >"$tmp"
  if [[ "$found" -eq 0 ]]; then
    printf '%s=%s\n' "$series" "$version" >>"$tmp"
  fi
  mv "$tmp" "$file"
}
