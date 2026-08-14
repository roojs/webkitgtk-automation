#!/usr/bin/env bash
# Preflight: prove patches/enable-webdriver-gtk4.patch applies to the Ubuntu
# webkit2gtk debian/rules for SERIES — without compiling WebKit.
#
# Usage:
#   ./scripts/pretest-patch.sh           # host series (or SERIES=…)
#   ./scripts/pretest-patch.sh noble
#
# Exit 0 = patch applies cleanly. Exit non-zero = do not start a full build.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH="$REPO_ROOT/patches/enable-webdriver-gtk4.patch"

host_series() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "${VERSION_CODENAME:-}"
  fi
}

SERIES="${SERIES:-${1:-$(host_series)}}"
SERIES="${SERIES:-noble}"

if [[ ! -f "$PATCH" ]]; then
  echo "error: missing $PATCH" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "==> pretest series=$SERIES"
echo "==> patch=$PATCH"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/webkitgtk-pretest.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Always fetch the published package for SERIES via a temporary deb-src list.
# Never prefer host apt indexes (wrong series / wrong package pin).
# Launchpad tip is fallback only — it can drift from the published package.
fetch_rules_via_archive_apt() {
  local sources="$TMP/webkitgtk-deb-src.list"
  local lists="$TMP/apt-lists"
  local cache="$TMP/apt-cache"
  mkdir -p "$lists/partial" "$cache/archives/partial"

  cat >"$sources" <<SOURCES
deb-src http://archive.ubuntu.com/ubuntu ${SERIES} main universe
deb-src http://archive.ubuntu.com/ubuntu ${SERIES}-updates main universe
deb-src http://archive.ubuntu.com/ubuntu ${SERIES}-security main universe
SOURCES

  local apt_opts=(
    -o "Dir::Etc::sourcelist=$sources"
    -o "Dir::Etc::sourceparts=/dev/null"
    -o "Dir::State::Lists=$lists"
    -o "Dir::Cache=$cache"
  )

  echo "==> apt-get update (SERIES=$SERIES archive deb-src only)"
  apt-get update -qq "${apt_opts[@]}"

  echo "==> apt-get source -d -y webkit2gtk (download-only)"
  (
    cd "$TMP"
    apt-get source -d -y "${apt_opts[@]}" webkit2gtk
    local deb_tar
    deb_tar="$(find . -maxdepth 1 -type f \( -name '*debian.tar.*' -o -name '*.debian.tar.*' \) | head -n 1)"
    if [[ -z "$deb_tar" ]]; then
      echo "error: no debian.tar found after apt-get source -d" >&2
      ls -la >&2 || true
      return 1
    fi
    echo "==> extracting debian/rules from $deb_tar"
    mkdir -p src
    tar -C src -xf "$deb_tar" debian/rules
    [[ -f src/debian/rules ]]
  )
}

fetch_rules_via_launchpad() {
  local url="https://git.launchpad.net/ubuntu/+source/webkit2gtk/plain/debian/rules?h=ubuntu/${SERIES}"
  echo "warning: archive apt fetch failed; falling back to Launchpad tip" >&2
  echo "warning: ubuntu/${SERIES} tip may differ from the published package" >&2
  echo "==> fallback: curl $url"
  mkdir -p "$TMP/src/debian"
  curl -fsSL "$url" -o "$TMP/src/debian/rules"
  [[ -s "$TMP/src/debian/rules" ]]
}

if fetch_rules_via_archive_apt; then
  echo "==> using archive apt debian/rules for $SERIES"
elif fetch_rules_via_launchpad; then
  echo "==> using Launchpad debian/rules for ubuntu/$SERIES (tip; not package pin)"
else
  echo "error: could not obtain debian/rules for series=$SERIES" >&2
  exit 1
fi

echo "==> dry-run patch -p1"
(
  cd "$TMP/src"
  if ! patch -p1 --dry-run < "$PATCH"; then
    echo "error: patch does not apply to $SERIES debian/rules" >&2
    echo "       regenerate patches/enable-webdriver-gtk4.patch against that series." >&2
    exit 1
  fi
)

echo "==> applying for real (temp tree only) to confirm"
(
  cd "$TMP/src"
  patch -p1 < "$PATCH" >/dev/null
  # Spot-check critical markers landed.
  grep -q 'ENABLE_WEBDRIVER_GTK4 = -DENABLE_WEBDRIVER=ON' debian/rules
  grep -q 'fuse-ld=lld' debian/rules
  grep -q 'ENABLE_SOUP3=NO' debian/rules
)

echo "==> pretest OK (patch applies to $SERIES debian/rules)"
