#!/usr/bin/env bash
# Resolve the patch file for a Ubuntu series via the series registry.

# shellcheck source=scripts/lib/series-registry.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/series-registry.sh"

patch_for_series() {
  patch_file_for_series "$1"
}
