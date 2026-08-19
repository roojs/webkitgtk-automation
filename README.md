# webkitgtk-automation

Rebuild Ubuntu **`libwebkitgtk-6.0-webdriver`** — parallel-install `.deb`s with WebDriver mouse/keyboard/wheel support for GTK4.

Ubuntu’s `debian/rules` enables `-DENABLE_WEBDRIVER=ON` for soup3 (`libwebkit2gtk-4.1`) but leaves it **off** for GTK4 (`libwebkitgtk-6.0`). Browser-side Element Click / Send Keys then return `unsupported operation`. This repo patches that and publishes packages that coexist with system `libwebkitgtk-6.0-4`.

Upstream: [WebKit #318171](https://bugs.webkit.org/show_bug.cgi?id=318171)

## Install

Packages: `libwebkitgtk-6.0-webdriver4` (runtime) and `libwebkitgtk-6.0-webdriver-dev` (pkg-config). Published for Ubuntu 25.04 (plucky), 25.10 (questing), and 26.04 (resolute) in the [roojs APT repository](https://roojs.github.io/repos/).

Add the signing key and sources file (replace `@suite@` with `lsb_release -cs`):

```bash
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://roojs.github.io/repos/key.gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/roojs.gpg

curl -fsSL https://roojs.github.io/repos/sources \
  | sed "s/@suite@/$(lsb_release -cs)/" \
  | sudo tee /etc/apt/sources.list.d/roojs.sources

sudo apt update
sudo apt install libwebkitgtk-6.0-webdriver4 libwebkitgtk-6.0-webdriver-dev
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

- The author set only a small set of requirements (enable WebDriver on GTK4, parallel-install `.deb`s alongside the distro stack)
- Build scripts, CI workflows, packaging patches, and documentation were largely AI-generated
- The author has reviewed the overall approach and key outputs, but not every line in detail
- Treat scripts and packaging as provisional until exercised on your target Ubuntu series
