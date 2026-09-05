# Repo layout

| Path | Role |
|------|------|
| `docs/consuming.md` | Meson/C consumer guide; compile-time WebDriver interaction probe |
| `scripts/pretest-patch.sh` | Dry-run patch against series `debian/rules` (no compile) |
| `patches/enable-webdriver-gtk4.patch` | WebDriver GTK4 patch (resolute / gtk3-gtk4 layout) |
| `patches/enable-webdriver-gtk4-soup3.patch` | WebDriver GTK4 patch (noble/plucky/questing / soup3-gtk4 layout) |
| `.github/series-registry` | Maps Ubuntu series → layout + patch file |
| `scripts/lib/series-registry.sh` | Parse registry; resolve patch and build tags |
| `.github/scripts/upgrade-runner-to-series.sh` | CI: dist-upgrade runner to target series (plucky/questing) |
| `.github/workflows/build-plucky.yml` | Plucky build (noble runner → 25.04 upgrade → Release) |
| `.github/workflows/build-questing.yml` | Questing build (noble runner → 25.10 upgrade → Release) |
| `.github/workflows/build-resolute.yml` | Resolute build (26.04 native → Release) |
| `cache/ccache` | Persistent compiler cache (gitignored) |
| `.ci-cache/apt` | Apt `.deb` archives for CI (gitignored) |
| `.ci-cache/work` | Packed work tree for resume (gitignored) |
| `work/` | Unpacked source + object dirs (gitignored) |
| `docs/plans/` | Implementation plans |
