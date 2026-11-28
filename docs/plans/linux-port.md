# Toastty for Ubuntu (GTK4 + libadwaita + Ghostty)

Status: in progress (branch `feat/linux-port`, started 2026-10-20).

## Goal

A native Ubuntu build of Toastty with feature parity for the macOS app's
day-to-day surface: windows, workspaces, tabs, split panes, Ghostty-backed
terminals, managed agents and their hooks, the automation socket and
`toastty` CLI, the right panel (browser, local documents, Scratchpad),
the command palette, persistence and restore, notifications, and Remote
Access for the iOS client. The UI is GTK4 + libadwaita, following GNOME/Yaru
conventions (soft rounded surfaces, adaptive sidebar, system accent color,
follow-system dark mode) rather than imitating macOS chrome.

Out of scope on Linux: Sparkle updates (distribution-managed instead),
macOS-only integrations such as the Dock icon policy and Carbon hot keys.

## Architecture

```
linux/
├── Package.swift            # SwiftPM graph for the Linux build (only build entry point)
├── shared-sources.json      # which shared Sources/ and Tests/ files the Linux build mirrors
├── env.sh                   # toolchain + sysroot environment (no root required)
├── ghostty/                 # Ghostty Linux port: build script, patches, C GTK widget
├── Sources/
│   ├── Shims/               # Linux stand-ins for AppKit/Network/WebKit/... used by shared logic
│   ├── CGtk/, CGtkShim/     # GTK4/libadwaita/WebKitGTK C modules + small C helpers for GObject macros
│   └── ToasttyLinux/        # GTK frontend (app, windows, sidebar, splits, panels, dialogs)
└── Tests/                   # Linux-only tests (UI-model, shims, closed-loop harness)
```

### Shared code, single source of truth

`scripts/linux/sync-shared-sources.py` mirrors the selected files from
`Sources/` and `Tests/` into `linux/.generated/<Target>/`. The mirror only
rewrites Apple-only import lines (`Darwin`→`Glibc`, `CryptoKit`→`Crypto`,
`Combine`→`OpenCombine`, `AppKit`→`ToasttyAppKitShim`, `Network`→
`ToasttyNetworkShim`, …) and `Darwin.`-qualified names, keeps line numbers,
and prefixes each file with `#sourceLocation`, so diagnostics point at the
original file. Rules:

- Edit the original file under `Sources/`, never the mirror.
- Prefer a shim type in `linux/Sources/Shims` over editing shared code.
- When shared code must change, keep it macOS-neutral and guard Linux
  behavior with `#if os(Linux)`; list each such file in `docs/linux.md`
  so a macOS build can review them. macOS cannot be built from Linux hosts.

Shared layers compiled on Linux:

| Layer | Shared sources |
|---|---|
| Protocol/state | `RemoteProtocol`, `Core` (`CoreState`), `CodexReconciliation` |
| CLI | `CLIKit`, `CLI` (`toastty`), `AgentShim` (`toastty-agent-shim`) |
| App logic | the non-SwiftUI subset of `Sources/App`: `AppStore`, `Automation/*` (socket server), `Sessions/*`, `Agents/*` (launch, shims, hooks, skills), `RemoteAccess/*` (gateway, Tailscale, push relay), `Persistence/*`, `Notifications/*` logic, terminal runtime/metadata services, web-panel runtimes where portable |
| Views | not shared: rewritten in GTK under `linux/Sources/ToasttyLinux` |

### Terminal: Ghostty on Linux

Built from Toastty's Ghostty fork (`figelwump/ghostty`, branch
`toastty-downstream`, the commit pinned in `docs/ghostty-integration.md`),
so the downstream embedder APIs (`ghostty_surface_is_at_prompt`, OSC 7501
program status, link hover) match macOS. The fork's embedded apprt
(`libghostty`) gains a Linux/OpenGL platform where the host owns the GL
context. `linux/ghostty/` provides:

- `build-libghostty.sh`: fetch Zig 0.16.0 and the fork, apply
  `linux/ghostty/patches/*.patch`, build into `linux/.deps/ghostty/`
  (`include/ghostty.h`, `lib/libghostty.so`, terminfo, shell integration).
