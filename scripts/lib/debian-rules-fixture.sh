#!/usr/bin/env bash
# Local cache of stock debian/rules per series (pretest; no WebKit compile).
set -euo pipefail

debian_rules_fixtures_root() {
  local root="${DEBIAN_RULES_FIXTURES_ROOT:-}"
  if [[ -z "$root" ]]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/fixtures/debian-rules"
  fi
  echo "$root"
}

debian_rules_fixture_dir() {
  echo "$(debian_rules_fixtures_root)/$1"
}

debian_rules_fixture_path() {
  echo "$(debian_rules_fixture_dir "$1")/debian/rules"
}

debian_rules_fixture_version_path() {
  echo "$(debian_rules_fixture_dir "$1")/version"
}

debian_rules_fixture_ready() {
  local series="$1" pinned="${2:-}"
  local rules version_file stored
  rules="$(debian_rules_fixture_path "$series")"
  version_file="$(debian_rules_fixture_version_path "$series")"
  [[ -s "$rules" && -f "$version_file" ]] || return 1
  if [[ -n "$pinned" ]]; then
    stored="$(tr -d '[:space:]' <"$version_file")"
    [[ "$stored" == "$pinned" ]] || return 1
  fi
}

copy_debian_rules_fixture() {
  local series="$1" dest="$2"
  local rules
  rules="$(debian_rules_fixture_path "$series")"
  [[ -s "$rules" ]] || {
    echo "error: missing debian/rules fixture for series=$series ($rules)" >&2
    return 1
  }
  mkdir -p "$(dirname "$dest")"
  cp -a "$rules" "$dest"
}
