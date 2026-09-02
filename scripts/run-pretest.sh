#!/usr/bin/env bash
# Single pretest entry point for CI and local use — same checks build workflows rely on.
#
# Usage:
#   ./scripts/run-pretest.sh              # host series
#   ./scripts/run-pretest.sh plucky
#   PRETEST_FAST=0 ./scripts/run-pretest.sh resolute   # include slow apt/dh paths
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/host-series.sh
source "$REPO_ROOT/scripts/lib/host-series.sh"

SERIES="${SERIES:-${1:-$(host_series)}}"
SERIES="${SERIES:-resolute}"
PRETEST_FAST="${PRETEST_FAST:-1}"
export SERIES PRETEST_FAST

chmod +x \
  "$REPO_ROOT/scripts/fetch-fixtures.sh" \
  "$REPO_ROOT/scripts/test-build-scripts.sh" \
  "$REPO_ROOT/scripts/pretest-patch.sh" \
  "$REPO_ROOT/scripts/pretest-webkit-patches.sh"

"$REPO_ROOT/scripts/fetch-fixtures.sh" "$SERIES"
"$REPO_ROOT/scripts/test-build-scripts.sh"
