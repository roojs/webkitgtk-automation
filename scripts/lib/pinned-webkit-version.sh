#!/usr/bin/env bash
# Read/write .github/pinned-webkit-version for a SERIES.
# Updated automatically by monitor-upstream-build.sh to match archive upstream.

# One Debian version (optional epoch, upstream, optional revision). Versions end
# up in the pin file, apt requests, file names and git tags, so anything else
# (slashes, whitespace, several versions) is refused.
valid_webkit_version() {
  local version="$1"
  [[ "$version" =~ ^([0-9]+:)?[0-9][A-Za-z0-9.+~-]*$ && "$version" != *- ]] || return 1
  if command -v dpkg >/dev/null 2>&1; then
    dpkg --validate-version "$version" >/dev/null 2>&1 || return 1
  fi
}

require_valid_webkit_version() {
  local version="$1" context="${2:-webkit2gtk}"
  if ! valid_webkit_version "$version"; then
    echo "error: $context: not a single Debian version: $(printf '%q' "$version")" >&2
    return 1
  fi
}

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
        require_valid_webkit_version "$version" "pinned version for series=$series in $file" || return 1
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
  require_valid_webkit_version "$version" "refusing to pin series=$series" || return 1
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
