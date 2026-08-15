# webkitgtk-automation

Rebuild Ubuntu **`libwebkitgtk-6.0`** with WebDriver mouse/keyboard/wheel support enabled.

Ubuntu’s `debian/rules` turns `-DENABLE_WEBDRIVER=ON` on for soup3 (`libwebkit2gtk-4.1`) but leaves it **off** for GTK4 (`libwebkitgtk-6.0`). Browser-side Element Click / Send Keys then return `unsupported operation`. This repo patches that and publishes replacement `.deb`s.

Upstream: [WebKit #318171](https://bugs.webkit.org/show_bug.cgi?id=318171)

## What you get

- `libwebkitgtk-6.0-4_*.deb` — runtime library with INTERACTIONS compiled in
- `libwebkitgtk-6.0-dev_*.deb` — matching `-dev` package

System **`webkitgtk-webdriver`** is unchanged (still depends on `libwebkit2gtk-4.1-0`). Only one `/usr/bin/WebKitWebDriver` is shipped.

## Supported Ubuntu series

Builds are **native** (no Docker). `SERIES` must match the machine’s Ubuntu release (`/etc/os-release` `VERSION_CODENAME`).

| Where | Series |
|-------|--------|
| GitHub Actions (`ubuntu-26.04`) | **resolute** (26.04 LTS) |
| Local | whatever you are running (`./build.sh` defaults to the host codename) |

## Install from a Release

1. Download `libwebkitgtk-6.0-4_*.deb` (and `-dev` if you need headers) from [Releases](../../releases).
2. Install:

```bash
sudo apt install ./libwebkitgtk-6.0-4_*.deb
# optional:
sudo apt install ./libwebkitgtk-6.0-dev_*.deb
```

3. Keep system `webkitgtk-webdriver` installed.
4. Prove with any WebDriver client: New Session → find `#q` → Element Click → Element Send Keys. Typed text should appear (not `unsupported operation`).

To revert to Ubuntu’s package:

```bash
sudo apt install --reinstall libwebkitgtk-6.0-4
```

## Pretest (no full build)

Before spending hours on CI, prove the patch applies to this series’ `debian/rules`:

```bash
./scripts/pretest-patch.sh          # host series
./scripts/pretest-patch.sh resolute # or explicit series
```

CI runs the same script as a **pretest** job that gates the heavy build, and on push/PR via `.github/workflows/pretest.yml`.

## Build locally

Needs a lot of disk, RAM, and time (full WebKit package build).

```bash
./build.sh
# or explicitly:
SERIES="$(. /etc/os-release && echo "$VERSION_CODENAME")" SUFFIX='+webkitgtk1' ./build.sh
```

Artifacts land in `dist/`.

### Resume & caching

Interrupted builds are meant to continue, not start over:

| Mechanism | What it does |
|-----------|----------------|
| `work/` | Kept by default. Same series/suffix/patch → skip re-download and re-patch |
| `dpkg-buildpackage -nc` | Skips `debian/rules clean` so `build-gtk4` object dirs survive |
| `cache/ccache` | Persistent ccache outside the source tree |
| `.ci-cache/apt` | Apt `.deb` archive cache (CI; `Dir::Cache::archives`) |
| `.ci-cache/work` | Packed `work/webkit2gtk-*` (incl. `build-gtk4`) after a failed/cancelled CI run so the next run resumes |

```bash
# Continue after Ctrl-C / failure (default):
./build.sh

# Force a fresh unpack + patch (keeps ccache):
CLEAN=1 ./build.sh

# Nuclear:
CLEAN=1 CLEAN_CACHE=1 ./build.sh
```

### Why the build is tuned this way

| Knob | Plain meaning |
|------|----------------|
| **GTK4-only** (`ENABLE_GTK3=NO`) | Ubuntu normally compiles WebKit twice (4.1 + 6.0). We only need 6.0, so we skip the gtk3 build (~half the work). |
| **`noautodbgsym`** | Do not emit separate `*-dbgsym` / `.ddeb` packages. |
| **`-g0`** | Do not embed debug info in object files. |
| **Gold linker** (`-fuse-ld=gold`) | Use `binutils-gold` (`ld.gold`) for lower peak RAM than `ld.bfd` when linking JSC. Strip BFD-only `-Wl,--reduce-memory-overheads` (gold/lld reject or mangle it). |
| **MiniBrowser off** | Not applicable on 26.04 (resolute dropped the MiniBrowser toggle). |

## Build on GitHub Actions

### Tag and walk away (preferred)

Push a `build-*` tag — that starts the workflow. When it finishes, the `.deb`s are on that tag’s **Release**.

```bash
git tag build-$(date +%Y%m%d)
git push origin build-$(date +%Y%m%d)
# sleep / check Releases later — no need to babysit Actions
```

Examples: `build-20260814`, `build-resolute-1`.

### Manual run

**Actions → Build libwebkitgtk-6.0 with WebDriver → Run workflow** (same pipeline).

Native on `ubuntu-26.04` (**resolute**). No Docker. Flow:

1. Checkout
2. **Pretest** — `scripts/pretest-patch.sh` (patch must apply; fails fast)
3. **Free runner disk** — strip unused SDKs and GHA preinstalled tools
4. **Setup minimal build env** — swap, archive `cmake` only (no `apt-get upgrade`), orchestration packages
5. Restore **apt**, **ccache**, and **work** caches
6. Unpack work tree if present (resumes `build-gtk4` via `build.sh` `-nc`)
7. `./build.sh` (pinned `webkit2gtk` source + `build-dep` only)
8. On **failure/cancel**: pack `work/` → save work cache (next run continues)
9. Save apt / ccache; on success upload `.deb`s and publish a Release

Source versions are pinned in `.github/pinned-webkit-version` (not archive “latest”).
The CI image’s preinstalled CMake 4.4.x is removed; Ubuntu archive cmake is installed and held.

If the packed work tree is over ~10 GiB, pack is skipped (Actions cache budget). Raise the repo Actions cache limit, use a self-hosted runner with a persistent `work/`, or rely on ccache alone.

Manual `workflow_dispatch` inputs:

| Input | Default | Meaning |
|-------|---------|---------|
| `suffix` | `+webkitgtk1` | Appended to the Ubuntu package version |
| `clean` | `false` | Wipe `work/` before building |
| `clean_cache` | `false` | Also wipe ccache |
| `refresh_apt_cache` | `false` | Force a new apt cache key (re-download) |

## Layout

| Path | Role |
|------|------|
| `scripts/pretest-patch.sh` | Dry-run patch against series `debian/rules` (no compile) |
| `patches/enable-webdriver-gtk4.patch` | WebDriver GTK4 + CI resource / ccache / install fixes |
| `build.sh` | Native fetch → patch → resumable `dpkg-buildpackage` → `dist/` |
| `.github/pinned-webkit-version` | Pinned `webkit2gtk` source version per series |
| `.github/scripts/setup-ci-build-env.sh` | Minimal CI base: swap, strip GHA tools, archive cmake, orchestration pkgs |
| `.github/scripts/free-runner-disk.sh` | Thorough hosted-runner cleanup |
| `.github/scripts/work-cache.sh` | Pack/unpack `work/` for incremental CI resume |
| `.github/workflows/build.yml` | Cleanup, apt upgrade+cache, work/ccache, Release |
| `cache/ccache` | Persistent compiler cache (gitignored) |
| `.ci-cache/apt` | Apt `.deb` archives for CI (gitignored) |
| `.ci-cache/work` | Packed work tree for resume (gitignored) |
| `work/` | Unpacked source + object dirs (gitignored) |
| `docs/plans/` | Implementation plan |
