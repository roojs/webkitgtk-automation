# Building locally

Needs a lot of disk, RAM, and time (full WebKit package build).

```bash
./build.sh
# or explicitly:
SERIES="$(. /etc/os-release && echo "$VERSION_CODENAME")" SUFFIX='+webdriver1' ./build.sh
```

Artifacts land in `dist/`.

Builds are **native** (no Docker). `SERIES` must match the machine’s Ubuntu release (`/etc/os-release` `VERSION_CODENAME`). See `.github/series-registry` for supported series.

## Pretest (no full build)

Before spending hours on CI, prove the patch applies to this series’ `debian/rules`:

```bash
./scripts/pretest-patch.sh          # host series
./scripts/pretest-patch.sh resolute # or explicit series
```

CI runs the same script as a **pretest** job that gates the heavy build (on push to `main` via `.github/workflows/pretest.yml`).

## Resume & caching

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

## Why the build is tuned this way

| Knob | Plain meaning |
|------|----------------|
| **GTK4-only** | Ubuntu normally compiles WebKit for soup3/4.1 and gtk4/6.0 (or gtk3+gtk4 on resolute). We only need 6.0, so we skip the other build (~half the work). Layout depends on series — see `.github/series-registry`. |
| **`noautodbgsym`** | Do not emit separate `*-dbgsym` / `.ddeb` packages. |
| **`-g0`** | Do not embed debug info in object files. |
| **Gold linker** (`-fuse-ld=gold`) | Use `binutils-gold` (`ld.gold`) for lower peak RAM than `ld.bfd` when linking JSC. Strip BFD-only `-Wl,--reduce-memory-overheads` (gold/lld reject or mangle it). |
| **MiniBrowser off** | Not applicable on 26.04 (resolute dropped the MiniBrowser toggle). |