- `widget/`: a C GTK4 widget (`ToasttyGhosttySurface`, a `GtkGLArea`
  subclass) owning one `ghostty_surface_t`: keyboard + IME, mouse, scroll,
  focus, resize/scale, cursor shape, and rendering. An offscreen EGL
  fallback renders where GDK has no GL (Broadway/headless tests).
- a `GhosttyKit` module map, so shared Swift code keeps `import GhosttyKit`.

### UI (GTK4 + libadwaita)

- `AdwApplication`, one `AdwApplicationWindow` per Toastty window,
  `AdwOverlaySplitView` (workspace sidebar), `AdwHeaderBar` with the
  workspace's tab strip (`AdwTabBar`), split panes as nested `GtkPaned`
  driven by `WorkspaceSplitTree`, a second `AdwOverlaySplitView` for the
  right panel (`AdwTabView` of WebKitGTK browser / local document / Scratchpad).
- Sidebar rows: workspace cards with session rows, status dots, unread and
  attention badges, later flags, drag reordering.
- Command palette: a centered `AdwDialog`-style popover with fuzzy list.
- Preferences: `AdwPreferencesDialog` (general, terminal, agents, remote access).
- Dialogs/toasts: `AdwAlertDialog`, `AdwToastOverlay`.
- Theme: `AdwStyleManager` follow-system color scheme and accent color
  (Yaru accents on Ubuntu), rounded 12px cards, soft separators. Terminal
  colors follow Ghostty config; the host chrome reads Ghostty background
  for the panel frame like macOS does.
- Desktop integration: `.desktop` file + icon, `GNotification` desktop
  notifications, Ubuntu Dock unread count via `com.canonical.Unity.LauncherEntry`.

### Paths

`ToasttyRuntimePaths` stays authoritative: `~/.toastty` config, agents.toml,
terminal profiles, hooks. Linux-specific data/state locations follow XDG
(`$XDG_DATA_HOME/toastty`, `$XDG_RUNTIME_DIR` for the automation socket)
through the runtime path layer, with runtime isolation for dev/test runs.

## Keyboard shortcuts (Ubuntu mapping)

Terminal apps own plain `Ctrl+<letter>`, so app shortcuts follow GNOME
Terminal/Ptyxis/Terminator conventions (`Ctrl+Shift`, `Ctrl+PageUp/Down`,
`F`-keys) instead of a blind Cmd→Ctrl swap.

