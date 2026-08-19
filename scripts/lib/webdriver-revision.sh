#!/usr/bin/env bash
# Per-series Debian package suffix (+webdriverN) for parallel-install rebuilds.
set -euo pipefail

WEBDRIVER_REVISION_FILE="${WEBDRIVER_REVISION_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.github/webdriver-revision}"

webdriver_revision_for_series() {
  local series="$1" line key val
  [[ -f "$WEBDRIVER_REVISION_FILE" ]] || {
    echo "error: missing $WEBDRIVER_REVISION_FILE" >&2
    return 1
  }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    if [[ "$key" == "$series" ]]; then
      echo "$val"
      return 0
    fi
  done <"$WEBDRIVER_REVISION_FILE"
  echo "error: no package revision for series=$series in $WEBDRIVER_REVISION_FILE" >&2
  return 1
}

next_webdriver_suffix() {
  local series="$1" revision
  revision="$(webdriver_revision_for_series "$series")"
  echo "+webdriver$((revision + 1))"
}

suffix_to_revision() {
  local suffix="$1"
  if [[ "$suffix" =~ ^\+webdriver([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  echo "error: expected +webdriverN suffix, got: $suffix" >&2
  return 1
}

record_webdriver_revision() {
  local series="$1" suffix="$2" revision tmp current
  revision="$(suffix_to_revision "$suffix")"
  current="$(webdriver_revision_for_series "$series")"
  if (( revision <= current )); then
    echo "error: refusing to record non-increasing revision for $series ($suffix <= +webdriver$current)" >&2
    return 1
  fi
  tmp="$(mktemp)"
  awk -v series="$series" -v revision="$revision" '
    BEGIN { updated = 0 }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
    {
      key = $0
      sub(/=.*/, "", key)
      if (key == series) {
        print key "=" revision
        updated = 1
      } else {
        print $0
      }
    }
    END {
      if (!updated) {
        print "error: series not found in revision file" > "/dev/stderr"
        exit 1
      }
    }
  ' "$WEBDRIVER_REVISION_FILE" >"$tmp"
  mv "$tmp" "$WEBDRIVER_REVISION_FILE"
}
