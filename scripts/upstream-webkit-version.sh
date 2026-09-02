#!/usr/bin/env bash
# Print the newest webkit2gtk *source package* version published for SERIES
# (SERIES + updates + security). Matches apt-get source ordering.
#
# Reads Ubuntu archive main/source/Sources.gz directly — no apt metadata refresh.
# Optional UPSTREAM_SOURCES_CACHE_DIR skips re-downloading unchanged indices (HEAD).
#
# Usage: ./scripts/upstream-webkit-version.sh [SERIES]
#
# Env:
#   ARCHIVE_BASE                 archive root (default: http://archive.ubuntu.com/ubuntu)
#   PACKAGE                      source package name (default: webkit2gtk)
#   UPSTREAM_SOURCES_CACHE_DIR   optional cache dir for index Last-Modified fingerprints
set -euo pipefail

SERIES="${1:-resolute}"
ARCHIVE_BASE="${ARCHIVE_BASE:-http://archive.ubuntu.com/ubuntu}"
PACKAGE="${PACKAGE:-webkit2gtk}"

sources_index_url() {
  local pocket="$1"
  printf '%s/dists/%s/main/source/Sources.gz' "$ARCHIVE_BASE" "$pocket"
}

cache_file_for() {
  local pocket="$1"
  printf '%s/%s-main.sources' "${UPSTREAM_SOURCES_CACHE_DIR:?}" "$pocket"
}

read_cache_entry() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  awk -F= -v key="$key" '$1 == key { print $2; found=1 } END { exit !found }' "$file"
}

write_cache_entry() {
  local file="$1" last_modified="$2" version="$3"
  mkdir -p "$(dirname "$file")"
  cat >"$file" <<EOF
last_modified=$last_modified
version=$version
EOF
}

index_last_modified() {
  local url="$1"
  curl -fsSI "$url" | awk 'tolower($1) == "last-modified:" { $1=""; sub(/^ /, ""); print; exit }'
}

versions_from_sources_gz() {
  local url="$1"
  curl -fsSL "$url" | gzip -dc \
    | awk -v pkg="$PACKAGE" '
        /^Package: / { cur = $2 }
        cur == pkg && /^Version: / { print $2 }
      '
}

version_from_index() {
  local pocket="$1"
  local url last_modified cached_lm cached_version version

  url="$(sources_index_url "$pocket")"

  if [[ -n "${UPSTREAM_SOURCES_CACHE_DIR:-}" ]]; then
    last_modified="$(index_last_modified "$url")"
    [[ -n "$last_modified" ]] || {
      echo "error: no Last-Modified header for $url" >&2
      return 1
    }
    cached_lm="$(read_cache_entry "$(cache_file_for "$pocket")" last_modified || true)"
    cached_version="$(read_cache_entry "$(cache_file_for "$pocket")" version || true)"
    if [[ "$last_modified" == "$cached_lm" && -n "$cached_version" ]]; then
      echo "$cached_version"
      return 0
    fi
    mapfile -t versions < <(versions_from_sources_gz "$url")
    if ((${#versions[@]} == 0)); then
      echo "error: $PACKAGE not found in $url" >&2
      return 1
    fi
    version="$(printf '%s\n' "${versions[@]}" | sort -V | tail -n 1)"
    write_cache_entry "$(cache_file_for "$pocket")" "$last_modified" "$version"
    echo "$version"
    return 0
  fi

  versions_from_sources_gz "$url"
}

collect_versions() {
  local pocket
  for pocket in "$SERIES" "${SERIES}-updates" "${SERIES}-security"; do
    version_from_index "$pocket" || {
      echo "error: failed to read $PACKAGE version from $(sources_index_url "$pocket")" >&2
      return 1
    }
  done
}

mapfile -t versions < <(collect_versions)

if ((${#versions[@]} == 0)); then
  echo "error: $PACKAGE not found in archive Sources for series=$SERIES" >&2
  exit 1
fi

printf '%s\n' "${versions[@]}" | sort -V | tail -n 1
