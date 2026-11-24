# Bug — `webkitgtk-webdriver.vapi` / dev header unusable from Vala

**Date:** 2026-09-04  
**Status:** fixed (packaging)  
**Area:** `packaging/webkitgtk-webdriver/` (`libwebkitgtk-6.0-webdriver-dev`)  
**Seen in:** `+webdriver5` on Ubuntu 25.04 (2.50.4-0ubuntu0.25.04.1+webdriver5)

---

## Problem

Shipped **Vala** and **C** extension files for `NavigatorWebDriverActivePolicy` do not
compose with system `webkitgtk-6.0` / `libwebkitgtk-6.0-dev`:

1. **Vala:** `public partial class Settings` in `webkitgtk-webdriver.vapi` fails —  
   `Settings` is **sealed** in `webkitgtk-6.0.vapi`:

   ```
   webkitgtk-webdriver.vapi: error: `WebKit' already contains a definition for `Settings'
   webkitgtk-6.0.vapi: note: previous definition of `Settings' was here (sealed)
   ```

2. **C header:** `WebKitNavigatorWebDriverActivePolicy.h` includes  
   `#include <webkitgtk-6.0/WebKitSettings.h>` — that path does not exist on disk.  
   Actual header: `webkit/WebKitSettings.h` under `-I/usr/include/webkitgtk-6.0`.

3. **Missing:** `webkitgtk-webdriver.deps` (should contain `webkitgtk-6.0`) is not
   installed beside the vapi.

Consumers cannot use `--pkg=webkitgtk-webdriver` alone; they must ship local shims.

---

## Expected

After `apt install libwebkitgtk-6.0-webdriver-dev`:

```vala
// --pkg=webkitgtk-6.0 --pkg=webkitgtk-webdriver
var settings = new WebKit.Settings ();
WebKit.set_navigator_webdriver_active_policy (
    settings, WebKit.NavigatorWebDriverActivePolicy.DISABLED);
```

…or equivalent **extern** bindings without `partial class Settings`.

---

## Proposed fix (packaging only)

### `packaging/webkitgtk-webdriver/webkitgtk-webdriver.vapi`

Drop `partial class Settings`. Keep enum + externs with `[CCode (cname = …)]` so Vala
names do not double-prefix `webkit_`:

```vala
namespace WebKit {
    public enum NavigatorWebDriverActivePolicy { AUTO, ENABLED, DISABLED }

    [CCode (cname = "webkit_settings_get_navigator_webdriver_active_policy")]
    public extern NavigatorWebDriverActivePolicy get_navigator_webdriver_active_policy (Settings settings);

    [CCode (cname = "webkit_settings_set_navigator_webdriver_active_policy")]
    public extern void set_navigator_webdriver_active_policy (Settings settings, NavigatorWebDriverActivePolicy policy);
}
```

(Optional later: GObject introspection / gir if GTK bindings should expose the property.)

### `packaging/webkitgtk-webdriver/WebKitNavigatorWebDriverActivePolicy.h`

```c
#include <webkit/WebKitSettings.h>
```

### Install manifest

Also ship `packaging/webkitgtk-webdriver/webkitgtk-webdriver.deps` →  
`usr/share/vala/vapi/webkitgtk-webdriver.deps` containing `webkitgtk-6.0`.

---

## Smoke

```bash
valac -c -o /dev/null --pkg=gtk4 --pkg=webkitgtk-6.0 --pkg=webkitgtk-webdriver test.vala
```

where `test.vala` constructs a controlled `WebView` and calls  
`set_navigator_webdriver_active_policy(…, DISABLED)`.

---

## Relation

- [2026-09-01-navigator-webdriver-on-controlled-views.md](./2026-09-01-navigator-webdriver-on-controlled-views.md) — WebCore policy (landed); this bug is **dev package bindings** only.
