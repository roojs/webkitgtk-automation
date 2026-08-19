# Build on GitHub Actions

Series, patch file, and packaging layout are centralized in `.github/series-registry`:

```
noble=soup3-gtk4:enable-webdriver-gtk4-soup3.patch
questing=soup3-gtk4:enable-webdriver-gtk4-soup3.patch
resolute=gtk3-gtk4:enable-webdriver-gtk4.patch
```

| Where | Series |
|-------|--------|
| GitHub Actions — **plucky** (`build-plucky-*` tags) | **plucky** (25.04) — noble runner upgraded in CI |
| GitHub Actions — **questing** (`build-questing-*` tags) | **questing** (25.10) — noble runner upgraded in CI |
| GitHub Actions — **resolute** (`build-resolute-*` tags) | **resolute** (26.04) — native on `ubuntu-26.04` |
| Local | whatever you are running if listed in `.github/series-registry` |

Install the `.deb` built for **your** Ubuntu series. A 25.10 package will not install on 25.04 (`libc6 >= 2.42`, exact `libjavascriptcoregtk-6.0-1` pin, `libxml2-16`).

## Questing (25.10) — preferred for Ubuntu 25.10 installs

Push a `build-questing-*` tag:

```bash
git tag build-questing-$(date +%Y%m%d)
git push origin build-questing-$(date +%Y%m%d)
```

Workflow: **Build libwebkitgtk-6.0 (25.10 questing)** (`.github/workflows/build-questing.yml`).

Runs on `ubuntu-24.04` (noble), dist-upgrades the runner to **questing**, then builds natively. Apt cache under `.ci-cache/apt-questing`.

## Plucky (25.04)

```bash
git tag build-plucky-$(date +%Y%m%d)
git push origin build-plucky-$(date +%Y%m%d)
```

Workflow: **Build libwebkitgtk-6.0 (25.04 plucky)** (`.github/workflows/build-plucky.yml`).

Same noble→target upgrade as questing. Apt cache under `.ci-cache/apt-plucky`. Pinned source is `2.50.4` (what 25.04 ships), not the 2.52.3 used on 25.10/26.04.

## Resolute (26.04)

Push a `build-resolute-*` tag (not bare `build-*` — that pattern is questing-only):

```bash
git tag build-resolute-$(date +%Y%m%d)
git push origin build-resolute-$(date +%Y%m%d)
```

Workflow: **Build libwebkitgtk-6.0 (26.04 resolute)** (`.github/workflows/build-resolute.yml`).

Native on `ubuntu-26.04`. Apt cache under `.ci-cache/apt-resolute`. CI strips GHA preinstalls (CMake 4.4, browsers, SDKs), rewrites apt to `archive.ubuntu.com`, installs archive cmake and holds it, then builds.

When a workflow finishes, the `.deb`s are on that tag's **Release**.

## Manual run

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

If the packed work tree is over ~10 GiB, pack is skipped (Actions cache budget). Raise the repo Actions cache limit, use a self-hosted runner with a persistent `work/`, or rely on ccache alone.

Manual `workflow_dispatch` inputs:

| Input | Default | Meaning |
|-------|---------|---------|
| `suffix` | _(auto)_ | Debian package suffix (`+webdriverN`; auto-increments per series from `.github/webdriver-revision`) |
| `clean` | `false` | Wipe `work/` before building |
| `clean_cache` | `false` | Also wipe ccache |
| `refresh_apt_cache` | `false` | Force a new apt cache key (re-download) |
