# webkitgtk-automation

Rebuild Ubuntu **`libwebkitgtk-6.0-webdriver`** — parallel-install `.deb`s with WebDriver mouse/keyboard/wheel support for GTK4.

Ubuntu’s `debian/rules` enables `-DENABLE_WEBDRIVER=ON` for soup3 (`libwebkit2gtk-4.1`) but leaves it **off** for GTK4 (`libwebkitgtk-6.0`). Browser-side Element Click / Send Keys then return `unsupported operation`. This repo patches that and publishes packages that coexist with system `libwebkitgtk-6.0-4`.

Upstream: [WebKit #318171](https://bugs.webkit.org/show_bug.cgi?id=318171)

## Install

Packages: `libwebkitgtk-6.0-webdriver4` (runtime) and `libwebkitgtk-6.0-webdriver-dev` (pkg-config). Uses system `libjavascriptcoregtk-6.0-1`, `libwebkitgtk-6.0-dev`, and `webkitgtk-webdriver`.

Install the `.deb` built for **your** Ubuntu series (plucky 25.04, questing 25.10, resolute 26.04).

1. Download `libwebkitgtk-6.0-webdriver4_*.deb` and `libwebkitgtk-6.0-webdriver-dev_*.deb` from [Releases](../../releases).
2. Install:

```bash
sudo apt install ./libwebkitgtk-6.0-webdriver4_*.deb ./libwebkitgtk-6.0-webdriver-dev_*.deb
```

Keep system `libwebkitgtk-6.0-4`, `libjavascriptcoregtk-6.0-1`, and `webkitgtk-webdriver` installed. Meson consumers: `dependency('webkitgtk-6.0-webdriver')` (Vala still uses `--pkg=webkitgtk-6.0` for API).

To remove:

```bash
sudo apt remove libwebkitgtk-6.0-webdriver4 libwebkitgtk-6.0-webdriver-dev
```

## Documentation

- [Building locally](docs/building.md) — `./build.sh`, resume/caching, pretest
- [CI builds](docs/ci.md) — GitHub Actions tags and workflows
- [Repo layout](docs/layout.md) — paths and roles
- [Plans](docs/plans/) — implementation history

## Artificial Intelligence Usage

This project was developed with the assistance of artificial intelligence.

- Product design and code design were done by the author
- AI's main role was writing implementation for review
- Most of the coding was performed by AI
- Code was then reviewed, revised, and approved by the author
- Limited exceptions apply mainly to the build system
