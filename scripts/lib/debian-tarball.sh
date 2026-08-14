#!/usr/bin/env bash
# Locate or download webkit2gtk *.debian.tar.* next to an unpacked work tree.
#
# build.sh sets DOWNLOAD_WEBKIT2GTK_SOURCE_CMD before calling ensure_debian_tarball.
# Tests set it to an isolated apt-get source -d invocation.

find_debian_tarball() {
  local parent="$1"
  find "$parent" -maxdepth 1 -type f \( -name 'webkit2gtk_*_debian.tar.*' -o -name 'webkit2gtk_*.debian.tar.*' \) -print -quit 2>/dev/null || true
}

download_debian_tarball_to_parent() {
  local parent="$1"
  if [[ -z "${DOWNLOAD_WEBKIT2GTK_SOURCE_CMD:-}" ]]; then
    echo "error: DOWNLOAD_WEBKIT2GTK_SOURCE_CMD is not set" >&2
    return 1
  fi
  echo "==> downloading webkit2gtk source package into $parent (download-only)" >&2
  (
    cd "$parent"
    # shellcheck disable=SC2091
    eval "$DOWNLOAD_WEBKIT2GTK_SOURCE_CMD"
  ) >&2
}

ensure_debian_tarball() {
  local parent="$1"
  local debian_tar
  debian_tar="$(find_debian_tarball "$parent")"
  if [[ -n "$debian_tar" ]]; then
    printf '%s\n' "$debian_tar"
    return 0
  fi
  download_debian_tarball_to_parent "$parent" || return 1
  debian_tar="$(find_debian_tarball "$parent")"
  if [[ -z "$debian_tar" ]]; then
    echo "error: could not obtain webkit2gtk debian tarball in $parent" >&2
    return 1
  fi
  printf '%s\n' "$debian_tar"
}

refresh_debian_rules_from_patch() {
  local src="$1" patch="$2" parent debian_tar
  parent="$(dirname "$src")"
  debian_tar="$(ensure_debian_tarball "$parent")" || return 1
  echo "==> packaging patch changed; restoring debian/rules from $(basename "$debian_tar")"
  tar -xOf "$debian_tar" debian/rules >"$src/debian/rules"
  echo "==> re-applying $patch (build-gtk4/ kept)"
  (
    cd "$src"
    patch -p1 <"$patch"
  )
}
