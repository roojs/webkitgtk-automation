#!/usr/bin/env bash
# Local cache of stock debian/ tree per series (pretest; no WebKit compile).
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

debian_fixture_required_paths() {
  cat <<'EOF'
debian/rules
debian/changelog
debian/control.in
debian/control-common.in
debian/control-transitional.in
EOF
}

debian_rules_fixture_ready() {
  local series="$1" pinned="${2:-}"
  local base version_file stored path
  base="$(debian_rules_fixture_dir "$series")"
  version_file="$(debian_rules_fixture_version_path "$series")"
  [[ -f "$version_file" ]] || return 1
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    [[ -s "$base/$path" ]] || return 1
  done < <(debian_fixture_required_paths)
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

copy_debian_fixture() {
  local series="$1" dest_parent="$2"
  local src
  src="$(debian_rules_fixture_dir "$series")/debian"
  [[ -d "$src" ]] || {
    echo "error: missing debian fixture for series=$series ($src)" >&2
    return 1
  }
  if ! debian_rules_fixture_ready "$series"; then
    echo "error: incomplete debian fixture for series=$series (run ./scripts/fetch-fixtures.sh $series)" >&2
    return 1
  fi
  mkdir -p "$dest_parent"
  rm -rf "$dest_parent/debian"
  cp -a "$src" "$dest_parent/debian"
}
