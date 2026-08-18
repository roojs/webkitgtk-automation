#!/usr/bin/env bash
# Helpers to fake a "compiled" work tree for packaging-stage tests (no WebKit compile).

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
  local rules="$1"
  if grep -q '^webkitgtk-webdriver-install-manifests:' "$rules" \
    || grep -q '^webkitgtk-automation-install-manifests:' "$rules"; then
    return 0
  fi
  cat >>"$rules" <<'EOF'

# webkitgtk-automation: local simulate-package-stage helper (no cmake).
webkitgtk-automation-install-manifests:
	echo debian/clean > debian/clean
	if [ "$(ENABLE_GTK4)" = "YES" ]; then \
		for src in $(WEBKIT_DH_FILES); do \
			dst=`echo $$src | $(WEBKIT_DH_RENAME_GTK4)` ; \
			wd=`echo $$dst | $(WEBKIT_DH_RENAME_WEBDRIVER_NAMES)` ; \
			case $$src in *-dev.install|gir*.install|*.docs) ;; \
			*) \
				$(WEBKIT_DH_CONVERT_GTK4) debian/$$src | $(WEBKIT_DH_RENAME_WEBDRIVER) | grep -v 'usr/share/locale.*WebKitGTK-6.0\.mo' > debian/$$wd ; \
				echo debian/$$wd >> debian/clean ; \
			esac ; \
		done ; \
	fi
	@{ \
		echo 'prefix=/usr'; \
		echo 'libdir=$${prefix}/lib/$(DEB_HOST_MULTIARCH)'; \
		echo 'includedir=$${prefix}/include'; \
		echo ''; \
		echo 'Name: webkitgtk-6.0-webdriver'; \
		echo 'Description: WebKitGTK 6.0 with WebDriver interactions (parallel install)'; \
		echo 'Version: $(shell dpkg-parsechangelog -S Version)'; \
		echo 'Requires: gtk4, libsoup-3.0, javascriptcoregtk-6.0'; \
		echo 'Libs: -L$${libdir} -l:libwebkitgtk-6.0-webdriver.so.4'; \
		echo 'Cflags: -I$${includedir}/webkitgtk-6.0'; \
	} > debian/webkitgtk-6.0-webdriver.pc
	echo 'debian/webkitgtk-6.0-webdriver.pc usr/lib/$(DEB_HOST_MULTIARCH)/pkgconfig/' > debian/libwebkitgtk-6.0-webdriver-dev.install
	echo debian/webkitgtk-6.0-webdriver.pc >> debian/clean
EOF
}

regenerate_install_manifests() {
  local src="$1"
  cd "$src"
  fakeroot make -f debian/rules debian/control
  inject_install_manifest_target debian/rules
  if grep -q '^webkitgtk-webdriver-install-manifests:' debian/rules; then
    fakeroot make -f debian/rules webkitgtk-webdriver-install-manifests
  else
    fakeroot make -f debian/rules webkitgtk-automation-install-manifests
  fi
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
  # Decoys that override_dh_auto_install should strip (packaging regression checks).
  mkdir -p "$src/debian/tmp/usr/share/locale/en/LC_MESSAGES"
  : >"$src/debian/tmp/usr/share/locale/en/LC_MESSAGES/WebKitGTK-6.0.mo"
  mkdir -p "$src/debian/tmp/usr/include/webkitgtk-6.0"
  : >"$src/debian/tmp/usr/include/webkitgtk-6.0/webkit.h"
  mkdir -p "$src/debian/tmp/usr/share/gir-1.0"
  : >"$src/debian/tmp/usr/share/gir-1.0/WebKit-6.0.gir"
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
  rm -rf debian/tmp/usr/include/webkitgtk-6.0
  rm -rf debian/tmp/usr/lib/*/webkitgtk-6.0-webdriver/jsc
  find debian/tmp -path '*/LC_MESSAGES/WebKitGTK-6.0.mo' -delete
  if [[ -f debian/libwebkitgtk-6.0-webdriver4.install ]]; then
    sed -i '/usr\/share\/locale.*WebKitGTK-6.0\.mo/d' debian/libwebkitgtk-6.0-webdriver4.install
  fi
}

run_dh_install_and_missing() {
  local src="$1"
  local extra
  cd "$src"
  # --with/--buildsystem are dh sequencer options, not valid on dh_install/dh_missing.
  extra="$(make -f debian/rules -pn 2>/dev/null | awk -F'= ' '/^EXTRA_DH_ARGUMENTS =/{print $2; exit}')"
  # shellcheck disable=SC2086
  fakeroot dh_install $extra
  # shellcheck disable=SC2086
  fakeroot dh_missing $extra
}
