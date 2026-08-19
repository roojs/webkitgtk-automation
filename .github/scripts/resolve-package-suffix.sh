#!/usr/bin/env bash
# Print the Debian package suffix (+webdriverN) for a series build.
#
# Usage:
#   .github/scripts/resolve-package-suffix.sh questing
#   SUFFIX=+webdriver3 .github/scripts/resolve-package-suffix.sh questing   # explicit override
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/webdriver-revision.sh
source "$REPO_ROOT/scripts/lib/webdriver-revision.sh"

SERIES="${1:?series required}"

if [[ -n "${SUFFIX:-}" ]]; then
  printf '%s\n' "$SUFFIX"
  exit 0
fi

next_webdriver_suffix "$SERIES"
