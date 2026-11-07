# Toastty Verify on Linux

The core workflow, scopes, decision tree and handoff checklist in `SKILL.md`
apply unchanged. This file maps each check to its Linux command. All Linux
validation is local:

- **Offscreen:** private GDK Broadway displays cover everything, including GUI
  suites, screenshots, menus, dialogs and shortcuts.
- **Real window:** a runtime-isolated window on the user's display, only for
  OpenGL-sensitive checks. Broadway always uses the offscreen renderer.

There is no `sv`, remote smoke, remote xcodebuild, Peekaboo or Computer Use
step for Linux code. Never run `gnome-shell --headless`, and never drive the
user's installed Toastty.

| macOS check | Linux equivalent |
|---|---|
| Generate + build (`check.sh`, `xcodebuild build`) | `scripts/linux/build.sh` (mirrors the shared sources, then runs `swift build`; `--product`, `--target`, `--release`) |
| `scripts/remote/test.sh` / `xcodebuild test` | `scripts/linux/test.sh [Filter]`: every target in an isolated home, including the Broadway GUI suites. Use `--app-logic` while the GTK frontend is mid-change and `--shared-only` for the shared core only. |
| `smoke-ui`, `workspace-tabs`, `workspace-scope`, `smoke-cli-live-control` | `scripts/linux/e2e-app-logic.sh` (socket, CLI, Ghostty, managed agent, persistence across restart, screenshot, scripted UI, Remote Access pairing). For a specific UI flow, use a Broadway test in `linux/Tests/` or a `TOASTTY_LINUX_SMOKE_SCRIPT` run (see `toastty-dev-run` `references/linux.md`). |
| `shortcut-hints`, `shortcut-trace` | `scripts/linux/test.sh LinuxCommandTable` and the Broadway suites (accelerators, menus, palette); `TOASTTY_LINUX_SMOKE_SCRIPT` `perform`, `palette` and `alt-hints` steps for a one-off check |
| Release-build or install checks | `scripts/linux/e2e-install.sh [--release]` installs into a throwaway prefix and reruns the end-to-end checks against it |
| Computer Use / Peekaboo | A Broadway run with screenshots you read yourself. Use a real window only for GL. |

Area-specific checks:

- **Ghostty widget, patches or libghostty** (`linux/ghostty/`): run
  `linux/ghostty/build-libghostty.sh` (`TOASTTY_GHOSTTY_SKIP_LIB=1` for
  widget-only changes), then `linux/ghostty/test/run-tests.sh --no-build`.
  Export patch changes with `linux/ghostty/export-patches.sh` and list them in
  `linux/ghostty/README.md`.
- **Web panels** (`WebPanels/<App>/`): `npm test` in that app. The generated
  bundles are shared with macOS.
- **Agent plugin skills** (`plugins/toastty/`):
  `python3 scripts/agents/validate-toastty-plugin.py`.
- **OpenGL-sensitive changes** need a real window in addition to the offscreen
  tests. These include the Ghostty GL/DMA-BUF path, widget presentation, WebKit
  renderer selection, frame timing, scaling and GPU-specific behaviour. Launch
  a runtime-isolated dev instance with `TOASTTY_LINUX_NON_UNIQUE=1` (see
  `toastty-dev-run` `references/linux.md`), tell the user a window will
  open, and say in the handoff what was checked on the real display.

Handoff additions: say which checks ran offscreen and which in a real window,
and give the test totals reported by `test.sh`.
