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
#   UPSTREAM_CURL_RETRIES        curl retry count (default: 4)
set -euo pipefail

SERIES="${1:-resolute}"
ARCHIVE_BASE="${ARCHIVE_BASE:-http://archive.ubuntu.com/ubuntu}"
PACKAGE="${PACKAGE:-webkit2gtk}"
UPSTREAM_CURL_RETRIES="${UPSTREAM_CURL_RETRIES:-4}"

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

curl_retry() {
  local attempt=1 max="$UPSTREAM_CURL_RETRIES"
  while [[ "$attempt" -le "$max" ]]; do
    if "$@"; then
      return 0
    fi
    if [[ "$attempt" -eq "$max" ]]; then
      return 1
    fi
    sleep $((attempt * 2))
    attempt=$((attempt + 1))
  done
}

index_last_modified() {
  local url="$1"
  curl_retry curl -fsSI "$url" | awk 'tolower($1) == "last-modified:" { $1=""; sub(/^ /, ""); print; exit }'
}

versions_from_sources_gz() {
  local url="$1"
  curl_retry curl -fsSL "$url" | gzip -dc \
    | awk -v pkg="$PACKAGE" '
        /^Package: / { cur = $2 }
        cur == pkg && /^Version: / { print $2 }
      '
}

newest_version_from_url() {
  local url="$1"
  local -a versions
  mapfile -t versions < <(versions_from_sources_gz "$url")
  if ((${#versions[@]} == 0)); then
    echo "error: $PACKAGE not found in $url" >&2
    return 1
  fi
  printf '%s\n' "${versions[@]}" | sort -V | tail -n 1
}

version_from_index() {
  local pocket="$1"
  local url last_modified cached_lm cached_version version cache_path

  url="$(sources_index_url "$pocket")"
  cache_path=""
  if [[ -n "${UPSTREAM_SOURCES_CACHE_DIR:-}" ]]; then
    cache_path="$(cache_file_for "$pocket")"
  fi

  if [[ -n "$cache_path" ]]; then
    last_modified="$(index_last_modified "$url" || true)"
    cached_lm="$(read_cache_entry "$cache_path" last_modified || true)"
    cached_version="$(read_cache_entry "$cache_path" version || true)"

    if [[ -z "$last_modified" ]]; then
      if [[ -n "$cached_version" ]]; then
        echo "warning: using cached $PACKAGE version for $pocket (HEAD failed)" >&2
        echo "$cached_version"
        return 0
      fi
      echo "error: no Last-Modified header for $url and no cache entry" >&2
      return 1
    fi

    if [[ "$last_modified" == "$cached_lm" && -n "$cached_version" ]]; then
      echo "$cached_version"
      return 0
    fi

    version="$(newest_version_from_url "$url")"
    write_cache_entry "$cache_path" "$last_modified" "$version"
    echo "$version"
    return 0
  fi

  newest_version_from_url "$url"
}

collect_versions() {
  local pocket version
  for pocket in "$SERIES" "${SERIES}-updates" "${SERIES}-security"; do
    if ! version="$(version_from_index "$pocket")"; then
      if [[ "$pocket" == "$SERIES" ]]; then
        echo "warning: skipping base pocket $pocket (using updates/security only)" >&2
        continue
      fi
      echo "error: failed to read $PACKAGE version from $(sources_index_url "$pocket")" >&2
      return 1
    fi
    echo "$version"
  done
}

mapfile -t versions < <(collect_versions)

if ((${#versions[@]} == 0)); then
  echo "error: $PACKAGE not found in archive Sources for series=$SERIES" >&2
  exit 1
fi

printf '%s\n' "${versions[@]}" | sort -V | tail -n 1
