#!/usr/bin/env bash
# Isolated apt against archive.ubuntu.com for one Ubuntu series (no host dist-upgrade).

archive_apt_init() {
  local series="$1" base="$2"
  ARCHIVE_APT_SERIES="$series"
  ARCHIVE_APT_BASE="$base"
  ARCHIVE_APT_SOURCES="$base/archive-apt-sources.list"
  ARCHIVE_APT_LISTS="$base/archive-apt-lists"
  ARCHIVE_APT_CACHE="$base/archive-apt-cache"
  ARCHIVE_APT_DPKG_STATUS="$base/archive-apt-dpkg-status"
  mkdir -p "$ARCHIVE_APT_LISTS/partial" "$ARCHIVE_APT_CACHE/archives/partial"
  : >"$ARCHIVE_APT_DPKG_STATUS"
  cat >"$ARCHIVE_APT_SOURCES" <<SOURCES
deb http://archive.ubuntu.com/ubuntu ${series} main universe
deb http://archive.ubuntu.com/ubuntu ${series}-updates main universe
deb http://archive.ubuntu.com/ubuntu ${series}-security main universe
deb-src http://archive.ubuntu.com/ubuntu ${series} main universe
deb-src http://archive.ubuntu.com/ubuntu ${series}-updates main universe
deb-src http://archive.ubuntu.com/ubuntu ${series}-security main universe
SOURCES
}

archive_apt_opts() {
  ARCHIVE_APT_OPTS=(
    -o "Dir::Etc::sourcelist=$ARCHIVE_APT_SOURCES"
    -o "Dir::Etc::sourceparts=/dev/null"
    -o "Dir::State::Lists=$ARCHIVE_APT_LISTS"
    -o "Dir::Cache=$ARCHIVE_APT_CACHE"
    -o "Dir::State::status=$ARCHIVE_APT_DPKG_STATUS"
  )
}

archive_apt() {
  [[ -n "${ARCHIVE_APT_SOURCES:-}" ]] || {
    echo "error: archive_apt_init not called" >&2
    return 1
  }
  archive_apt_opts
  apt-get "$@" "${ARCHIVE_APT_OPTS[@]}"
}

archive_apt_cache() {
  [[ -n "${ARCHIVE_APT_SOURCES:-}" ]] || {
    echo "error: archive_apt_init not called" >&2
    return 1
  }
  archive_apt_opts
  apt-cache "$@" "${ARCHIVE_APT_OPTS[@]}"
}

archive_apt_update() {
  archive_apt update -qq
}

archive_apt_download() {
  local dest="$1"
  shift
  mkdir -p "$dest"
  (
    cd "$dest"
    archive_apt download "$@"
  )
}

# Collect binary package names needed to satisfy Depends (no Recommends/Suggests).
archive_apt_depends_packages() {
  local pkg
  archive_apt_cache depends --recurse --no-recommends --no-suggests \
    --no-conflicts --no-breaks --no-replaces --no-enhances "$@" \
    | awk '/^  Depends: / { split($2, a, ":"); print a[1] }' \
    | grep -v '^<' | sort -u
}

# Download a package plus its Depends into dest (no dpkg install; no host lock).
archive_apt_download_deps() {
  local dest="$1"
  shift
  local dep_pkgs=()
  mapfile -t dep_pkgs < <(archive_apt_depends_packages "$@")
  mkdir -p "$dest"
  (
    cd "$dest"
    if ((${#dep_pkgs[@]} > 0)); then
      archive_apt download "$@" "${dep_pkgs[@]}"
    else
      archive_apt download "$@"
    fi
  )
}

# Merge all .deb files in a directory into one tree (for -l paths in dpkg-shlibdeps).
extract_debs_tree() {
  local debs_dir="$1" dest="$2"
  local deb
  mkdir -p "$dest"
  while IFS= read -r -d '' deb; do
    dpkg-deb -x "$deb" "$dest"
  done < <(find "$debs_dir" -maxdepth 1 -type f -name '*.deb' -print0)
}
