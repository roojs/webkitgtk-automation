#!/usr/bin/env bash
# Rewrite Maintainer and webdriver package descriptions after debian/control regen.
set -euo pipefail

MAINTAINER_NAME="${WEBKITGTK_PACKAGE_MAINTAINER_NAME:-Alan Knowles}"
MAINTAINER_EMAIL="${WEBKITGTK_PACKAGE_MAINTAINER_EMAIL:-alan@roojs.com}"
MAINTAINER="${MAINTAINER_NAME} <${MAINTAINER_EMAIL}>"

rewrite_webdriver_packaging_metadata() {
  local tree="${1:-.}"
  local control="$tree/debian/control"
  local changelog="$tree/debian/changelog"

  [[ -f "$control" ]] || {
    echo "error: missing $control" >&2
    return 1
  }

  sed -i "s/^Maintainer: .*/Maintainer: ${MAINTAINER}/" "$control"

  awk -v runtime_pkg='libwebkitgtk-6.0-webdriver4' \
      -v dev_pkg='libwebkitgtk-6.0-webdriver-dev' \
      '
    function print_runtime_body() {
      print " Parallel-install rebuild of Ubuntu libwebkitgtk-6.0 with ENABLE_WEBDRIVER"
      print " compiled in for GTK4. Coexists with system libwebkitgtk-6.0-4 and links"
      print " against stock libjavascriptcoregtk-6.0-1. Packaged by roojs."
      print " ."
      print " Use system webkitgtk-webdriver for the automation server; link apps"
      print " against this library for Element Click / Send Keys on GTK4."
    }
    function print_dev_body() {
      print " Ships webkitgtk-6.0-webdriver.pc only. API headers and vapi come from"
      print " system libwebkitgtk-6.0-dev and libjavascriptcoregtk-6.0-dev."
    }
    function skip_description_body() {
      while ((getline line) > 0 && line ~ /^[ \t]/) {
        continue
      }
      return line
    }
    function handle_package_line(line,    pkg) {
      sub(/^Package: /, "", line)
      pkg = line
      print "Package: " pkg
      if (pkg == runtime_pkg) {
        target = "runtime"
      } else if (pkg == dev_pkg) {
        target = "dev"
      } else {
        target = ""
      }
    }
    {
      line = $0
      if (line ~ /^Package: /) {
        handle_package_line(line)
        next
      }
      if (target != "" && line ~ /^Description: /) {
        if (target == "runtime") {
          print "Description: WebKitGTK 6.0 runtime with WebDriver interactions (parallel install)"
          print_runtime_body()
        } else {
          print "Description: pkg-config for libwebkitgtk-6.0-webdriver (thin -dev package)"
          print_dev_body()
        }
        follow = skip_description_body()
        if (follow != "") {
          if (follow ~ /^Package: /) {
            handle_package_line(follow)
          } else {
            print follow
          }
        }
        next
      }
      print line
    }
  ' "$control" >"$control.tmp"
  mv "$control.tmp" "$control"

  if [[ -f "$changelog" ]]; then
    sed -i "s/^ -- .*/ -- ${MAINTAINER}  $(date -R)/" "$changelog"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  rewrite_webdriver_packaging_metadata "${1:-.}"
fi
