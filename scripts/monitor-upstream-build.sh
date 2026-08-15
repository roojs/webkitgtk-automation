#!/usr/bin/env bash
# Compare archive webkit2gtk to tracked state; pretest and push a build-* tag when newer.
#
# Usage (CI):
#   ./scripts/monitor-upstream-build.sh
#
# Env:
#   SERIES          Ubuntu series (default: noble)
#   DRY_RUN=1       Log actions only; do not commit, tag, or push
#   FORCE_BUILD=1   Build even when upstream matches tracked (pretest still required)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERIES="${SERIES:-noble}"
TRACKED_FILE="$REPO_ROOT/.github/tracked-upstream-version"
PENDING_FILE="$REPO_ROOT/.github/pending-upstream-version"
SUFFIX="${SUFFIX:-+webkitgtk1}"

read_state_file() {
  local file="$1"
  [[ -f "$file" ]] || { echo ""; return 0; }
  awk '!/^[[:space:]]*#/ && !/^[[:space:]]*$/ { line=$0 } END { gsub(/[[:space:]]/, "", line); print line }' "$file"
}

write_state_file() {
  local file="$1" value="$2" header="$3"
  cat >"$file" <<EOF
$header
$value

EOF
}

sanitize_tag_suffix() {
  # GitHub tag names: avoid +, spaces, etc.
  echo "$1" | tr '+/' '--'
}

current="$("$REPO_ROOT/scripts/upstream-webkit-version.sh" "$SERIES")"
tracked="$(read_state_file "$TRACKED_FILE")"
pending="$(read_state_file "$PENDING_FILE")"

echo "==> monitor series=$SERIES"
echo "==> archive webkit2gtk source version: $current"
echo "==> tracked (last successful build): ${tracked:-<none>}"
echo "==> pending (in-flight auto-build): ${pending:-<none>}"

if [[ -n "${FORCE_BUILD:-}" && "${FORCE_BUILD}" != "0" ]]; then
  echo "==> FORCE_BUILD=1: will run pretest and queue a build"
elif [[ "$current" == "$tracked" ]]; then
  echo "==> up to date; no build needed"
  exit 0
elif [[ "$current" == "$pending" ]]; then
  echo "==> build already queued for $current; waiting for CI"
  exit 0
fi

echo "==> new upstream version detected ($tracked -> $current)"

echo "==> running script tests"
chmod +x "$REPO_ROOT/scripts/test-build-scripts.sh" "$REPO_ROOT/scripts/pretest-patch.sh"
SERIES="$SERIES" "$REPO_ROOT/scripts/test-build-scripts.sh"

if [[ "${DRY_RUN:-}" == "1" ]]; then
  tag="build-upstream-$(sanitize_tag_suffix "$current")"
  echo "==> DRY_RUN=1: would set pending=$current and push tag $tag"
  exit 0
fi

write_state_file "$PENDING_FILE" "$current" "# Upstream webkit2gtk version queued for an in-flight auto-build (empty = none)."

tag="build-upstream-$(sanitize_tag_suffix "$current")"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "==> tag $tag already exists; leaving pending=$current and exiting"
  git add "$PENDING_FILE"
  git config user.name "github-actions[bot]"
  git config user.email "github-actions[bot]@users.noreply.github.com"
  git commit -m "Monitor: mark upstream webkit2gtk $current pending (tag exists)" || true
  git push origin HEAD
  exit 0
fi

git add "$PENDING_FILE"
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git commit -m "Monitor: queue build for upstream webkit2gtk $current"

git tag -a "$tag" -m "Auto-build for upstream webkit2gtk $current (${SERIES}, suffix ${SUFFIX})"
git push origin HEAD "$tag"
echo "==> pushed $tag (triggers build workflow)"
