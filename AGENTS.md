# Agent / automation workflow

## Git — no pull requests

**Never open pull requests on this repository.**

- Commit and push directly to `main`.
- Do not create feature branches for review unless the user explicitly asks.
- Do not use `ManagePullRequest`, `gh pr create`, or similar.

## Builds

- Pretest must pass before full CI builds (`scripts/test-build-scripts.sh`, `scripts/pretest-patch.sh`).
- Packaging simulate uses stock Ubuntu `libwebkitgtk-6.0-4` debs, not empty stubs or CI-built binaries.
- Staged CI: `build.sh compile` then `build.sh package` (see `build.sh` and series workflows).

## Series

Native builds only — `SERIES` must match the host Ubuntu release. Cross-series checks use archive apt isolation in scripts, not dist-upgrade on the host.
