#!/usr/bin/env bash
# Shared checks for whether build-gtk4/ can resume dpkg-buildpackage -nc safely.

gtk4_build_tree_looks_complete() {
  local src="${1:-.}"
  [[ -f "$src/build-gtk4/build.ninja" ]] \
    && [[ -f "$src/build-gtk4/CMakeCache.txt" ]] \
    && [[ -f "$src/build-gtk4/CMakeFiles/VerifyGlobs.cmake" ]] \
    && grep -q 'CMAKE_GENERATOR:INTERNAL=Ninja' "$src/build-gtk4/CMakeCache.txt"
}
