#!/usr/bin/env bash
# Log / save packaging fixture state for reproducing simulate dh-check locally.

dump_section() {
  local title="$1"
  echo ""
  echo "========== $title =========="
}

dump_file_if_exists() {
  local path="$1" label="${2:-$1}"
  if [[ -f "$path" ]]; then
    echo "--- $label ---"
    cat "$path"
    echo ""
  else
    echo "--- $label (missing) ---"
  fi
}

dump_path_list() {
  local root="$1" label="$2"
  echo "--- $label ---"
  if [[ -d "$root" ]]; then
    find "$root" \( -type f -o -type l \) | sort
    echo "(total: $(find "$root" \( -type f -o -type l \) | wc -l) paths)"
  else
    echo "(directory missing: $root)"
  fi
  echo ""
}

dump_elf_summary() {
  local root="$1" label="$2"
  echo "--- $label (ELF / size) ---"
  if [[ -d "$root" ]]; then
    find "$root" -type f -name '*.so*' -print0 \
      | xargs -0 -r ls -la
    echo ""
    if command -v sha256sum >/dev/null 2>&1; then
      find "$root" -type f -name '*.so*' -print0 \
        | xargs -0 -r sha256sum
    fi
  else
    echo "(directory missing: $root)"
  fi
  echo ""
}

# Write the same content to SIMULATE_DUMP_DIR when set (for CI artifacts).
# (Text manifests and path lists are copied in dump_packaging_fixture_state.)

dump_packaging_fixture_state() {
  local src="$1" stage="$2"
  local dump_dir="${SIMULATE_DUMP_DIR:-}"
  local stage_dir="$dump_dir/$stage"

  dump_section "packaging fixture dump: $stage (SERIES=${SERIES:-?})"

  if [[ -n "$dump_dir" ]]; then
    mkdir -p "$stage_dir"
    echo "==> writing fixture dump to $stage_dir"
  fi

  if [[ -f "$src/.webkitgtk-automation-prepared" ]]; then
    dump_file_if_exists "$src/.webkitgtk-automation-prepared" "marker .webkitgtk-automation-prepared"
    if [[ -n "$dump_dir" ]]; then
      cp -a "$src/.webkitgtk-automation-prepared" "$stage_dir/marker.txt"
    fi
  fi

  for install in \
    "$src/debian/libwebkitgtk-6.0-webdriver4.install" \
    "$src/debian/libwebkitgtk-6.0-webdriver-dev.install"; do
    dump_file_if_exists "$install" "$(basename "$install")"
    if [[ -n "$dump_dir" && -f "$install" ]]; then
      cp -a "$install" "$stage_dir/"
    fi
  done

  if [[ -f "$src/debian/clean" ]]; then
    dump_file_if_exists "$src/debian/clean" "debian/clean"
    if [[ -n "$dump_dir" ]]; then
      cp -a "$src/debian/clean" "$stage_dir/debian-clean.txt"
    fi
  fi

  if [[ -f "$src/debian/webkitgtk-6.0-webdriver.pc" ]]; then
    dump_file_if_exists "$src/debian/webkitgtk-6.0-webdriver.pc" "webkitgtk-6.0-webdriver.pc"
    if [[ -n "$dump_dir" ]]; then
      cp -a "$src/debian/webkitgtk-6.0-webdriver.pc" "$stage_dir/"
    fi
  fi

  if [[ -f "$src/debian/libwebkitgtk-6.0-webdriver4.substvars" ]]; then
    dump_file_if_exists "$src/debian/libwebkitgtk-6.0-webdriver4.substvars" "substvars"
    if [[ -n "$dump_dir" ]]; then
      cp -a "$src/debian/libwebkitgtk-6.0-webdriver4.substvars" "$stage_dir/"
    fi
  fi

  dump_path_list "$src/debian/tmp" "debian/tmp paths"
  if [[ -n "$dump_dir" && -d "$src/debian/tmp" ]]; then
    find "$src/debian/tmp" \( -type f -o -type l \) | sort >"$stage_dir/debian-tmp.paths"
  fi

  dump_path_list "$src/debian/libwebkitgtk-6.0-webdriver4" "debian/libwebkitgtk-6.0-webdriver4 paths"
  if [[ -n "$dump_dir" && -d "$src/debian/libwebkitgtk-6.0-webdriver4" ]]; then
    find "$src/debian/libwebkitgtk-6.0-webdriver4" \( -type f -o -type l \) | sort \
      >"$stage_dir/package-tree.paths"
  fi

  dump_elf_summary "$src/debian/libwebkitgtk-6.0-webdriver4" "package .so files"
  if [[ -n "$dump_dir" && -d "$src/debian/libwebkitgtk-6.0-webdriver4" ]]; then
    find "$src/debian/libwebkitgtk-6.0-webdriver4" -type f -name '*.so*' -print0 \
      | xargs -0 -r sha256sum >"$stage_dir/package-so.sha256" 2>/dev/null || true
  fi
}

simulate_dump_enabled() {
  [[ "${SIMULATE_DUMP:-}" == "1" ]] || [[ "${GITHUB_ACTIONS:-}" == "true" ]]
}
