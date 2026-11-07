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
| Full local gate (`scripts/automation/check.sh`) | The same command. On Linux it runs `scripts/linux/check.sh`: shared self-tests, web panel tests, the Ghostty widget test, debug and release builds, two smoke scripts, the release install end-to-end, then `test.sh`. |
| `smoke-ui`, `workspace-tabs`, `workspace-scope`, `smoke-cli-live-control`, `shortcut-hints` | The same scripts under `scripts/automation/`. On Linux they build with `scripts/linux/build.sh` and run on their own Broadway display. Also `scripts/linux/e2e-app-logic.sh` (managed agent, persistence across restart, scripted UI, Remote Access pairing). For a specific UI flow, use a Broadway test in `linux/Tests/` or a `TOASTTY_LINUX_SMOKE_SCRIPT` run (see `toastty-dev-run` `references/linux.md`). |
| `shortcut-trace` (macOS-only) | `scripts/linux/test.sh LinuxCommandTable` and the Broadway suites (accelerators, menus, palette); `TOASTTY_LINUX_SMOKE_SCRIPT` `perform`, `palette` and `alt-hints` steps for a one-off check |
| Release-build or install checks | `scripts/linux/e2e-install.sh [--release]` installs into a throwaway prefix and reruns the end-to-end checks against it |
| Packaging (`scripts/linux/package.sh`, `install.sh`, `linux/data/`, `linux/packaging/`), app startup, agent launch or anything a release could break | `scripts/linux/package.sh --version 0.0.0 --build-number 0` (it does the release build; `--no-build` only right after one), then `scripts/linux/test-package.sh --release-dir artifacts/release/linux/0.0.0-0`: launches the `.deb` and the AppImage, runs a terminal command, starts Claude Code and Codex with a one-word prompt, and saves screenshots and transcripts under `artifacts/package-tests/`. Read the screenshots. `0.0.0-0` is the scratch version the gate also uses; always pass `--release-dir`. The agent checks use the user's real home, agent logins and a few tokens: keep them for changes to install layout, the agent shim, plugins, hooks or agent launch, and pass `--agents none` otherwise. For `install.sh`, run this and the release-install row above. |
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
  a runtime-isolated dev instance (see
  `toastty-dev-run` `references/linux.md`), tell the user a window will
  open, and say in the handoff what was checked on the real display.

Handoff additions: say which checks ran offscreen and which in a real window,
and give the test totals reported by `test.sh` and the pass/fail counts from
any `test-package.sh` report.
