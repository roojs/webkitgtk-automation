# Using libwebkitgtk-6.0-webdriver

For application and library authors (Meson, C, Vala) linking an embedded WebKitGTK
view that is driven through WebDriver (Element Click, Send Keys, wheel).

## Install

Ubuntu: install runtime + thin `-dev` from the [roojs APT repository](https://roojs.github.io/repos/)
(see [README](../README.md#install)). Keep system `libwebkitgtk-6.0-4`,
`libjavascriptcoregtk-6.0-1`, and `webkitgtk-webdriver`.

Fedora/RHEL: stock `webkitgtk6.0` / `webkitgtk-6.0` already ships WebDriver
interactions in the GTK4 library — no parallel package required.

## pkg-config

| Module | When |
|--------|------|
| `webkitgtk-6.0-webdriver` | Ubuntu/Debian — parallel install from this repo |
| `webkitgtk-6.0` | Fedora/RHEL and other distros where stock GTK4 WebKit has interactions |

Thin `-dev` (`libwebkitgtk-6.0-webdriver-dev` on Ubuntu) supplies
`webkitgtk-6.0-webdriver.pc` (link flags only). API headers and Vala vapi still
come from system `libwebkitgtk-6.0-dev`.

```meson
webkit_dep = dependency('webkitgtk-6.0-webdriver')
```

Vala: `--pkg=webkitgtk-6.0` for the core API; add `--pkg=webkitgtk-webdriver` only
if you use the optional navigator-policy extension from `-dev`.

## Compile-time interaction check

Ubuntu stock `libwebkitgtk-6.0` and `libwebkitgtk-6.0-webdriver` share the same C
API but **not** the same WebDriver interaction support: stock Ubuntu GTK4 builds omit
mouse/keyboard interaction code, so WebDriver Element Click / Send Keys return
`unsupported operation`. Fedora stock builds include that code.

Do **not** rely on pkg-config module name alone. At **configure time**, probe the
installed `.so` that each module would link:

When `ENABLE_WEBDRIVER_MOUSE_INTERACTIONS` is off, WebKit does not link
`SimulatedInputDispatcher` into `libwebkitgtk-6.0.so.4`. When interactions are on
(Fedora stock, or this repo’s `libwebkitgtk-6.0-webdriver.so.4`), that symbol is
present. No distro-specific flags or Fedora packaging changes are required.

This repository ships
[`scripts/meson/check-webkit-interactions.sh`](../scripts/meson/check-webkit-interactions.sh):

```bash
./scripts/meson/check-webkit-interactions.sh webkitgtk-6.0          # 0 = ok, 1 = not
./scripts/meson/check-webkit-interactions.sh webkitgtk-6.0-webdriver
```

### Meson example (auto-select)

Try the parallel module first, then stock; require at least one library with
interactions compiled in:

```meson
check_script = files('path/to/webkitgtk-automation/scripts/meson/check-webkit-interactions.sh')

webkit_dep = disabler()
webkit_pc_used = ''

foreach pc : ['webkitgtk-6.0-webdriver', 'webkitgtk-6.0']
  _dep = dependency(pc, required: false)
  if _dep.found() and run_command(check_script, pc, check: false).returncode() == 0
    webkit_dep = _dep
    webkit_pc_used = pc
    break
  endif
endforeach

if not webkit_dep.found()
  error('No WebKitGTK with WebDriver interactions found. '
      + 'On Ubuntu/Debian install libwebkitgtk-6.0-webdriver-dev.')
endif

message('WebKitGTK for automation: @0@'.format(webkit_pc_used))
```

Copy the script into your tree or invoke it from a git submodule / vendored path.
Point `check_script` at your checkout of this repository.

### What this does not check

- **Navigator policy / hiding `navigator.webdriver`** — optional; see README. Not
  required for Element Click / Send Keys.
- **Runtime** — configure only inspects the library pkg-config would link at build
  time. Reinstalling packages without re-running `meson setup` is outside this
  check.

### Assumption

The probe greps `strings` on the resolved `.so` for `SimulatedInputDispatcher`.
That type is C++ and not exported in the dynamic symbol table (`nm -D` misses it);
the string appears when interaction code was linked in. The name has been stable
across recent WebKit 2.5x releases; a future WebKit refactor could require
updating the probe.

## Runtime

1. Keep system `webkitgtk-webdriver` / `WebKitWebDriver` for the automation server.
2. Link the embedded browser against the `webkit_dep` chosen above.
3. Create controlled views with `is-controlled-by-automation: true` when driving
   through WebDriver.

## See also

- [README](../README.md) — install, demonstration, navigator policy
- [Building locally](building.md) — building these packages (maintainers)
- [Plans](plans/2.0-parallel-install-webkitgtk-webdriver.md) — design history
