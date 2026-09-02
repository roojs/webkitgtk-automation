# webkitgtk-automation

Rebuild Ubuntu **`libwebkitgtk-6.0-webdriver`** — parallel-install `.deb`s that apply two upstream WebKit fixes to the GTK4 library, plus Debian/build-rule changes so those packages install alongside system `libwebkitgtk-6.0-4`.

This is not a fork of WebKit. It is Ubuntu’s `webkit2gtk` source with:

| Patch | Upstream | What it does |
|-------|----------|--------------|
| `webkit-318171-webdriver-interactions.patch` | [#318171](https://bugs.webkit.org/show_bug.cgi?id=318171) | Compiles WebDriver mouse/keyboard/wheel interaction code into `libwebkitgtk-6.0` without turning on full `ENABLE_WEBDRIVER`. |
| `webkit-165269-navigator-webdriver-policy*.patch` | [#165269](https://bugs.webkit.org/show_bug.cgi?id=165269) | Adds `NavigatorWebDriverActivePolicy` and defaults it to **Disabled** so controlled views do not advertise automation to page JavaScript. |

Packaging patches (`enable-webdriver-gtk4*.patch`, `webkitgtk-variant-suffix.patch`) rename the GTK4 stack to `libwebkitgtk-6.0-webdriver`, skip duplicate JSC/WebDriver binaries, and tune the build for CI. System `libwebkitgtk-6.0-4`, `libjavascriptcoregtk-6.0-1`, and `webkitgtk-webdriver` stay installed.

## Demonstration

Stock `libwebkitgtk-6.0` returns `unsupported operation` for WebDriver Element Click and Send Keys. After installing these packages, both succeed:

https://github.com/user-attachments/assets/c09be86e-9f71-42d1-82da-fc2a4adadb0a

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

## Hiding `navigator.webdriver` (automation flag)

### The problem

On stock WebKitGTK, a `WebKitWebView` created with `is-controlled-by-automation: true` exposes W3C `navigator.webdriver === true` to page JavaScript. That is intentional upstream behaviour — sites use it as a bot signal.

Chromium on Windows already lets embedders opt out: launch with `--disable-blink-features=AutomationControlled` so controlled sessions need not advertise automation. WebKit upstream added the same idea in [#165269](https://bugs.webkit.org/show_bug.cgi?id=165269) via `NavigatorWebDriverActivePolicy`:

| Policy | `navigator.webdriver` on a controlled view |
|--------|------------------------------------------|
| **Auto** | `true` when the view is automation-controlled (stock Ubuntu `libwebkitgtk-6.0-4`) |
| **Enabled** | always `true` |
| **Disabled** | always `false`, even when automation-controlled |

### What this package does

The `#165269` patch is applied with **Disabled** as the default. After you install `libwebkitgtk-6.0-webdriver4` and link your app against it:

- WebDriver Element Click, Send Keys, and wheel still work (the `#318171` interactions are in the library).
- Page JavaScript sees `navigator.webdriver === false` on controlled views — the same practical outcome as Chromium’s `AutomationControlled` opt-out on Windows.
- Stock `libwebkitgtk-6.0-4` on the system is unchanged and keeps **Auto** policy.

No application code is required for the default hidden behaviour. Use automation as you already do:

1. Keep system `webkitgtk-webdriver` for the `WebKitWebDriver` process.
2. Build/link the embedded browser against `webkitgtk-6.0-webdriver` (Meson: `-Dwebkit_pc=webkitgtk-6.0-webdriver` or `dependency('webkitgtk-6.0-webdriver')`).
3. Create the view with `is-controlled-by-automation: true` when driving it through WebDriver.

GTK does not yet expose a public `WebKitSettings` property for `NavigatorWebDriverActivePolicy` (Cocoa has private SPI). This package bakes in **Disabled** at build time. If you need stock **Auto** behaviour, link against system `libwebkitgtk-6.0-4` instead.

### Verify

In a controlled session, open the developer console and run:

```javascript
navigator.webdriver
```

Expect `false` with `libwebkitgtk-6.0-webdriver4`; expect `true` with stock `libwebkitgtk-6.0-4`.

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
