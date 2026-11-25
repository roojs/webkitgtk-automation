#!/usr/bin/env bash
# Download a Debian source package through an isolated apt whose deb-src entries
# are signed-by the Debian archive keyring. apt checks the InRelease signature
# and every file hash (dsc, orig, debian tarballs) before the files land in dest.
#
# Env:
#   DEBIAN_MIRROR            (default: http://deb.debian.org/debian)
#   DEBIAN_SECURITY_MIRROR   (default: http://deb.debian.org/debian-security)
#   DEBIAN_ARCHIVE_KEYRING   (default: /usr/share/keyrings/debian-archive-keyring.gpg)

debian_source_apt_keyring() {
  echo "${DEBIAN_ARCHIVE_KEYRING:-/usr/share/keyrings/debian-archive-keyring.gpg}"
}

debian_source_apt_ensure_keyring() {
  local keyring
  keyring="$(debian_source_apt_keyring)"
  if [[ ! -s "$keyring" ]] && command -v sudo >/dev/null 2>&1; then
    echo "==> installing debian-archive-keyring" >&2
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq debian-archive-keyring >&2 || true
  fi
  if [[ ! -s "$keyring" ]]; then
    echo "error: Debian archive keyring not found: $keyring (apt install debian-archive-keyring)" >&2
    return 1
  fi
}

# Usage: debian_source_apt_download SERIES PACKAGE VERSION DEST
debian_source_apt_download() {
  local series="$1" package="$2" version="$3" dest="$4"
  local keyring mirror security_mirror state sources lists cache status
  local -a opts

  debian_source_apt_ensure_keyring || return 1
  keyring="$(debian_source_apt_keyring)"
  mirror="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
  security_mirror="${DEBIAN_SECURITY_MIRROR:-http://deb.debian.org/debian-security}"

  state="$(mktemp -d "${TMPDIR:-/tmp}/webkitgtk-debian-apt.XXXXXX")"
  sources="$state/sources.list"
  lists="$state/lists"
  cache="$state/cache"
  status="$state/dpkg-status"
  mkdir -p "$lists/partial" "$cache/archives/partial" "$state/trusted.gpg.d" "$dest"
  : >"$status"
  cat >"$sources" <<SOURCES
deb-src [signed-by=${keyring}] ${mirror} ${series} main
deb-src [signed-by=${keyring}] ${mirror} ${series}-updates main
deb-src [signed-by=${keyring}] ${security_mirror} ${series}-security main
SOURCES

  opts=(
    -o "Dir::Etc::sourcelist=$sources"
    -o "Dir::Etc::sourceparts=/dev/null"
    -o "Dir::Etc::trusted=$state/trusted.gpg"
    -o "Dir::Etc::trustedparts=$state/trusted.gpg.d"
    -o "Dir::State::Lists=$lists"
    -o "Dir::State::status=$status"
    -o "Dir::Cache=$cache"
    -o "Acquire::AllowInsecureRepositories=false"
    -o "Acquire::AllowDowngradeToInsecureRepositories=false"
    -o "Acquire::AllowWeakRepositories=false"
    -o "APT::Get::AllowUnauthenticated=false"
  )

  if ! apt-get update -qq "${opts[@]}" >&2; then
    echo "error: apt-get update failed for signed Debian $series sources" >&2
    rm -rf "$state"
    return 1
  fi
  if ! (cd "$dest" && apt-get source -d -y --only-source "${opts[@]}" "${package}=${version}") >&2; then
    echo "error: apt-get source could not fetch a verified ${package}=${version} for $series" >&2
    rm -rf "$state"
    return 1
  fi
  rm -rf "$state"
}
