#!/usr/bin/env bash
# Helpers to fake a "compiled" work tree for packaging-stage tests (no WebKit compile).
# shellcheck source=scripts/lib/archive-apt.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/archive-apt.sh"
# shellcheck source=scripts/lib/pinned-webkit-version.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pinned-webkit-version.sh"

write_fake_build_gtk4() {
  local src="$1"
  mkdir -p "$src/build-gtk4/CMakeFiles"
  echo 'CMAKE_GENERATOR:INTERNAL=Ninja' >"$src/build-gtk4/CMakeCache.txt"
  touch "$src/build-gtk4/build.ninja" "$src/build-gtk4/CMakeFiles/VerifyGlobs.cmake"
}

write_compiled_marker() {
  local src="$1" series="$2" suffix="$3" compile_key="$4"
  local rules_patch="$5" cmake_patch="$6"
  local rules_sha cmake_sha patch_sha
  rules_sha="$(sha256sum "$rules_patch" | awk '{print $1}')"
  cmake_sha="$(sha256sum "$cmake_patch" | awk '{print $1}')"
  patch_sha="$(cat "$rules_patch" "$cmake_patch" | sha256sum | awk '{print $1}')"
  cat >"$src/.webkitgtk-automation-prepared" <<EOF
SERIES=$series
SUFFIX=$suffix
COMPILE_CACHE_KEY=$compile_key
PATCH_SHA256=$patch_sha
RULES_PATCH_SHA256=$rules_sha
CMAKE_PATCH_SHA256=$cmake_sha
STAGE=compiled
PREPARED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

inject_install_manifest_target() {
  local rules="$1" layout="$2"
  if grep -q '^webkitgtk-webdriver-install-manifests:' "$rules" \
    || grep -q '^webkitgtk-automation-install-manifests:' "$rules"; then
    return 0
  fi
  local gtk4_sed_cmd='$(WEBKIT_DH_CONVERT_GTK4)'
  if [[ "$layout" == soup3-gtk4 ]]; then
    gtk4_sed_cmd='$(WEBKIT_DH_RENAME_GTK4)'
  fi
  cat >>"$rules" <<EOF

# webkitgtk-automation: local simulate-package-stage helper (no cmake).
webkitgtk-automation-install-manifests:
	echo debian/clean > debian/clean
	if [ "\$(ENABLE_GTK4)" = "YES" ]; then \\
		for src in \$(WEBKIT_DH_FILES); do \\
			dst=\`echo \$\$src | \$(WEBKIT_DH_RENAME_GTK4)\` ; \\
			wd=\`echo \$\$dst | \$(WEBKIT_DH_RENAME_WEBDRIVER_NAMES)\` ; \\
			case \$\$src in *-dev.install|gir*.install|*.docs) ;; \\
			*) \\
				${gtk4_sed_cmd} debian/\$\$src | \$(WEBKIT_DH_RENAME_WEBDRIVER) | grep -v 'usr/share/locale.*WebKitGTK-6.0\\.mo' > debian/\$\$wd ; \\
				echo debian/\$\$wd >> debian/clean ; \\
			esac ; \\
		done ; \\
	fi
	@{ \\
		echo 'prefix=/usr'; \\
		echo 'libdir=\$\${prefix}/lib/\$(DEB_HOST_MULTIARCH)'; \\
		echo 'includedir=\$\${prefix}/include'; \\
		echo ''; \\
		echo 'Name: webkitgtk-6.0-webdriver'; \\
		echo 'Description: WebKitGTK 6.0 with WebDriver interactions (parallel install)'; \\
		echo 'Version: \$(shell dpkg-parsechangelog -S Version)'; \\
		echo 'Requires: webkitgtk-6.0, gtk4, libsoup-3.0, javascriptcoregtk-6.0'; \\
		echo 'Libs: -L\$\${libdir} -l:libwebkitgtk-6.0-webdriver.so.4'; \\
		echo 'Cflags: -I\$\${includedir}/webkitgtk-6.0 -I\$\${includedir}/webkitgtk-webdriver-6.0'; \\
	} > debian/webkitgtk-6.0-webdriver.pc
	echo 'debian/webkitgtk-6.0-webdriver.pc usr/lib/\$(DEB_HOST_MULTIARCH)/pkgconfig/' > debian/libwebkitgtk-6.0-webdriver-dev.install
	echo 'debian/webkitgtk-webdriver/WebKitNavigatorWebDriverActivePolicy.h usr/include/webkitgtk-webdriver-6.0/' >> debian/libwebkitgtk-6.0-webdriver-dev.install
	echo 'debian/webkitgtk-webdriver/webkitgtk-webdriver.vapi usr/share/vala/vapi/' >> debian/libwebkitgtk-6.0-webdriver-dev.install
	echo debian/webkitgtk-6.0-webdriver.pc >> debian/clean
EOF
}

regenerate_install_manifests() {
  local src="$1" series="$2" layout
  # shellcheck source=scripts/lib/series-registry.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/series-registry.sh"
  layout="$(series_layout "$series")"
  cd "$src"
  fakeroot make -f debian/rules debian/control
  # shellcheck source=scripts/lib/rewrite-webdriver-packaging-metadata.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rewrite-webdriver-packaging-metadata.sh"
  rewrite_webdriver_packaging_metadata "$src"
  inject_install_manifest_target debian/rules "$layout"
  if grep -q '^webkitgtk-webdriver-install-manifests:' debian/rules; then
    fakeroot make -f debian/rules webkitgtk-webdriver-install-manifests
  else
    fakeroot make -f debian/rules webkitgtk-automation-install-manifests
  fi
  local install="$src/debian/libwebkitgtk-6.0-webdriver4.install"
  [[ -f "$install" ]] && [[ -s "$install" ]] || {
    echo "error: empty or missing $install after manifest regen (layout=$layout)" >&2
    return 1
  }
}

ubuntu_stock_to_webdriver_path() {
  local path="$1"
  # Bound with slashes so libwebkitgtk-6.0/ is not touched when renaming webkitgtk-6.0/.
  path="${path//\/webkitgtk-6.0\//\/webkitgtk-6.0-webdriver\/}"
  path="${path//libwebkitgtk-6.0\.so/libwebkitgtk-6.0-webdriver.so}"
  printf '%s' "$path"
}

add_packaging_cleanup_decoys() {
  local src="$1"
  local multiarch="${DEB_HOST_MULTIARCH:-$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo x86_64-linux-gnu)}"
  # Ninja install artifacts not in the stock runtime .deb — cleanup must still strip these.
  mkdir -p "$src/debian/tmp/usr/share/locale/en/LC_MESSAGES"
  : >"$src/debian/tmp/usr/share/locale/en/LC_MESSAGES/WebKitGTK-6.0.mo"
  mkdir -p "$src/debian/tmp/usr/include/webkitgtk-6.0"
  : >"$src/debian/tmp/usr/include/webkitgtk-6.0/webkit.h"
  mkdir -p "$src/debian/tmp/usr/share/gir-1.0"
  : >"$src/debian/tmp/usr/share/gir-1.0/WebKit-6.0.gir"
  mkdir -p "$src/debian/tmp/usr/lib/$multiarch/girepository-1.0"
  : >"$src/debian/tmp/usr/lib/$multiarch/girepository-1.0/JavaScriptCore-6.0.typelib"
  : >"$src/debian/tmp/usr/lib/$multiarch/girepository-1.0/WebKit-6.0.typelib"
  : >"$src/debian/tmp/usr/lib/$multiarch/girepository-1.0/WebKitWebProcessExtension-6.0.typelib"
}

download_ubuntu_binary_deb() {
  local series="$1" apt_base="$2" dest="$3" pkg="$4" version="$5"
  archive_apt_init "$series" "$apt_base"
  archive_apt_update
  archive_apt_download "$dest" "${pkg}=${version}"
}

populate_debian_tmp_from_ubuntu_stock() {
  local src="$1" series="$2" apt_base="$3"
  local version arch deb extract tmp rel destpath srcfile destfile
  version="$(read_pinned_webkit_version "$series")"
  arch="${DEB_HOST_ARCH:-$(dpkg-architecture -qDEB_HOST_ARCH 2>/dev/null || echo amd64)}"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/webkitgtk-ubuntu-fixture.XXXXXX")"
  trap 'rm -rf "$tmp"' RETURN

  echo "==> downloading stock Ubuntu libwebkitgtk-6.0-4=${version} (${series})"
  download_ubuntu_binary_deb "$series" "$apt_base" "$tmp/dl" \
    "libwebkitgtk-6.0-4" "$version"

  deb="$(find "$tmp/dl" -maxdepth 1 -type f -name 'libwebkitgtk-6.0-4_*.deb' -print -quit)"
  [[ -n "$deb" ]] || {
    echo "error: libwebkitgtk-6.0-4 .deb not found after apt download" >&2
    return 1
  }

  extract="$tmp/extract"
  mkdir -p "$extract"
  dpkg-deb -x "$deb" "$extract"

  echo "==> copying stock package tree into debian/tmp (webdriver path rename)"
  while IFS= read -r -d '' srcfile; do
    rel="${srcfile#"$extract"/}"
    case "$rel" in
      usr/share/doc/*) continue ;; # not in webdriver4 install manifest
    esac
    destpath="$(ubuntu_stock_to_webdriver_path "$rel")"
    destfile="$src/debian/tmp/$destpath"
    mkdir -p "$(dirname "$destfile")"
    cp -a "$srcfile" "$destfile"
  done < <(find "$extract" -type f -print0)

  add_packaging_cleanup_decoys "$src"
  trap - RETURN
  rm -rf "$tmp"
}

populate_debian_tmp() {
  local src="$1" series="$2" apt_base="$3"
  local mode="${PACKAGE_FIXTURE:-ubuntu}"
  case "$mode" in
    ubuntu)
      populate_debian_tmp_from_ubuntu_stock "$src" "$series" "$apt_base"
      ;;
    stub)
      populate_debian_tmp_stubs "$src"
      ;;
    *)
      echo "error: unknown PACKAGE_FIXTURE=$mode (ubuntu|stub)" >&2
      return 1
      ;;
  esac
}

populate_debian_tmp_stubs() {
  local src="$1"
  local install="$src/debian/libwebkitgtk-6.0-webdriver4.install"
  local line path
  [[ -f "$install" ]] || { echo "error: missing $install" >&2; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" ]] && continue
    path="${line%% *}"
    mkdir -p "$src/debian/tmp/$(dirname "$path")"
    : >"$src/debian/tmp/$path"
  done <"$install"
  add_packaging_cleanup_decoys "$src"
}

run_dh_shlibdeps_check() {
  local src="$1" series="$2" apt_base="$3"
  local version tmp dl merged multiarch lib_extra main_so deb_count
  version="$(read_pinned_webkit_version "$series")"
  multiarch="${DEB_HOST_MULTIARCH:-$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo x86_64-linux-gnu)}"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/webkitgtk-jsc-fixture.XXXXXX")"
  trap 'rm -rf "$tmp"' RETURN

  echo "==> downloading stock Ubuntu runtime deps for dpkg-shlibdeps (libwebkitgtk-6.0-4=${version})"
  archive_apt_init "$series" "$apt_base"
  archive_apt_update
  dl="$tmp/dl"
  archive_apt_download_deps "$dl" \
    "libwebkitgtk-6.0-4=${version}" \
    "libjavascriptcoregtk-6.0-1=${version}"

  deb_count="$(find "$dl" -maxdepth 1 -type f -name '*.deb' | wc -l)"
  [[ "$deb_count" -gt 0 ]] || {
    echo "error: no .deb files in archive apt cache after download-deps" >&2
    return 1
  }

  merged="$tmp/merged"
  extract_debs_tree "$dl" "$merged"
  lib_extra="-l/usr/lib/$multiarch -l$merged/usr/lib/$multiarch -l$merged/lib/$multiarch"
  cd "$src"
  main_so="$(find debian/libwebkitgtk-6.0-webdriver4 -type f -name 'libwebkitgtk-6.0-webdriver.so.*' | head -1)"
  [[ -n "$main_so" ]] || {
    echo "error: no libwebkitgtk-6.0-webdriver.so.* in package tree after dh_install" >&2
    return 1
  }
  echo "==> dpkg-shlibdeps on $main_so ($deb_count stock .debs merged; --ignore-missing-info)"
  if ! fakeroot dpkg-shlibdeps --ignore-missing-info \
    -Tdebian/libwebkitgtk-6.0-webdriver4.substvars \
    $lib_extra "$main_so"; then
    echo "error: dpkg-shlibdeps failed on stock-renamed main .so" >&2
    return 1
  fi
  trap - RETURN
  rm -rf "$tmp"
}

run_override_dh_auto_install_cleanup() {
  local src="$1"
  cd "$src"
  find debian/tmp \( -type f -o -type l \) \( \
    -name 'libjavascriptcoregtk-6.0.so' -o -name 'libjavascriptcoregtk-6.0.so.*' \
    -o -name 'libwebkitgtk-6.0-webdriver.so' \
    -o -name 'javascriptcoregtk-6.0.pc' -o -name 'webkitgtk-6.0.pc' \
    -o -name 'webkitgtk-web-process-extension-6.0.pc' \) -delete
  find debian/tmp -path '*/gir-1.0/*JavaScriptCore*6.0*' -delete
  find debian/tmp -path '*/gir-1.0/*WebKit*6.0*' -delete
  find debian/tmp -path '*/girepository-1.0/*JavaScriptCore*6.0*' -delete
  find debian/tmp -path '*/girepository-1.0/*WebKit*6.0*' -delete
  rm -rf debian/tmp/usr/include/webkitgtk-6.0
  rm -rf debian/tmp/usr/lib/*/webkitgtk-6.0-webdriver/jsc
  find debian/tmp -path '*/LC_MESSAGES/WebKitGTK-6.0.mo' -delete
  if [[ -f debian/libwebkitgtk-6.0-webdriver4.install ]]; then
    sed -i '/usr\/share\/locale.*WebKitGTK-6.0\.mo/d' debian/libwebkitgtk-6.0-webdriver4.install
  fi
}

read_extra_dh_arguments() {
  local rules="$1" merged from_make from_rules
  merged="$(make -f "$rules" -pn 2>/dev/null | awk -F'= ' '/^EXTRA_DH_ARGUMENTS =/{v=$2} END{print v}')"
  merged="${merged#"${merged%%[![:space:]]*}"}"
  merged="${merged%"${merged##*[![:space:]]}"}"
  if [[ -n "$merged" && "$merged" != "\\" ]]; then
    echo "$merged"
    return 0
  fi
  # make -pn can leave split/unexpanded assignments on some hosts; scrape rules.
  from_rules="$(grep -E '^EXTRA_DH_ARGUMENTS[[:space:]]*\+?=' "$rules" \
    | sed -E 's/^EXTRA_DH_ARGUMENTS[[:space:]]*\+?=[[:space:]]*//;s/[[:space:]]*\\$//' \
    | tr '\n' ' ')"
  from_rules="${from_rules#"${from_rules%%[![:space:]]*}"}"
  from_rules="${from_rules%"${from_rules##*[![:space:]]}"}"
  if [[ -n "$from_rules" ]]; then
    echo "$from_rules"
    return 0
  fi
  return 1
}

run_dh_install_and_missing() {
  local src="$1"
  local extra
  cd "$src"
  # Simulate validates webdriver packaging only — do not dh_install the whole
  # webkit2gtk stack (would require stubs for jsc/gir/webdriver binary, etc.).
  extra="-plibwebkitgtk-6.0-webdriver4 -plibwebkitgtk-6.0-webdriver-dev"
  if read_extra_dh_arguments debian/rules >/dev/null 2>&1; then
    : # rules parseable; webdriver-only -p is intentional for this fixture
  fi
  if ! fakeroot dh_install $extra; then
    echo "error: dh_install failed for webdriver packages (extra=$extra)" >&2
    return 1
  fi
  if ! fakeroot dh_missing $extra; then
    echo "error: dh_missing failed for webdriver packages (extra=$extra)" >&2
    return 1
  fi
}
