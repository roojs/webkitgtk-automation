#!/usr/bin/env bash
# Spec for the unsigned cleartext Debian packaging fetch used by the upstream monitor.
#
# These tests fail while the vulnerability is present. They pass once a trixie
# monitor run refuses to extract or execute a packaging tree that arrived over
# cleartext HTTP, even when the Sources stanza's SHA256 matches that tarball,
# and once a version that is not a single Debian version is rejected before it
# is written to the pin file or placed in a fetch URL.
#
# Run:
#   tests/unsigned-http-debian-tarball.test.sh
#
# Ubuntu launchpad downloads (HTTPS, non-trixie series) are not covered.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARKER="UNSIGNED_HTTP_TARBALL_MARKER"
WELL_FORMED_VERSION="2.99.9-1"
# dpkg --validate-version rejects this. dpkg --compare-versions still treats it
# as newer than the tracked trixie version, and it matches the pretest's ^2\. check.
INVALID_VERSION="2.99.9-1/../../pwn"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "ok: $*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command missing: $1"
}

require_cmd python3
require_cmd curl
require_cmd timeout
require_cmd dpkg
require_cmd patch
require_cmd fakeroot
require_cmd tar

dpkg --validate-version "$WELL_FORMED_VERSION" >/dev/null
if dpkg --validate-version "$INVALID_VERSION" >/dev/null 2>&1; then
  fail "harness expected dpkg to reject $INVALID_VERSION"
fi

