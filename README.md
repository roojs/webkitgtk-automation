# webkitgtk-automation

Rebuild Ubuntu **`libwebkitgtk-6.0-webdriver`** — a parallel-install stack with WebDriver mouse/keyboard/wheel support enabled.

Ubuntu’s `debian/rules` turns `-DENABLE_WEBDRIVER=ON` on for soup3 (`libwebkit2gtk-4.1`) but leaves it **off** for GTK4 (`libwebkitgtk-6.0`). Browser-side Element Click / Send Keys then return `unsupported operation`. This repo patches that and publishes parallel-install `.deb`s that coexist with system `libwebkitgtk-6.0-4`.

Upstream: [WebKit #318171](https://bugs.webkit.org/show_bug.cgi?id=318171)

## What you get

- `libwebkitgtk-6.0-webdriver4_*.deb` — runtime library (`libwebkitgtk-6.0-webdriver.so.4`) with INTERACTIONS compiled in
- `libwebkitgtk-6.0-webdriver-dev_*.deb` — thin pkg-config package (`webkitgtk-6.0-webdriver.pc` only)

Uses system **`libjavascriptcoregtk-6.0-1`** and **`libwebkitgtk-6.0-dev`** (headers/vapi). System **`webkitgtk-webdriver`** is unchanged.

## Supported Ubuntu series

Builds are **native** (no Docker). `SERIES` must match the machine’s Ubuntu release (`/etc/os-release` `VERSION_CODENAME`).

| Where | Series |
|-------|--------|
| GitHub Actions — **plucky** (`build-plucky-*` tags) | **plucky** (25.04) — noble runner upgraded in CI |
| GitHub Actions — **questing** (`build-questing-*` tags) | **questing** (25.10) — noble runner upgraded in CI |
| GitHub Actions — **resolute** (`build-resolute-*` tags) | **resolute** (26.04) — native on `ubuntu-26.04` |
| Local | whatever you are running if listed in `.github/series-registry` |

Install the `.deb` built for **your** Ubuntu series. A 25.10 package will not install on 25.04 (`libc6 >= 2.42`, exact `libjavascriptcoregtk-6.0-1` pin, `libxml2-16`).

## Install from a Release

1. Download `libwebkitgtk-6.0-webdriver4_*.deb` and `libwebkitgtk-6.0-webdriver-dev_*.deb` from [Releases](../../releases).
2. Install:

```bash
sudo apt install ./libwebkitgtk-6.0-webdriver4_*.deb ./libwebkitgtk-6.0-webdriver-dev_*.deb
```

3. Keep system `libwebkitgtk-6.0-4`, `libjavascriptcoregtk-6.0-1`, and `webkitgtk-webdriver` installed.
4. Meson consumers: `dependency('webkitgtk-6.0-webdriver')` (Vala still uses `--pkg=webkitgtk-6.0` for API).
5. Prove with any WebDriver client: New Session → find `#q` → Element Click → Element Send Keys.

To remove the parallel stack:

```bash
sudo apt remove libwebkitgtk-6.0-webdriver4 libwebkitgtk-6.0-webdriver-dev
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
SERIES="$(. /etc/os-release && echo "$VERSION_CODENAME")" SUFFIX='+webdriver1' ./build.sh
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
| **GTK4-only** | Ubuntu normally compiles WebKit for soup3/4.1 and gtk4/6.0 (or gtk3+gtk4 on resolute). We only need 6.0, so we skip the other build (~half the work). Layout depends on series — see `.github/series-registry`. |
| **`noautodbgsym`** | Do not emit separate `*-dbgsym` / `.ddeb` packages. |
| **`-g0`** | Do not embed debug info in object files. |
| **Gold linker** (`-fuse-ld=gold`) | Use `binutils-gold` (`ld.gold`) for lower peak RAM than `ld.bfd` when linking JSC. Strip BFD-only `-Wl,--reduce-memory-overheads` (gold/lld reject or mangle it). |
| **MiniBrowser off** | Not applicable on 26.04 (resolute dropped the MiniBrowser toggle). |

## Build on GitHub Actions

Series, patch file, and packaging layout are centralized in `.github/series-registry`:

```
noble=soup3-gtk4:enable-webdriver-gtk4-soup3.patch
questing=soup3-gtk4:enable-webdriver-gtk4-soup3.patch
resolute=gtk3-gtk4:enable-webdriver-gtk4.patch
```

### Questing (25.10) — preferred for Ubuntu 25.10 installs

Push a `build-questing-*` tag:

```bash
git tag build-questing-$(date +%Y%m%d)
git push origin build-questing-$(date +%Y%m%d)
```

Workflow: **Build libwebkitgtk-6.0 (25.10 questing)** (`.github/workflows/build-questing.yml`).

Runs on `ubuntu-24.04` (noble), dist-upgrades the runner to **questing**, then builds natively. Apt cache under `.ci-cache/apt-questing`.

### Plucky (25.04)

```bash
git tag build-plucky-$(date +%Y%m%d)
git push origin build-plucky-$(date +%Y%m%d)
```

Workflow: **Build libwebkitgtk-6.0 (25.04 plucky)** (`.github/workflows/build-plucky.yml`).

Same noble→target upgrade as questing. Apt cache under `.ci-cache/apt-plucky`. Pinned source is `2.50.4` (what 25.04 ships), not the 2.52.3 used on 25.10/26.04.

### Resolute (26.04)

Push a `build-resolute-*` tag (not bare `build-*` — that pattern is questing-only):

```bash
git tag build-resolute-$(date +%Y%m%d)
git push origin build-resolute-$(date +%Y%m%d)
```

Workflow: **Build libwebkitgtk-6.0 with WebDriver** (`.github/workflows/build.yml`).

Native on `ubuntu-26.04`. CI strips GHA preinstalls (CMake 4.4, browsers, SDKs), rewrites apt to `archive.ubuntu.com`, installs archive cmake and holds it, then builds.

When a workflow finishes, the `.deb`s are on that tag's **Release**.

### Manual run

**Actions →** pick the questing or resolute workflow → **Run workflow**.

Native build flow (series-specific runner setup differs):

1. Checkout
2. **Pretest** — `scripts/test-build-scripts.sh` / `pretest-patch.sh` (patch must apply; fails fast)
3. **Free runner disk** — strip unused SDKs and GHA preinstalled tools
4. **Setup** — plucky/questing: noble→target dist-upgrade + orchestration packages; resolute: minimal env + archive cmake
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
| `patches/enable-webdriver-gtk4.patch` | WebDriver GTK4 patch (resolute / gtk3-gtk4 layout) |
| `patches/enable-webdriver-gtk4-soup3.patch` | WebDriver GTK4 patch (noble/plucky/questing / soup3-gtk4 layout) |
| `.github/series-registry` | Maps Ubuntu series → layout + patch file |
| `scripts/lib/series-registry.sh` | Parse registry; resolve patch and build tags |
| `.github/scripts/upgrade-runner-to-series.sh` | CI: dist-upgrade runner to target series (plucky/questing) |
| `.github/workflows/build-plucky.yml` | Plucky build (noble runner → 25.04 upgrade → Release) |
| `.github/workflows/build-questing.yml` | Questing build (noble runner → 25.10 upgrade → Release) |
| `.github/workflows/build.yml` | Resolute build (26.04 native → Release) |
| `cache/ccache` | Persistent compiler cache (gitignored) |
| `.ci-cache/apt` | Apt `.deb` archives for CI (gitignored) |
| `.ci-cache/work` | Packed work tree for resume (gitignored) |
| `work/` | Unpacked source + object dirs (gitignored) |
| `docs/plans/` | Implementation plan |
