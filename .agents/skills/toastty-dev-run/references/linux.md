# Toastty Dev Run on Linux

The planning, runtime-isolation, `instance.json` and cleanup rules in
`SKILL.md` apply unchanged; runtime isolation is shared code. This file
replaces the macOS build, launch and GUI-inspection mechanics. Background:
`docs/linux.md`.

Linux validation is local. There is no remote GUI host, Peekaboo or Computer
Use path:

- **Offscreen (default):** a private GDK Broadway display. Nothing appears on
  the user's desktop, so it never steals focus. Use it for everything except
  OpenGL.
- **Real window:** only for OpenGL-sensitive checks, such as Ghostty's GL/DMA-BUF
  renderer, WebKit GPU rendering, frame timing, fractional scaling, or the
  user's GPU. Broadway always uses the offscreen (memory texture) renderer,
  so it cannot show these paths.

Never run `gnome-shell --headless` (it broke the user's session) and never
drive the user's installed Toastty. Read-only socket queries against the
live app are fine.

## Build

```bash
scripts/linux/build.sh --product toastty-linux --product toastty
```

The products are `linux/.build/debug/toastty-linux` (the app) and
`linux/.build/debug/toastty` (the CLI). After Ghostty widget or patch changes,
run `linux/ghostty/build-libghostty.sh` first
(`TOASTTY_GHOSTTY_SKIP_LIB=1` rebuilds only the widget).

## Offscreen run (Broadway)

```bash
WORK="$(mktemp -d "$XDG_RUNTIME_DIR/ttdev.XXXX")"   # short: AF_UNIX paths max 108 bytes
mkdir -p "$WORK/home"
DISPLAYNUM=77                                        # free when no gtk4-broadwayd runs as :77; viewer http://127.0.0.1:$((8080+DISPLAYNUM))
SOCK="$WORK/s.sock"
# broadwayd puts its socket in $XDG_RUNTIME_DIR: give it the app's.
XDG_RUNTIME_DIR="$WORK" gtk4-broadwayd ":$DISPLAYNUM" >"$WORK/broadwayd.log" 2>&1 &
BROADWAY_PID=$!

env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$WORK/home" CFFIXED_USER_HOME="$WORK/home" \
  XDG_RUNTIME_DIR="$WORK" LANG=C.UTF-8 SHELL=/bin/bash TERM=xterm-256color \
  GDK_BACKEND=broadway BROADWAY_DISPLAY=":$DISPLAYNUM" GTK_A11Y=none NO_AT_BRIDGE=1 \
  GDK_DEBUG=no-portals GSETTINGS_BACKEND=memory \
  TOASTTY_RUNTIME_HOME="$WORK/runtime-home" TOASTTY_SOCKET_PATH="$SOCK" \
  linux/.build/debug/toastty-linux --automation --run-id dev --artifacts-dir "$WORK/artifacts" \
    --disable-animations >"$WORK/app.log" 2>&1 &
APP_PID=$!
# Ready when "$WORK/artifacts/automation-ready-dev.json" exists. Without the
# automation flags, wait for "$SOCK" to answer `query list`.
toastty() { env -i PATH=/usr/bin:/bin HOME="$WORK/home" XDG_RUNTIME_DIR="$WORK" \
  linux/.build/debug/toastty --json --socket-path "$SOCK" "$@"; }
```

- `TOASTTY_RUNTIME_HOME="$WORK/runtime-home"` gives the run its own runtime
  home: `instance.json`, `logs/toastty.log` and state start empty and go away
  with `$WORK`. `TOASTTY_DEV_WORKTREE_ROOT="$PWD"` instead uses the worktree's
  shared home under `artifacts/dev-runs/worktree-<name>-<hash>/runtime-home`:
  its log appends to earlier runs and concurrent runs from the worktree
  overwrite each other's `instance.json`. Use it only for a run the user will
  come back to.

- `env -i` keeps the agent's own `TOASTTY_*` variables (a Toastty terminal
  sets them) from pointing the run, or a CLI call, at the live app. Call the
  CLI the same way, with `--socket-path` (the `toastty` function above).
- The PID is `$APP_PID`, or `pid` in `$WORK/runtime-home/instance.json` when
  the launch goes through a wrapper such as `setsid`. Never find it with
  `pgrep -f toastty`: that pattern also matches the agent's own shell
  command line, and the user's installed Toastty.
- If the app cannot reach the Broadway socket, WebKit crashes during startup
  (a segfault under `WebKitEnvironment.init`). Check that broadwayd and the
  app share `XDG_RUNTIME_DIR`.
- The macOS automation flags (`--automation`, `--run-id`, `--fixture`,
  `--artifacts-dir`, `--disable-animations`, `--socket-path`,
  `--skip-quit-confirmation`) and their `TOASTTY_*` variables work the same
  on Linux. They enable the automation mode the smoke scripts use
  (`automation.dump_state`, `automation.capture_screenshot`, the readiness
  file). Drop them for a plain isolated run.