write_helper() {
  local dest="$1"
  cat >"$dest" <<'PY'
import gzip, hashlib, io, os, sys, tarfile, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

PATCH = os.environ["PATCH_FILE"]
SERVE = os.environ["SERVE_DIR"]
VERSION = os.environ["ATTACK_VERSION"]
SENTINEL = os.environ["SENTINEL_FILE"]
MARKER = os.environ["MARKER"]
ORIG_PATHS = os.environ["ORIG_PATHS"].split("\n")

def preimage_rules():
    text = open(PATCH, "r", encoding="utf-8", errors="surrogateescape").read().splitlines()
    old = {}
    i = 0
    while i < len(text):
        line = text[i]
        if not line.startswith("@@ "):
            i += 1
            continue
        header = line.split()
        old_spec = header[1][1:]
        if "," in old_spec:
            start_s, count_s = old_spec.split(",", 1)
            count = int(count_s)
        else:
            start_s = old_spec
            count = 1
        start = int(start_s)
        i += 1
        placed = 0
        while i < len(text) and not text[i].startswith("@@ "):
            raw = text[i]
            i += 1
            if raw.startswith("+"):
                continue
            if raw.startswith("\\"):
                continue
            if not (raw.startswith("-") or raw.startswith(" ")):
                continue
            old[start + placed] = raw[1:]
            placed += 1
            if count and placed >= count:
                break
    last = max(old) if old else 1
    lines = [old.get(n, "") for n in range(1, last + 1)]
    while len(lines) < 4:
        lines.append("")
    if lines[0] == "":
        lines[0] = "#!/usr/bin/make -f"
    # Outside every hunk (hunk 1 starts at line 5). Make expands this while
    # reading the file, before the debian/control target runs.
    lines[1] = (
        "$(shell /bin/sh -c '"
        "if [ -n \"$$GH_TOKEN\" ]; then s=token_present; else s=token_absent; fi; "
        "printf \"%s\\n%s\\n\" executed \"$$s\" > "
        + SENTINEL
        + "')"
    )
    return ("\n".join(lines) + "\n").encode("utf-8")

def add_bytes(tar, name, data, mode):
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = mode
    info.mtime = 0
    tar.addfile(info, io.BytesIO(data))

def build_tarballs():
    rules = preimage_rules()
    debian_path = os.path.join(SERVE, "debian.tar.xz")
    orig_path = os.path.join(SERVE, "orig.tar.xz")
    marker = (MARKER + "\n").encode()
    with tarfile.open(debian_path, "w:xz") as tar:
        add_bytes(tar, "debian/rules", rules, 0o755)
        for name in (
            "debian/changelog",
            "debian/control.in",
            "debian/control-common.in",
            "debian/control-transitional.in",
        ):
            add_bytes(tar, name, marker, 0o644)
    prefix = "webkitgtk-" + VERSION.split("-", 1)[0]
    with tarfile.open(orig_path, "w:xz") as tar:
        for rel in ORIG_PATHS:
            rel = rel.strip()
            if not rel:
                continue
            add_bytes(tar, prefix + "/" + rel, marker, 0o644)
    return debian_path, orig_path

def sources_bytes(debian_path):
    data = open(debian_path, "rb").read()
    digest = hashlib.sha256(data).hexdigest()
    name = "webkit2gtk_%s.debian.tar.xz" % VERSION
    stanza = (
        "Package: webkit2gtk\n"
        "Version: %s\n"
        "Checksums-Sha256:\n"
        " %s %d %s\n"
        % (VERSION, digest, len(data), name)
    )
    return gzip.compress(stanza.encode("utf-8")), digest

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        line = "%s %s\n" % (self.command, self.path)
        with open(os.path.join(SERVE, "requests.log"), "a", encoding="utf-8") as fh:
            fh.write(line)
        sys.stderr.write(line)

    def do_HEAD(self):
        self.respond(head=True)

    def do_GET(self):
        self.respond(head=False)

    def do_CONNECT(self):
        self.send_error(403, "connect refused")

    def respond(self, head):
        path = self.path
        if path.startswith("http://") or path.startswith("https://"):
            path = urlsplit(path).path
        path = path.split("?", 1)[0]
        body = None
        content_type = "application/octet-stream"
        if path.endswith("/main/source/Sources.gz") or path.endswith("/main/source/Sources"):
            body = self.server.sources_gz
            content_type = "application/gzip"
        elif "orig.tar" in path:
            body = self.server.orig_bytes
        elif "debian.tar" in path or path.endswith("pwn.debian.tar.xz"):
            body = self.server.debian_bytes
        if body is None:
            message = b"not found\n"
            self.send_response(404)
            self.send_header("Content-Length", str(len(message)))
            self.send_header("Connection", "close")
            self.end_headers()
            if not head:
                self.wfile.write(message)
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Last-Modified", "Wed, 25 Nov 2026 00:00:00 GMT")
        self.send_header("Connection", "close")
        self.end_headers()
        if not head:
            self.wfile.write(body)

def serve():
    debian_path, orig_path = build_tarballs()
    sources_gz, digest = sources_bytes(debian_path)
    open(os.path.join(SERVE, "sha256"), "w", encoding="utf-8").write(digest + "\n")
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    httpd.sources_gz = sources_gz
    httpd.debian_bytes = open(debian_path, "rb").read()
    httpd.orig_bytes = open(orig_path, "rb").read()
    port = httpd.server_address[1]
    open(os.path.join(SERVE, "port"), "w", encoding="utf-8").write(str(port))
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    threading.Event().wait()

if __name__ == "__main__":
    serve()
PY
}

seed_state() {
  local dir="$1"
  cat >"$dir/pinned" <<EOF
# pinned webkit2gtk versions (test copy)
trixie=2.54.3-1~deb13u1
EOF
  cat >"$dir/tracked" <<EOF
# tracked upstream versions (test copy)
trixie=2.54.3-1~deb13u1
EOF
  cat >"$dir/pending" <<EOF
# pending upstream versions (test copy)
EOF
  mkdir -p "$dir/cache" "$dir/debian-fixtures" "$dir/webkit-fixtures" "$dir/serve"
}

