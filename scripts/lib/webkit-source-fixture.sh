#!/usr/bin/env bash
# Minimal WebKit source tree for patch dry-runs (a few files only).
set -euo pipefail

webkit_source_fixtures_root() {
  local root="${WEBKIT_SOURCE_FIXTURES_ROOT:-}"
  if [[ -z "$root" ]]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/fixtures/webkit-source"
  fi
  echo "$root"
}

webkit_source_fixture_dir() {
  echo "$(webkit_source_fixtures_root)/$1"
}

webkit_source_fixture_version_path() {
  echo "$(webkit_source_fixture_dir "$1")/version"
}

webkit_source_fixture_paths() {
  cat <<'EOF'
Source/cmake/OptionsGTK.cmake
Source/WebKit/PlatformGTK.cmake
Source/WebCore/Headers.cmake
Source/WebCore/Modules/webdriver/NavigatorWebDriver.cpp
Source/WebCore/Modules/webdriver/Navigator+WebDriver.idl
Source/WebCore/page/SettingsBase.h
Source/WebKit/UIProcess/API/glib/WebKitSettings.cpp
Source/WebKit/UIProcess/API/glib/WebKitSettings.h.in
Source/WTF/Scripts/Preferences/UnifiedWebPreferences.yaml
EOF
}

webkit_source_fixture_ready() {
  local series="$1" pinned="${2:-}" path version_file stored
  version_file="$(webkit_source_fixture_version_path "$series")"
  [[ -f "$version_file" ]] || return 1
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    [[ -f "$(webkit_source_fixture_dir "$series")/$path" ]] || return 1
  done < <(webkit_source_fixture_paths)
  if [[ -n "$pinned" ]]; then
    stored="$(tr -d '[:space:]' <"$version_file")"
    [[ "$stored" == "$pinned" ]] || return 1
  fi
}