- Runtime-isolated and automation runs are separate GApplication instances
  automatically. `TOASTTY_LINUX_NON_UNIQUE=1` is only needed for a run with
  neither.
- Broadway runs always have animations off: with no viewer attached the
  frame clock never ticks, and pending libadwaita animations later crash the
  tab bar.
- The smoke scripts run here unchanged (`scripts/automation/smoke-ui.sh`,
  `workspace-tabs-smoke.sh`, `workspace-scope-smoke.sh`,
  `smoke-cli-live-control.sh`, `shortcut-hints-smoke.sh`): on Linux they build
  with `scripts/linux/build.sh` and start their own Broadway display
  (`scripts/automation/smoke-platform.sh`). `shortcut-trace.sh` is
  macOS-only.
- `scripts/linux/e2e-app-logic.sh` is the reference for a complete,
  self-cleaning Broadway session with a fake managed agent.
- To watch the run, open the Broadway viewer URL in a browser.

Drive and inspect it (`toastty action list` and `toastty query list` print
the catalog):

```bash
WIN=$(toastty query run workspace.list | jq -r '.result.workspaces[0].windowID')
WS=$(toastty action run workspace.create --window "$WIN" "title=Dev" | jq -r .result.workspaceID)
PANEL=$(toastty query run terminal.state --workspace "$WS" | jq -r .result.panelID)
toastty action run terminal.send-text --panel "$PANEL" "text=echo hello" submit=true
toastty query run terminal.visible-text --panel "$PANEL" | jq -r .result.text
toastty action run workspace.tab.create --workspace "$WS"     # a new tab with a terminal
toastty action run agent.launch --panel "$PANEL" profileID=claude
SHOT=$(python3 scripts/linux/socket-request.py "$SOCK" automation.capture_screenshot '{"step": "dev"}' | jq -r .result.path)
```

- Screenshots: `automation.capture_screenshot` needs the automation flags and
  a `step` name. It writes under `$WORK/artifacts/ui/`: copy the PNG (and
  `$WORK/app.log`) somewhere durable, such as `artifacts/dev-runs/`, before
  removing `$WORK`. Under Broadway the terminal's texture in a capture can lag
  its text by a frame; wait a second after the last change, and trust
  `terminal.visible-text` for the content. Without automation,
  `TOASTTY_LINUX_SCREENSHOT_PATH=<png>` writes one screenshot after the first
  render.
- State: `python3 scripts/linux/socket-request.py "$SOCK" automation.dump_state '{}'`
  (the session registry with agent statuses, layout, panels).
- UI steps that need no socket command, such as menus, dialogs, the palette,
  clicks, resizing and focus changes: set `TOASTTY_LINUX_SMOKE_SCRIPT=<file>`.
  The command list is in
  `linux/Sources/ToasttyLinux/UI/Debug/AutomationScript.swift` (`action`,
  `screenshot`, `state`, `expect`, `palette`, `dialog-*`, `panel-click`,
  `app-focus`, …), and terminal and annotation commands are in
  `TerminalAutomation.swift` and `BrowserAnnotationAutomation.swift`. Put
  durable checks in a Broadway test (`linux/Tests/*Broadway*`) instead.

Clean up only what you started: `kill $APP_PID $BROADWAY_PID`, then remove
`$WORK` (broadwayd's socket is inside it).

## Real window (OpenGL checks only)

```bash
TOASTTY_DEV_WORKTREE_ROOT="$PWD" \
  linux/.build/debug/toastty-linux >artifacts/dev-runs/manual-gl.log 2>&1 &
```

- Runtime isolation (`TOASTTY_DEV_WORKTREE_ROOT` or `TOASTTY_RUNTIME_HOME`)
  makes this a separate GApplication instance. Without isolation the app is
  unique (`com.GiantThings.toastty`), so the launch would be handed over
  D-Bus to the user's installed Toastty and no dev instance would start.
- Runtime isolation keeps its config, logs and socket apart from the live app.
  The window still appears on the user's desktop and takes focus, so say so
  before opening it and close it when done.
- Renderer evidence: `TOASTTY_GHOSTTY_RENDERER=gl|offscreen` forces the
  terminal path, `TOASTTY_GHOSTTY_LATENCY_TRACE=1` prints one line per key
  press, and `TOASTTY_LINUX_TERMINAL_DEBUG=1` logs Ghostty actions. Measure
  web-panel and frame timing here, not on Broadway.

## Installing

`scripts/linux/install.sh` replaces the user's installed app under
`~/.local` (`--prefix` changes that). Only run it when the user asks, and
remind them to quit Toastty first. To test the install layout, use
`scripts/linux/e2e-install.sh`, which installs into a throwaway prefix.
