#!/usr/bin/env bash
# Layout-based spot checks for patched debian/rules (pretest / script tests).

packaging_layout() {
  local series="$1"
  # shellcheck source=scripts/lib/series-registry.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/series-registry.sh"
  series_layout "$series"
}

assert_patched_rules_markers() {
  local rules="$1" layout="$2"
  if [[ ! -f "$rules" ]]; then
    echo "error: missing debian/rules: $rules" >&2
    return 1
  fi

  grep -q 'ENABLE_WEBDRIVER_GTK4 = -DENABLE_WEBDRIVER=ON' "$rules" \
    || { echo "error: ENABLE_WEBDRIVER_GTK4 marker missing" >&2; return 1; }
  grep -q 'fuse-ld=gold' "$rules" \
    || { echo "error: gold linker marker missing" >&2; return 1; }
  ! grep -q 'reduce-memory-overheads' "$rules" \
    || { echo "error: reduce-memory-overheads should be removed" >&2; return 1; }
  ! grep -q 'fuse-ld=lld' "$rules" \
    || { echo "error: lld linker must not be used" >&2; return 1; }
  grep -q -- '-Nlibwebkitgtk-doc' "$rules" \
    || { echo "error: -Nlibwebkitgtk-doc skip missing" >&2; return 1; }

  case "$layout" in
    soup3-gtk4)
      grep -q 'ENABLE_SOUP3=NO' "$rules" \
        || { echo "error: soup3-gtk4 layout expects ENABLE_SOUP3=NO" >&2; return 1; }
      grep -q 'ENABLE_GTK4=YES' "$rules" \
        || { echo "error: soup3-gtk4 layout expects ENABLE_GTK4=YES" >&2; return 1; }
      grep -q -- '-Nlibjavascriptcoregtk-bin' "$rules" \
        || { echo "error: soup3-gtk4 layout must skip libjavascriptcoregtk-bin (4.1 jsc)" >&2; return 1; }
      grep -q -- '-Nwebkitgtk-webdriver' "$rules" \
        || { echo "error: soup3-gtk4 layout must skip webkitgtk-webdriver" >&2; return 1; }
      if grep -q '^ENABLE_GTK3=' "$rules"; then
        echo "error: soup3-gtk4 layout must not use ENABLE_GTK3 toggles" >&2
        return 1
      fi
      ;;
    gtk3-gtk4)
      grep -q 'ENABLE_GTK3=NO' "$rules" \
        || { echo "error: gtk3-gtk4 layout expects ENABLE_GTK3=NO" >&2; return 1; }
      grep -q 'ENABLE_GTK4=YES' "$rules" \
        || { echo "error: gtk3-gtk4 layout expects ENABLE_GTK4=YES" >&2; return 1; }
      if grep -q '^ENABLE_SOUP3=' "$rules"; then
        echo "error: gtk3-gtk4 layout must not use ENABLE_SOUP toggles" >&2
        return 1
      fi
      ! grep -q -- '-Nlibwebkit2gtk-4.1-0' "$rules" \
        || { echo "error: patched rules must not -N gtk3 packages when ENABLE_GTK3=NO" >&2; return 1; }
      ;;
    *)
      echo "error: unknown packaging layout: $layout" >&2
      return 1
      ;;
  esac
}

assert_patched_control_gtk4_only() {
  local control="$1" layout="$2"
  [[ -f "$control" ]] || { echo "error: missing debian/control" >&2; return 1; }
  grep -q '^Package: libwebkitgtk-6.0-4$' "$control" \
    || { echo "error: gtk4 runtime package missing from control" >&2; return 1; }

  case "$layout" in
    soup3-gtk4)
      if grep -q '^Package: libwebkit2gtk-4.1' "$control"; then
        echo "error: soup3 binary packages should be absent from gtk4-only control" >&2
        return 1
      fi
      ;;
    gtk3-gtk4)
      if grep -q '^Package: libwebkit2gtk-4.1' "$control"; then
        echo "error: gtk3 binary packages should be absent from regenerated control" >&2
        return 1
      fi
      ;;
  esac
}
