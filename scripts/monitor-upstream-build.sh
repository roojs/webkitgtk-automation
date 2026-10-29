#!/usr/bin/env bash
# Follow Ubuntu archive webkit2gtk for CI series: sync pins, pretest, push build tags.
#
# Usage (CI):
#   ./scripts/monitor-upstream-build.sh
#
# Env:
#   SERIES              Optional single series (default: all in MONITOR_BUILD_SERIES)
#   DRY_RUN=1           Log actions only; do not commit, tag, or push
#   FORCE_BUILD=1       Build even when upstream matches tracked (pretest still required)
#   MONITOR_BUILD_SERIES       Space-separated series to auto-build (default: plucky questing resolute stonking)
#   MONITOR_PIN_SYNC_SERIES    Space-separated series to sync in pinned-webkit-version (includes noble)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/pinned-webkit-version.sh
source "$REPO_ROOT/scripts/lib/pinned-webkit-version.sh"
# shellcheck source=scripts/lib/tracked-upstream-version.sh
source "$REPO_ROOT/scripts/lib/tracked-upstream-version.sh"
# shellcheck source=scripts/lib/series-registry.sh
source "$REPO_ROOT/scripts/lib/series-registry.sh"

PINNED_FILE="$(pinned_webkit_version_file)"
PENDING_FILE="$(pending_upstream_version_file)"
SUFFIX="${SUFFIX:-+webkitgtk1}"

sanitize_tag_suffix() {
  echo "$1" | tr '+/' '--'
}

upstream_build_tag() {
  local series="$1" version="$2"
  build_release_tag "$series" "upstream-$(sanitize_tag_suffix "$version")"
}

run_pretest() {
  local series="$1" version="$2"
  echo "==> running pretest for $series archive webkit2gtk $version"
  chmod +x "$REPO_ROOT/scripts/run-pretest.sh"
  if ! command -v dh_listpackages >/dev/null 2>&1; then
    echo "==> installing pretest deps"
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      devscripts debhelper fakeroot zstd binutils-gold curl
  fi
  REFRESH=1 SERIES="$series" "$REPO_ROOT/scripts/run-pretest.sh" "$series"
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

pending_build_failed() {
  local series="$1" tag="$2"
  command -v gh >/dev/null 2>&1 || return 1
  local conclusion
  conclusion="$(
    gh run list \
      --workflow "build-${series}.yml" \
      --event push \
      --branch "$tag" \
      --limit 1 \
      --json conclusion \
      -q '.[0].conclusion' 2>/dev/null || true
  )"
  [[ "$conclusion" == "failure" || "$conclusion" == "cancelled" ]]
}

sync_pin_if_needed() {
  local series="$1" current="$2"
  local pinned
  pinned="$(read_pinned_webkit_version "$series")"
  if [[ "$pinned" == "$current" ]]; then
    return 1
  fi
  echo "==> [$series] syncing pin to archive: $pinned -> $current"
  write_pinned_webkit_version "$series" "$current"
  return 0
}

process_build_series() {
  local series="$1"
  local current pinned tracked pending need_build=0 tag

  current="$("$REPO_ROOT/scripts/upstream-webkit-version.sh" "$series")"
  pinned="$(read_pinned_webkit_version "$series")"
  tracked="$(read_tracked_upstream_version "$series")"
  pending="$(read_pending_upstream_version "$series")"

  echo "==> monitor series=$series"
  echo "==> archive webkit2gtk source version: $current"
  echo "==> pinned (build target): $pinned"
  echo "==> tracked (last successful build): ${tracked:-<none>}"
  echo "==> pending (in-flight auto-build): ${pending:-<none>}"

  if [[ -n "${FORCE_BUILD:-}" && "${FORCE_BUILD}" != "0" ]]; then
    echo "==> FORCE_BUILD=1: will run pretest and queue a build for $series"
    need_build=1
  elif [[ -n "$tracked" && "$tracked" == "$current" ]]; then
    echo "==> [$series] up to date; no build needed"
    return 0
  elif [[ -z "$tracked" ]]; then
    echo "==> [$series] no successful release recorded yet; will build archive $current"
    need_build=1
  elif [[ "$current" == "$pending" ]]; then
    tag="$(upstream_build_tag "$series" "$current")"
    if pending_build_failed "$series" "$tag"; then
      echo "==> [$series] pending build for $current failed; clearing pending to requeue"
      clear_pending_upstream_version "$series"
      pending=""
    else
      echo "==> [$series] build already queued for $current; waiting for CI"
      return 0
    fi
  fi

  if [[ "$need_build" != "1" ]]; then
    if dpkg_version_lt "$tracked" "$current"; then
      echo "==> [$series] new upstream version ($tracked -> $current); pretest then queue build"
      need_build=1
    else
      echo "==> [$series] archive ($current) is not newer than tracked ($tracked); skipping build"
      return 0
    fi
  fi

  if ! run_pretest "$series" "$current"; then
    echo "==> pretest failed for $series $current" >&2
    git checkout -- "$PINNED_FILE" 2>/dev/null || true
    return 1
  fi

  if [[ "${DRY_RUN:-}" == "1" ]]; then
    tag="$(upstream_build_tag "$series" "$current")"
    echo "==> DRY_RUN=1: would set pending=$current, commit state, and push tag $tag"
    return 0
  fi

  write_pending_upstream_version "$series" "$current"

  tag="$(upstream_build_tag "$series" "$current")"
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    echo "==> tag $tag already exists; marking pending=$current for $series"
    commit_and_push "Monitor: mark upstream webkit2gtk $current pending for $series (tag exists)" \
      "$PINNED_FILE" "$PENDING_FILE"
    return 0
  fi

  commit_and_push "Monitor: follow upstream webkit2gtk $current ($series)" \
    "$PINNED_FILE" "$PENDING_FILE"

  git tag -a "$tag" -m "Auto-build for upstream webkit2gtk $current (${series}, suffix ${SUFFIX})"
  git push origin "$tag"
  echo "==> pushed $tag (triggers build workflow)"
}

build_series=()
if [[ -n "${SERIES:-}" ]]; then
  build_series=("$SERIES")
else
  read -r -a build_series <<<"$(monitor_build_series_list)"
fi

read -r -a pin_series <<<"$(monitor_pin_sync_series_list)"

pin_changed=0
for series in "${pin_series[@]}"; do
  [[ -n "$series" ]] || continue
  series_registered "$series" || continue
  current="$("$REPO_ROOT/scripts/upstream-webkit-version.sh" "$series")"
  if sync_pin_if_needed "$series" "$current"; then
    pin_changed=1
  fi
done

if [[ "$pin_changed" == "1" && "${DRY_RUN:-}" != "1" ]]; then
  commit_and_push "Monitor: sync pinned webkit2gtk versions to archive" "$PINNED_FILE"
fi

for series in "${build_series[@]}"; do
  [[ -n "$series" ]] || continue
  series_registered "$series" || {
    echo "error: series=$series not registered" >&2
    exit 1
  }
  process_build_series "$series"
done
