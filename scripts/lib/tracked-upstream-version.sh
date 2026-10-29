#!/usr/bin/env bash
# Read/write .github/tracked-upstream-version and pending-upstream-version (per series).

tracked_upstream_version_file() {
  if [[ -n "${TRACKED_UPSTREAM_VERSION_FILE:-}" ]]; then
    echo "$TRACKED_UPSTREAM_VERSION_FILE"
    return 0
  fi
  echo "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.github/tracked-upstream-version"
}

pending_upstream_version_file() {
  if [[ -n "${PENDING_UPSTREAM_VERSION_FILE:-}" ]]; then
    echo "$PENDING_UPSTREAM_VERSION_FILE"
    return 0
  fi
  echo "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.github/pending-upstream-version"
}

read_series_state_value() {
  local file="$1" series="$2"
  [[ -f "$file" ]] || { echo ""; return 0; }

  local line key value legacy=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] || continue
    if [[ "$line" == *"="* ]]; then
      key="${line%%=*}"
      value="${line#*=}"
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
      if [[ "$key" == "$series" ]]; then
        echo "$value"
        return 0
      fi
    else
      legacy=1
      legacy_line="$line"
    fi
  done <"$file"

  if [[ "$legacy" == "1" && "$series" == "${MONITOR_LEGACY_SERIES:-resolute}" ]]; then
    echo "$legacy_line"
    return 0
  fi
  echo ""
}

write_series_state_value() {
  local file="$1" series="$2" value="$3" header="$4"
  local tmp found=0 line key

  tmp="$(mktemp "${TMPDIR:-/tmp}/series-state.XXXXXX")"
  if [[ -f "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "${line//[[:space:]]/}" ]]; then
        printf '%s\n' "$line"
        continue
      fi
      if [[ "$line" == *"="* ]]; then
        key="${line%%=*}"
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        if [[ "$key" == "$series" ]]; then
          printf '%s=%s\n' "$series" "$value"
          found=1
        else
          printf '%s\n' "$line"
        fi
      fi
    done <"$file" >"$tmp"
  else
    printf '%s\n' "$header" >"$tmp"
  fi

  if [[ "$found" -eq 0 ]]; then
    if [[ ! -s "$tmp" ]]; then
      printf '%s\n' "$header" >"$tmp"
    fi
    printf '%s=%s\n' "$series" "$value" >>"$tmp"
  fi
  mv "$tmp" "$file"
}

read_tracked_upstream_version() {
  read_series_state_value "$(tracked_upstream_version_file)" "$1"
}

read_pending_upstream_version() {
  read_series_state_value "$(pending_upstream_version_file)" "$1"
}

write_tracked_upstream_version() {
  write_series_state_value \
    "$(tracked_upstream_version_file)" \
    "$1" \
    "$2" \
    "# Last upstream webkit2gtk source version we successfully built and released, per series."
}

write_pending_upstream_version() {
  write_series_state_value \
    "$(pending_upstream_version_file)" \
    "$1" \
    "$2" \
    "# Upstream webkit2gtk version queued for an in-flight auto-build (empty = none)."
}

clear_pending_upstream_version() {
  write_pending_upstream_version "$1" ""
}

dpkg_version_lt() {
  local a="$1" b="$2"
  [[ -n "$a" && -n "$b" ]] || return 1
  dpkg --compare-versions "$a" lt "$b"
}

monitor_build_series_list() {
  if [[ -n "${MONITOR_BUILD_SERIES:-}" ]]; then
    echo "$MONITOR_BUILD_SERIES"
    return 0
  fi
  echo "plucky questing resolute"
}

monitor_pin_sync_series_list() {
  if [[ -n "${MONITOR_PIN_SYNC_SERIES:-}" ]]; then
    echo "$MONITOR_PIN_SYNC_SERIES"
    return 0
  fi
  echo "noble plucky questing resolute"
}
