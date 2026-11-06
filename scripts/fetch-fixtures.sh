#!/usr/bin/env bash
# One-time (or REFRESH=1) download of pretest fixtures — debian/ tree + a few WebKit paths.
#
# Usage:
#   ./scripts/fetch-fixtures.sh              # all series in .github/pinned-webkit-version
#   ./scripts/fetch-fixtures.sh plucky       # one series
#   REFRESH=1 ./scripts/fetch-fixtures.sh    # re-download even if cached
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/pinned-webkit-version.sh
source "$REPO_ROOT/scripts/lib/pinned-webkit-version.sh"
# shellcheck source=scripts/lib/debian-rules-fixture.sh
source "$REPO_ROOT/scripts/lib/debian-rules-fixture.sh"
# shellcheck source=scripts/lib/webkit-source-fixture.sh
source "$REPO_ROOT/scripts/lib/webkit-source-fixture.sh"

REFRESH="${REFRESH:-0}"
SERIES_ARG="${1:-}"

launchpad_debian_tar_url() {
  local version="$1"
  echo "https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/webkit2gtk/${version}/webkit2gtk_${version}.debian.tar.xz"
}

launchpad_orig_tar_url() {
  local version="$1"
  local upstream="${version%%-*}"
  echo "https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/webkit2gtk/${version}/webkit2gtk_${upstream}.orig.tar.xz"
}

debian_pool_debian_tar_url() {
  local version="$1"
  echo "http://deb.debian.org/debian/pool/main/w/webkit2gtk/webkit2gtk_${version}.debian.tar.xz"
  echo "http://deb.debian.org/debian-security/pool/updates/main/w/webkit2gtk/webkit2gtk_${version}.debian.tar.xz"
}

debian_pool_orig_tar_url() {
  local version="$1"
  local upstream="${version%%-*}"
  echo "http://deb.debian.org/debian/pool/main/w/webkit2gtk/webkit2gtk_${upstream}.orig.tar.xz"
  echo "http://deb.debian.org/debian-security/pool/updates/main/w/webkit2gtk/webkit2gtk_${upstream}.orig.tar.xz"
}

curl_first_url() {
  local dest="$1"
  shift
  local url
  for url in "$@"; do
    echo "==> try $url" >&2
    if curl -fsSL --globoff "$url" -o "$dest"; then
      return 0
    fi
    rm -f "$dest"
  done
  echo "error: none of the URLs could be downloaded" >&2
  return 1
}

download_debian_tar() {
  local series="$1" version="$2" dest="$3"
  if [[ "$series" == "trixie" ]]; then
    # shellcheck disable=SC2046
    curl_first_url "$dest" $(debian_pool_debian_tar_url "$version")
  else
    curl -fsSL "$(launchpad_debian_tar_url "$version")" -o "$dest"
  fi
}

download_orig_tar() {
  local series="$1" version="$2" dest="$3"
  if [[ "$series" == "trixie" ]]; then
    # shellcheck disable=SC2046
    curl_first_url "$dest" $(debian_pool_orig_tar_url "$version")
  else
    curl -fsSL "$(launchpad_orig_tar_url "$version")" -o "$dest"
  fi
}

fetch_debian_rules_fixture() {
  local series="$1" version="$2"
  local dir rules version_file url tmp
  dir="$(debian_rules_fixture_dir "$series")"
  rules="$(debian_rules_fixture_path "$series")"
  version_file="$(debian_rules_fixture_version_path "$series")"

  if [[ "$REFRESH" != "1" ]] && debian_rules_fixture_ready "$series" "$version"; then
    echo "==> debian fixture OK: $series ($version)"
    return 0
  fi

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/webkitgtk-debian-fixture.XXXXXX")"
  echo "==> fetching debian.tar for $series $version"
  download_debian_tar "$series" "$version" "$tmp/debian.tar.xz"
  mkdir -p "$dir"
  rm -rf "$dir/debian"
  tar -xJf "$tmp/debian.tar.xz" -C "$dir"
  echo "$version" >"$version_file"
  rm -rf "$tmp"
  echo "==> wrote debian fixture under $dir/debian"
}

fetch_webkit_source_fixture() {
  local series="$1" version="$2"
  local dir version_file url tmp path
  dir="$(webkit_source_fixture_dir "$series")"
  version_file="$(webkit_source_fixture_version_path "$series")"

  if [[ "$REFRESH" != "1" ]] && webkit_source_fixture_ready "$series" "$version"; then
    echo "==> webkit source fixture OK: $series ($version)"
    return 0
  fi

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/webkitgtk-orig-fixture.XXXXXX")"
  echo "==> fetching orig.tar for $series $version (extract selected paths only)"
  download_orig_tar "$series" "$version" "$tmp/orig.tar.xz"

  rm -rf "$dir"
  mkdir -p "$dir"
  top="$(tar -tJf "$tmp/orig.tar.xz" | sed -n '1p' | cut -d/ -f1)"
  args=()
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    args+=("${top}/${path}")
  done < <(webkit_source_fixture_paths)
  tar -xJf "$tmp/orig.tar.xz" -C "$dir" --strip-components=1 "${args[@]}"

  echo "$version" >"$version_file"
  rm -rf "$tmp"
  echo "==> wrote webkit source fixture under $dir"
}

series_list() {
  if [[ -n "$SERIES_ARG" ]]; then
    echo "$SERIES_ARG"
    return 0
  fi
  awk -F= '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    { print $1 }
  ' "$REPO_ROOT/.github/pinned-webkit-version"
}

main() {
  local series version
  while IFS= read -r series; do
    [[ -n "$series" ]] || continue
    version="$(read_pinned_webkit_version "$series")"
    echo "==> fixtures series=$series version=$version"
    fetch_debian_rules_fixture "$series" "$version"
    fetch_webkit_source_fixture "$series" "$version"
  done < <(series_list)
}

main
