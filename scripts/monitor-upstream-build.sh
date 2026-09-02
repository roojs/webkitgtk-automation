#!/usr/bin/env bash
# Follow Ubuntu archive webkit2gtk for SERIES: pretest and push a build tag when newer.
#
# Usage (CI):
#   ./scripts/monitor-upstream-build.sh
#
# Env:
#   SERIES          Ubuntu series (default: resolute)
#   DRY_RUN=1       Log actions only; do not commit, tag, or push
#   FORCE_BUILD=1   Build even when upstream matches tracked (pretest still required)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/pinned-webkit-version.sh
source "$REPO_ROOT/scripts/lib/pinned-webkit-version.sh"
# shellcheck source=scripts/lib/series-registry.sh
source "$REPO_ROOT/scripts/lib/series-registry.sh"
SERIES="${SERIES:-resolute}"
TRACKED_FILE="$REPO_ROOT/.github/tracked-upstream-version"
PENDING_FILE="$REPO_ROOT/.github/pending-upstream-version"
PINNED_FILE="$(pinned_webkit_version_file)"
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
  echo "$1" | tr '+/' '--'
}

upstream_build_tag() {
  local version="$1"
  build_release_tag "$SERIES" "upstream-$(sanitize_tag_suffix "$version")"
}

restore_pinned_file() {
  git checkout -- "$PINNED_FILE" 2>/dev/null || true
}

run_pretest() {
  echo "==> running pretest for archive webkit2gtk $1"
  chmod +x "$REPO_ROOT/scripts/run-pretest.sh"
  if ! command -v dh_listpackages >/dev/null 2>&1; then
    echo "==> installing pretest deps"
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      devscripts debhelper fakeroot zstd binutils-gold curl
  fi
  REFRESH=1 SERIES="$SERIES" "$REPO_ROOT/scripts/run-pretest.sh" "$SERIES"
}

commit_and_push() {
  local message="$1"
  shift
  git add "$@"
  git config user.name "github-actions[bot]"
  git config user.email "github-actions[bot]@users.noreply.github.com"
  git commit -m "$message"
  git push origin HEAD
}

current="$("$REPO_ROOT/scripts/upstream-webkit-version.sh" "$SERIES")"
pinned="$(read_pinned_webkit_version "$SERIES")"
tracked="$(read_state_file "$TRACKED_FILE")"
pending="$(read_state_file "$PENDING_FILE")"
pin_synced=0

echo "==> monitor series=$SERIES"
echo "==> archive webkit2gtk source version: $current"
echo "==> pinned (build target): $pinned"
echo "==> tracked (last successful build): ${tracked:-<none>}"
echo "==> pending (in-flight auto-build): ${pending:-<none>}"

if [[ "$pinned" != "$current" ]]; then
  echo "==> syncing pin to archive: $pinned -> $current"
  write_pinned_webkit_version "$SERIES" "$current"
  pinned="$current"
  pin_synced=1
fi

need_build=0
if [[ -n "${FORCE_BUILD:-}" && "${FORCE_BUILD}" != "0" ]]; then
  echo "==> FORCE_BUILD=1: will run pretest and queue a build"
  need_build=1
elif [[ "$current" == "$tracked" ]]; then
  if [[ "$pin_synced" == "1" ]]; then
    if [[ "${DRY_RUN:-}" == "1" ]]; then
      echo "==> DRY_RUN=1: would commit pin sync to $current"
    else
      commit_and_push "Monitor: sync pin to archive webkit2gtk $current" "$PINNED_FILE"
    fi
  else
    echo "==> up to date; no build needed"
  fi
  exit 0
elif [[ "$current" == "$pending" ]]; then
  echo "==> build already queued for $current; waiting for CI"
  exit 0
else
  echo "==> new upstream version ($tracked -> $current); pretest then queue build"
  need_build=1
fi

if [[ "$need_build" != "1" ]]; then
  exit 0
fi

if ! run_pretest "$current"; then
  echo "==> pretest failed for $current; reverting pin sync" >&2
  restore_pinned_file
  exit 1
fi

if [[ "${DRY_RUN:-}" == "1" ]]; then
  tag="$(upstream_build_tag "$current")"
  echo "==> DRY_RUN=1: would set pending=$current, commit pin, and push tag $tag"
  restore_pinned_file
  exit 0
fi

write_state_file "$PENDING_FILE" "$current" "# Upstream webkit2gtk version queued for an in-flight auto-build (empty = none)."

tag="$(upstream_build_tag "$current")"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "==> tag $tag already exists; marking pending=$current"
  commit_and_push "Monitor: mark upstream webkit2gtk $current pending (tag exists)" \
    "$PINNED_FILE" "$PENDING_FILE"
  exit 0
fi

commit_and_push "Monitor: follow upstream webkit2gtk $current" \
  "$PINNED_FILE" "$PENDING_FILE"

git tag -a "$tag" -m "Auto-build for upstream webkit2gtk $current (${SERIES}, suffix ${SUFFIX})"
git push origin "$tag"
echo "==> pushed $tag (triggers build workflow)"
