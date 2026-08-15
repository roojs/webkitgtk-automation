#!/usr/bin/env bash
# Parse .github/series-registry for layout and patch file per Ubuntu series.

series_registry_file() {
  if [[ -n "${SERIES_REGISTRY_FILE:-}" ]]; then
    echo "$SERIES_REGISTRY_FILE"
    return 0
  fi
  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  echo "$root/.github/series-registry"
}

series_registry_entry() {
  local series="$1" file line key layout patch
  file="$(series_registry_file)"
  if [[ ! -f "$file" ]]; then
    echo "error: missing series registry: $file" >&2
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] || continue
    key="${line%%=*}"
    if [[ "$key" != "$series" ]]; then
      continue
    fi
    layout="${line#*=}"
    patch="${layout#*:}"
    layout="${layout%%:*}"
    if [[ -z "$layout" || -z "$patch" ]]; then
      echo "error: invalid registry entry for series=$series: $line" >&2
      return 1
    fi
    echo "$layout $patch"
    return 0
  done <"$file"
  echo "error: series=$series not in $(series_registry_file)" >&2
  return 1
}

series_layout() {
  local series="$1" entry
  entry="$(series_registry_entry "$series")" || return 1
  echo "${entry%% *}"
}

patch_file_for_series() {
  local series="$1" patch_name root
  patch_name="$(series_registry_entry "$series" | awk '{print $2}')" || return 1
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  echo "$root/patches/$patch_name"
}

series_registered() {
  series_registry_entry "$1" >/dev/null 2>&1
}

build_release_tag() {
  local series="$1" suffix="${2:-}"
  if [[ -n "$suffix" ]]; then
    echo "build-${series}-${suffix}"
    return 0
  fi
  echo "build-${series}-$(date +%Y%m%d)"
}
