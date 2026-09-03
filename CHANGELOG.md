# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Package versions use Ubuntu’s `webkit2gtk` version plus a **`+webdriverN`** suffix
(e.g. `2.50.4-0ubuntu0.25.04.1+webdriver4`). **N** is tracked per Ubuntu series in
[`.github/webdriver-revision`](.github/webdriver-revision). Entries below use **webdriverN**
as the release label; the series column lists where each build was published.

## [Unreleased]

### Added

- `webkit-165269-navigator-webdriver-invisible*.patch`: policy **Disabled** omits
  `navigator.webdriver` from page JavaScript (Chromium `AutomationControlled` parity).

### Changed

- Compile cache key v12 (preference / IDL / binding regeneration).

## [webdriver4] - 2026-09-02

### Added

- `webkit-165269-navigator-webdriver-gtk-api.patch`: `WebKitSettings:navigator-webdriver-active-policy`
  and `WebKitNavigatorWebDriverActivePolicy` on GTK ([#165269](https://bugs.webkit.org/show_bug.cgi?id=165269)).
- `libwebkitgtk-6.0-webdriver-dev`: `WebKitNavigatorWebDriverActivePolicy.h` and supplemental
  `webkitgtk-webdriver.vapi` (with system `libwebkitgtk-6.0-dev`).

**Published:** plucky, resolute. **Not published:** questing (still on webdriver3).

## [webdriver3] - 2026-09-02

### Added

- `webkit-165269-navigator-webdriver-policy*.patch`: `NavigatorWebDriverActivePolicy`
  (Auto / Enabled / Disabled) in WebCore ([#165269](https://bugs.webkit.org/show_bug.cgi?id=165269)).

### Changed

- Default `NavigatorWebDriverActivePolicy` is **Auto** (upstream semantics).

**Published:** plucky, questing, resolute.

## [webdriver2] - 2026-08-19

### Added

- README demonstration: WebDriver Element Click and Send Keys on GTK4.

### Changed

- Per-series `+webdriverN` auto-increment on publish (`.github/webdriver-revision`).

### Fixed

- Packaging: thin `-dev` dependencies, `debian/control` stanza breaks, roojs metadata rewrite.

**Published:** plucky, questing, resolute.

## [webdriver1] - 2026-08-18

### Added

- Parallel-install `libwebkitgtk-6.0-webdriver4` / `libwebkitgtk-6.0-webdriver-dev`.
- `webkit-318171-webdriver-interactions.patch`: mouse/keyboard/wheel interaction code in
  `libwebkitgtk-6.0` ([#318171](https://bugs.webkit.org/show_bug.cgi?id=318171)).
- Packaging patches: `-webdriver` library suffix; shared system JSC and `webkitgtk-webdriver`
  server; roojs APT publishing.

**Published:** plucky, questing, resolute.
