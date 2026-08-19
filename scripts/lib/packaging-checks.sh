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
  grep -q 'WEBKITGTK_VARIANT_SUFFIX = -webdriver' "$rules" \
    || { echo "error: WEBKITGTK_VARIANT_SUFFIX marker missing" >&2; return 1; }
  grep -q 'WEBKIT_DH_RENAME_WEBDRIVER' "$rules" \
    || { echo "error: WEBKIT_DH_RENAME_WEBDRIVER marker missing" >&2; return 1; }
  grep -q 'rm -rf debian/tmp/usr/include/webkitgtk-6.0' "$rules" \
    || { echo "error: thin -dev header cleanup missing from override_dh_auto_install" >&2; return 1; }
  grep -q 'LC_MESSAGES/WebKitGTK-6.0.mo' "$rules" \
    || { echo "error: locale .mo cleanup missing from override_dh_auto_install" >&2; return 1; }
  grep -Fq 'libwebkitgtk-6.0-webdriver4.install' "$rules" \
    || { echo "error: locale lines must be stripped from webdriver4.install" >&2; return 1; }
  grep -q 'grep -v.*WebKitGTK-6.0' "$rules" \
    || { echo "error: locale must be filtered when generating webdriver4.install" >&2; return 1; }
  grep -q 'gir-1.0' "$rules" \
    || { echo "error: GIR cleanup path must target gir-1.0" >&2; return 1; }
  grep -q 'girepository-1.0' "$rules" \
    || { echo "error: typelib cleanup path must target girepository-1.0" >&2; return 1; }
  grep -q 'fuse-ld=gold' "$rules" \
    || { echo "error: gold linker marker missing" >&2; return 1; }
  ! grep -q 'reduce-memory-overheads' "$rules" \
    || { echo "error: reduce-memory-overheads should be removed" >&2; return 1; }
  ! grep -q 'fuse-ld=lld' "$rules" \
    || { echo "error: lld linker must not be used" >&2; return 1; }
  grep -q -- '-Nlibwebkitgtk-doc' "$rules" \
    || { echo "error: -Nlibwebkitgtk-doc skip missing" >&2; return 1; }
  grep -q -- '-Nlibjavascriptcoregtk-6.0-1' "$rules" \
    || { echo "error: must skip libjavascriptcoregtk-6.0-1 (system JSC)" >&2; return 1; }
  grep -q 'override_dh_shlibdeps' "$rules" \
    || { echo "error: override_dh_shlibdeps missing (system JSC for dpkg-shlibdeps)" >&2; return 1; }
  grep -q 'dh_shlibdeps -plibwebkitgtk-6.0-webdriver4 -l/usr/lib/' "$rules" \
    || { echo "error: webdriver dh_shlibdeps must pass -l/usr/lib for system JSC" >&2; return 1; }

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
  grep -q '^Package: libwebkitgtk-6.0-webdriver4$' "$control" \
    || { echo "error: gtk4 webdriver runtime package missing from control" >&2; return 1; }
  grep -q '^Package: libwebkitgtk-6.0-webdriver-dev$' "$control" \
    || { echo "error: gtk4 webdriver dev package missing from control" >&2; return 1; }
  if grep -q '^Package: libwebkitgtk-6.0-4$' "$control"; then
    echo "error: stock libwebkitgtk-6.0-4 must not appear in gtk4-only control" >&2
    return 1
  fi
  if grep -q 'libjavascriptcoregtk-6.0-dev (= ' "$control"; then
    echo "error: libjavascriptcoregtk-6.0-dev must use system archive (no binary:Version pin)" >&2
    return 1
  fi
  if grep -q 'libjavascriptcoregtk-6.0-1 (= ' "$control"; then
    echo "error: libjavascriptcoregtk-6.0-1 must use system archive (no binary:Version pin)" >&2
    return 1
  fi

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
