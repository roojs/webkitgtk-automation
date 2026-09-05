#!/usr/bin/env bash
# Canonical manifest for repo files staged into libwebkitgtk-6.0-webdriver-dev.
# Used by build.sh, pretest, and simulate-package-stage install manifests.
#
# Format per line: relpath|install-dest-in-deb
# (staged under debian/webkitgtk-webdriver/ before dh_install)

webdriver_dev_packaging_manifest() {
  cat <<'EOF'
packaging/webkitgtk-webdriver/WebKitNavigatorWebDriverActivePolicy.h|usr/include/webkitgtk-webdriver-6.0/
packaging/webkitgtk-webdriver/webkitgtk-webdriver.vapi|usr/share/vala/vapi/
packaging/webkitgtk-webdriver/webkitgtk-webdriver.deps|usr/share/vala/vapi/
EOF
}

_webdriver_dev_parse_entry() {
  local line="$1"
  relpath="${line%%|*}"
  install_dest="${line#*|}"
}

assert_webdriver_dev_packaging_files() {
  local repo_root="$1" line relpath install_dest missing=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    _webdriver_dev_parse_entry "$line"
    if [[ ! -f "$repo_root/$relpath" ]]; then
      echo "error: missing $repo_root/$relpath (webdriver dev packaging manifest)" >&2
      missing=1
    fi
  done < <(webdriver_dev_packaging_manifest)
  return "$missing"
}

stage_webdriver_dev_bindings() {
  local repo_root="$1" src="$2" line relpath install_dest
  mkdir -p "$src/debian/webkitgtk-webdriver"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    _webdriver_dev_parse_entry "$line"
    cp "$repo_root/$relpath" "$src/debian/webkitgtk-webdriver/"
  done < <(webdriver_dev_packaging_manifest)
}

webdriver_dev_packaging_install_echo_snippets() {
  local line relpath install_dest base
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    _webdriver_dev_parse_entry "$line"
    base="${relpath##*/}"
    printf "\techo 'debian/webkitgtk-webdriver/%s %s' >> debian/libwebkitgtk-6.0-webdriver-dev.install\n" \
      "$base" "$install_dest"
  done < <(webdriver_dev_packaging_manifest)
}
