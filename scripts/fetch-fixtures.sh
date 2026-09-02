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

  url="$(launchpad_debian_tar_url "$version")"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/webkitgtk-debian-fixture.XXXXXX")"
  echo "==> fetching debian.tar only: $url"
  curl -fsSL "$url" -o "$tmp/debian.tar.xz"
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

  url="$(launchpad_orig_tar_url "$version")"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/webkitgtk-orig-fixture.XXXXXX")"
  echo "==> fetching orig.tar (extract selected paths only): $url"
  curl -fsSL "$url" -o "$tmp/orig.tar.xz"

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