| Action | macOS | Ubuntu |
|---|---|---|
| New window | Cmd+N | Ctrl+Shift+N |
| New tab | Cmd+T | Ctrl+Shift+T |
| Close panel | Cmd+W | Ctrl+Shift+W |
| Quit | Cmd+Q | Ctrl+Shift+Q |
| Toggle sidebar | Cmd+B | F9 |
| Toggle right panel | Cmd+Shift+B | Shift+F9 |
| New workspace | Cmd+Shift+N | Ctrl+Alt+N |
| Close workspace | Cmd+Shift+W | Ctrl+Alt+W |
| Rename workspace | Cmd+Shift+E | F2 |
| Rename tab | Option+Shift+E | Shift+F2 |
| Split right / down | Cmd+D / Cmd+Shift+D | Ctrl+Shift+O / Ctrl+Shift+E |
| Focus prev / next pane | Cmd+[ / Cmd+] | Ctrl+Alt+[ / Ctrl+Alt+] |
| Focus pane by direction | Cmd+Opt+Arrows | Alt+Arrows |
| Resize split | Cmd+Ctrl+Arrows | Ctrl+Shift+Arrows |
| Equalize splits | Cmd+Ctrl+= | Ctrl+Alt+= |
| Zoom focused panel | Cmd+Shift+F | Ctrl+Shift+X |
| Next unread / attention | Cmd+Shift+A | Ctrl+Shift+J |
| Later flag | Cmd+Shift+L | Ctrl+Shift+L |
| Watch running command | Cmd+Shift+M | Ctrl+Shift+M |
| Run task Merge button | Option+Shift+M | Alt+Shift+M |
| Switch tab 1–9 | Cmd+1–9 | Alt+1–9 |
| Switch workspace 1–9 | Option+1–9 | Ctrl+Alt+1–9 |
| Prev / next tab | Cmd+Shift+[ / ] | Ctrl+PageUp / Ctrl+PageDown |
| Move tab left / right | drag | Ctrl+Shift+PageUp / PageDown |
| Prev / next right-panel tab | Cmd+Ctrl+[ / ] | Ctrl+Alt+PageUp / PageDown |
| Focus pane by position | Option+Shift+1–0 | Alt+Shift+1–0 |
| New browser (right panel) / browser tab | Cmd+Ctrl+B / +Shift | Ctrl+Alt+B / Ctrl+Alt+Shift+B |
| New Scratchpad | Cmd+Ctrl+S | Ctrl+Alt+S |
| Command palette | Cmd+Shift+P | Ctrl+Shift+P |
| Find / next / previous | Cmd+F / Cmd+G / Cmd+Shift+G | Ctrl+Shift+F / Ctrl+Shift+G (F3) / Ctrl+Shift+H (Shift+F3) |
| Copy / paste (terminal) | Cmd+C / Cmd+V | Ctrl+Shift+C / Ctrl+Shift+V, Shift+Insert |
| Text size up / down / reset | Cmd+= / Cmd+- / Cmd+0 | Ctrl++ / Ctrl+- / Ctrl+0 |
| Browser location / reload | Cmd+L / Cmd+R | Ctrl+L / Ctrl+R, F5 |
| Local doc edit / save | Cmd+E / Cmd+S | Ctrl+E / Ctrl+S |
| Annotate browser page | pencil button (no shortcut) | Ctrl+Shift+A (browser focused) |
| Back / forward (mouse buttons) | buttons 4/5 (`NavigationMouseInterceptor`) | buttons 8/9 |
| Agent profile / split down with profile | Cmd+Opt+key / +Shift | Ctrl+Alt+key / Ctrl+Alt+Shift+key |
| Preferences | Cmd+, | Ctrl+, |
| Keyboard shortcuts help | — | Ctrl+? |
| Fullscreen | Cmd+Ctrl+F | F11 |

Ctrl+Alt+{N, W, B, S, digits} are reserved; agent profiles that pick those
keys are reported through the existing profile shortcut conflict path.

## Work breakdown

| # | Workstream | Owner | Depends on |
|---|---|---|---|
| 0 | Toolchain, sysroot, mirror script, package skeleton, plan | coordinator | — |
| 1 | Ghostty Linux port (libghostty + GTK widget + demo + test) | subagent `ghostty-linux` | 0 |
| 2 | Shared non-App modules compile + their tests pass on Linux | subagent `shared-core` | 0 |
| 3 | App-logic layer on Linux (shims, AppStore, socket, sessions, agents, hooks, remote access) | subagent `app-logic` | 2 |
| 4 | GTK shell: app/window, sidebar, tabs, splits, theme, shortcuts, palette, dialogs, prefs | subagent `gtk-shell` | 2 (3 for wiring) |
| 5 | Terminal integration: Ghostty widget ↔ terminal runtime, find, clipboard, links, DnD | subagent `terminal-integration` | 1, 3, 4 |
| 6 | Right panel (WebKitGTK), Remote Access UI, notifications, desktop integration | subagent `panels-remote` | 3, 4 |
| 7 | Closed-loop verification (Broadway + socket + CLI), docs, packaging | coordinator + QA subagent | all |

## Verification

- `scripts/linux/build.sh`: sync mirror, build all products.
- `scripts/linux/test.sh`: shared + Linux unit tests (`swift test`).
- Closed-loop GUI tests under GDK Broadway (private display) driven through
  the automation socket and `toastty` CLI: create workspaces/splits, run
  commands in Ghostty terminals and read visible text back, launch a fake
  managed agent and observe hook-driven status, pair a fake remote client
  over the gateway WebSocket. Never run a nested or headless gnome-shell.
- macOS: shared-file edits are guarded and listed in `docs/linux.md`; they
  still need a macOS build (`./scripts/automation/check.sh`) before merge.