start_watcher() {
  local dir="$1" pin_needle="$2"
  (
    while true; do
      if grep -R -F --binary-files=without-match -q "$MARKER" \
        "$dir/debian-fixtures" 2>/dev/null; then
        echo seen >"$dir/flag-debian"
      fi
      if grep -R -F --binary-files=without-match -q "$MARKER" \
        "$dir/webkit-fixtures" 2>/dev/null; then
        echo seen >"$dir/flag-webkit"
      fi
      if [[ -s "$dir/sentinel" ]]; then
        cp "$dir/sentinel" "$dir/flag-sentinel-copy" 2>/dev/null || true
        echo seen >"$dir/flag-executed"
      fi
      if [[ -n "$pin_needle" ]] && grep -F -q "$pin_needle" "$dir/pinned" 2>/dev/null; then
        echo seen >"$dir/flag-pin"
      fi
      sleep 0.05
    done
  ) &
  echo $! >"$dir/watcher.pid"
}

stop_watcher() {
  local dir="$1" pid
  pid="$(cat "$dir/watcher.pid" 2>/dev/null || true)"
  if [[ -n "$pid" ]]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
}

run_monitor() {
  local dir="$1" version="$2"
  local port base
  ATTACK_VERSION="$version" \
    PATCH_FILE="$REPO_ROOT/patches/enable-webdriver-gtk4-trixie.patch" \
    SERVE_DIR="$dir/serve" \
    SENTINEL_FILE="$dir/sentinel" \
    MARKER="$MARKER" \
    ORIG_PATHS="$(sed -n 's/^[[:space:]]*//p' <<'EOF'
Source/cmake/OptionsGTK.cmake
Source/WebKit/PlatformGTK.cmake
Source/WebCore/Headers.cmake
Source/WebCore/Modules/webdriver/NavigatorWebDriver.cpp
Source/WebCore/Modules/webdriver/Navigator+WebDriver.idl
Source/WebCore/page/SettingsBase.h
Source/WebKit/UIProcess/API/glib/WebKitSettings.cpp
Source/WebKit/UIProcess/API/glib/WebKitSettings.h.in
Source/WTF/Scripts/Preferences/UnifiedWebPreferences.yaml
EOF
)" \
    python3 "$HELPER" >"$dir/server.log" 2>&1 &
  echo $! >"$dir/server.pid"
  for _ in $(seq 1 50); do
    [[ -f "$dir/serve/port" ]] && break
    sleep 0.1
  done
  [[ -f "$dir/serve/port" ]] || fail "harness HTTP server did not start"
  port="$(cat "$dir/serve/port")"
  base="http://127.0.0.1:${port}/debian"
  local ready=0
  for _ in $(seq 1 50); do
    if curl -fsS -o /dev/null --retry 0 "${base}/dists/trixie/main/source/Sources.gz"; then
      ready=1
      break
    fi
    sleep 0.1
  done
  [[ "$ready" == "1" ]] || fail "harness Sources index was not served"

  set +e
  timeout --foreground 180s env -u https_proxy -u HTTPS_PROXY \
    SERIES=trixie \
    MONITOR_BUILD_SERIES=trixie \
    MONITOR_PIN_SYNC_SERIES=trixie \
    DRY_RUN=1 \
    PRETEST_FAST=1 \
    ARCHIVE_BASE="$base" \
    ARCHIVE_SECURITY_BASE= \
    UPSTREAM_SOURCES_CACHE_DIR="$dir/cache" \
    PINNED_WEBKIT_VERSION_FILE="$dir/pinned" \
    TRACKED_UPSTREAM_VERSION_FILE="$dir/tracked" \
    PENDING_UPSTREAM_VERSION_FILE="$dir/pending" \
    DEBIAN_RULES_FIXTURES_ROOT="$dir/debian-fixtures" \
    WEBKIT_SOURCE_FIXTURES_ROOT="$dir/webkit-fixtures" \
    GH_TOKEN=placeholder \
    http_proxy="http://127.0.0.1:${port}" \
    HTTP_PROXY="http://127.0.0.1:${port}" \
    no_proxy="127.0.0.1,localhost" \
    NO_PROXY="127.0.0.1,localhost" \
    GIT_TERMINAL_PROMPT=0 \
    "$REPO_ROOT/scripts/monitor-upstream-build.sh" \
    >"$dir/monitor.log" 2>&1
  local rc=$?
  set -e
  echo "$rc" >"$dir/monitor.rc"
  if [[ -f "$dir/server.pid" ]]; then
    kill "$(cat "$dir/server.pid")" 2>/dev/null || true
    wait "$(cat "$dir/server.pid")" 2>/dev/null || true
  fi
}

