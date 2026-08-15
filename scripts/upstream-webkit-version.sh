#!/usr/bin/env bash
# Print the newest webkit2gtk *source package* version published for SERIES
# (noble + noble-updates + noble-security). Matches what apt-get source would fetch.
#
# Usage: ./scripts/upstream-webkit-version.sh [SERIES]
set -euo pipefail

SERIES="${1:-noble}"

host_series() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "${VERSION_CODENAME:-}"
  fi
}

if [[ -n "$(host_series)" && "$SERIES" != "$(host_series)" ]]; then
  echo "error: SERIES=$SERIES does not match host ($(host_series))" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

TMP="$(mktemp -d "${TMPDIR:-/tmp}/webkitgtk-upstream-ver.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

sources="$TMP/sources.list"
lists="$TMP/lists"
cache="$TMP/cache"
mkdir -p "$lists/partial" "$cache/archives/partial"

cat >"$sources" <<SOURCES
deb-src http://archive.ubuntu.com/ubuntu ${SERIES} main universe
deb-src http://archive.ubuntu.com/ubuntu ${SERIES}-updates main universe
deb-src http://archive.ubuntu.com/ubuntu ${SERIES}-security main universe
SOURCES

apt_opts=(
  -o "Dir::Etc::sourcelist=$sources"
  -o "Dir::Etc::sourceparts=/dev/null"
  -o "Dir::State::Lists=$lists"
  -o "Dir::Cache=$cache"
)

apt-get update -qq "${apt_opts[@]}"

version="$(
  apt-cache "${apt_opts[@]}" showsrc webkit2gtk 2>/dev/null \
    | awk '/^Version:/ { print $2 }' \
    | sort -V \
    | tail -n 1
)"

if [[ -z "$version" ]]; then
  echo "error: could not determine webkit2gtk source version for series=$SERIES" >&2
  exit 1
fi

echo "$version"
