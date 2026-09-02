# Bug / feature — Controlled views advertise `navigator.webdriver`

**Date:** 2026-09-01  
**Status:** open  
**Area:** parallel `libwebkitgtk-6.0-webdriver` rebuild (WebCore)  
**Upstream:** [webkit.org 165269](https://bugs.webkit.org/show_bug.cgi?id=165269) (RESOLVED FIXED — policy API)  
**Upstream land:** [315656@main](https://commits.webkit.org/315656@main) (`a8aac3e41541`)

---

## Problem

- 🔷 A `WebView` constructed with `is-controlled-by-automation: true` exposes W3C  
  `navigator.webdriver === true` to page JavaScript.
- 🔷 That is intentional stock WebKit behavior (automation signal) — not a bug in  
  upstream WebKit.
- 🔷 Windows / Chromium embedders already suppress the same signal: launch with  
  `--disable-blink-features=AutomationControlled` so controlled sessions need not  
  advertise automation to page JS. That precedent justifies an engine-level opt-out  
  here too, without pretending stock Auto policy is wrong for everyone.
- 🔷 Apps that need this package’s **GTK4 Automation interactions** (mouse / keys)  
  still hit sites that treat `webdriver === true` as a hard bot signal (captcha / login).
- 🔷 Page-JS redefines of the getter are detectable; this package already ships a  
  **custom WebKit library**, so an engine-honest fix belongs here.

---

## How it is exposed today

- 🔷 IDL: `Source/WebCore/Modules/webdriver/Navigator+WebDriver.idl`

```idl
// https://w3c.github.io/webdriver/#interface
[
    ImplementedBy=NavigatorWebDriver
] partial interface Navigator {
    readonly attribute boolean webdriver;
};
```

- 🔷 Implementation: `NavigatorWebDriver::webdriver` → `isControlledByAutomation()`  
  (historically `Page::isControlledByAutomation()` when policy is Auto).

---

## Option 1 — Blunt (IDL)

- 🔷 Comment out / remove the `readonly attribute boolean webdriver;` line in  
  `Navigator+WebDriver.idl` for the **webdriver** parallel build only.
- 🔷 Result: property absent / not bound — pages that only check  
  `navigator.webdriver === true` often pass.
- 💩 Breaks W3C shape (`webdriver` always present as boolean). Some detectors  
  use `'webdriver' in navigator` or descriptor checks differently.
- ℹ️ Acceptable as a **fast spike** only if Option 2 backport is blocked.

---

## Option 2 — Proper (upstream policy) — **chosen**

Upstream [165269](https://bugs.webkit.org/show_bug.cgi?id=165269) added  
`NavigatorWebDriverActivePolicy` (`Auto` | `Enabled` | `Disabled`):

- **Auto** — today’s behavior (`Page::isControlledByAutomation()`).
- **Enabled** — force `true`.
- **Disabled** — force `false` even when the page is automation-controlled.

Landed on trunk as [315656@main](https://commits.webkit.org/315656@main):

- `NavigatorWebDriver.cpp` consults `settings().navigatorWebDriverActivePolicy()`.
- Preference in `UnifiedWebPreferences.yaml` (`status: embedder`).
- Cocoa SPI: `WKPreferences` `_setNavigatorWebDriverActivePolicy` +  
  `_WKAutomationSessionConfiguration` `navigatorWebDriverEnabled`.

**For this Ubuntu / GTK4 parallel package:**

- 🔷 Cherry-pick or backport that WebCore (+ settings) change onto the series  
  we rebuild (may predate trunk).
- 🔷 Default the **webdriver** variant to **Disabled** (or expose a clear  
  build/runtime switch), so Automation fill/press stays available without  
  advertising `navigator.webdriver === true`.
- 🔷 Prefer this over IDL deletion: attribute stays present, value is `false`,  
  getter remains the native binding.

💩 GTK / GLib may lack the Cocoa SPI. Minimum for apps: WebCore default  
Disabled in this package, or a small GTK settings hook if/when we need  
per-view control.

---

## Framing (bug vs feature)

- 🔷 Stock Ubuntu `libwebkitgtk-6.0` stays W3C / Auto.
- 🔷 This repo’s **`libwebkitgtk-6.0-webdriver`** is already a deliberate  
  fork for Automation interactions — defaulting policy to **Disabled** (Option 2)  
  is a **documented package feature**, not a silent break of the system library.  
  Same idea as Chromium’s `AutomationControlled` opt-out on Windows.
- 🔷 Track as a packaging patch (+ optional plan) under `patches/` + rebuild  
  `+webdriverN`, same as the GTK4 interactions work.

---

## Proposed work

1. ⏳ Review 165269 / 315656@main against current series source (what already  
   exists vs needs backport).
2. ⏳ **Policy Disabled** patch for webdriver builds (Option 2); document in README.
3. ⏳ Option 1 (IDL) only if backport is blocked and a spike is needed.
4. ⏳ Smoke: controlled `WebView` + Automation mouse/keys; DevTools  
   `navigator.webdriver === false` (or undefined if IDL path).

---

## Out of scope

- 🚫 Changing system `libwebkitgtk-6.0-4` packaging.
- 🚫 JS UserScript / MITM redefine of the property (app-side; detectable).
- 🚫 Porting Chromium launch flags into WebView2 apps (different engine; cited only  
  as precedent for embedder-controlled suppression).