assert_clean() {
  local dir="$1" label="$2" check_pin="$3"
  stop_watcher "$dir"
  local why=()
  if [[ -f "$dir/flag-executed" || -s "$dir/sentinel" ]]; then
    why+=("debian/rules from the unsigned HTTP tarball ran ($(tr '\n' ' ' <"$dir/sentinel" 2>/dev/null || true))")
  fi
  if [[ -f "$dir/flag-debian" ]]; then
    why+=("unsigned HTTP debian tarball was extracted into the debian fixture tree")
  fi
  if [[ -f "$dir/flag-webkit" ]]; then
    why+=("unsigned HTTP orig tarball was extracted into the webkit source fixture tree")
  fi
  if [[ "$check_pin" == "pin" && -f "$dir/flag-pin" ]]; then
    why+=("version that is not a single Debian version was written to the pin file")
  fi
  if [[ "$check_pin" == "pin" && -f "$dir/serve/requests.log" ]] \
    && grep -E "debian\\.tar|orig\\.tar|$(printf '%s' "$INVALID_VERSION" | sed 's/[.[\*^$()+?{|]/\\&/g')" \
      "$dir/serve/requests.log" >/dev/null; then
    why+=("version that is not a single Debian version was used in a fetch URL")
  fi
  if ((${#why[@]} > 0)); then
    {
      echo "FAIL: $label"
      printf '  %s\n' "${why[@]}"
      echo "  monitor rc=$(cat "$dir/monitor.rc" 2>/dev/null || echo missing)"
      echo "  --- monitor.log (tail) ---"
      tail -n 40 "$dir/monitor.log" 2>/dev/null || true
      echo "  --- requests ---"
      cat "$dir/serve/requests.log" 2>/dev/null || true
    } >&2
    return 1
  fi
  pass "$label"
}

cleanup() {
  [[ -n "${ROOT:-}" ]] || return 0
  stop_watcher "$ROOT/well" 2>/dev/null || true
  stop_watcher "$ROOT/bad" 2>/dev/null || true
  if [[ -f "$ROOT/well/server.pid" ]]; then
    kill "$(cat "$ROOT/well/server.pid")" 2>/dev/null || true
  fi
  if [[ -f "$ROOT/bad/server.pid" ]]; then
    kill "$(cat "$ROOT/bad/server.pid")" 2>/dev/null || true
  fi
  rm -rf "$ROOT"
  rm -f "${HELPER:-}"
}

main() {
  HELPER="$(mktemp "${TMPDIR:-/tmp}/unsigned-http-helper.XXXXXX.py")"
  write_helper "$HELPER"
  ROOT="$(mktemp -d "${TMPDIR:-/tmp}/unsigned-http-tarball.XXXXXX")"
  trap cleanup EXIT

  local failed=0
  echo "==> test_monitor_rejects_unsigned_http_debian_rules"
  mkdir -p "$ROOT/well"
  seed_state "$ROOT/well"
  start_watcher "$ROOT/well" ""
  run_monitor "$ROOT/well" "$WELL_FORMED_VERSION"
  assert_clean "$ROOT/well" "test_monitor_rejects_unsigned_http_debian_rules" "nopin" || failed=1

  echo "==> test_monitor_rejects_non_debian_version"
  mkdir -p "$ROOT/bad"
  seed_state "$ROOT/bad"
  start_watcher "$ROOT/bad" "$INVALID_VERSION"
  run_monitor "$ROOT/bad" "$INVALID_VERSION"
  assert_clean "$ROOT/bad" "test_monitor_rejects_non_debian_version" "pin" || failed=1

  [[ "$failed" == "0" ]]
}

main "$@"
