# Toastty

<p align="center">
  <img src="docs/assets/toastty-hero.png" alt="Toastty — multiple workspaces with split panes, Claude Code, and live logs" width="1840">
</p>

A native macOS terminal multiplexer built with Swift and powered by the [libghostty](https://ghostty.org) rendering engine.

Toastty builds on the the awesomeness of Ghostty with features that are tuned for working with coding agents: workspaces in vertical tabs, notifications and unread badges when agents are done working, and the performance and layout flexibility you're used to with Ghostty.

There are also little features throughout. For example, keyboard shortcuts to jump directly to a panel and global font control (resize the font of all terminals at once, useful when switching between external monitors and your laptop for example).

## Features

- **Workspaces in vertical tabs** — Named workspaces as vertical tabs, switch between them with `Cmd+1`–`Cmd+9`, and persist layouts across restarts
- **Unread badges** — See at a glance when a workspace has a coding agent that is ready for your review or response
- **Split panes** — Divide your workspace horizontally (`Cmd+D`) or vertically (`Cmd+Shift+D`), resize splits (`Cmd+Ctrl+Arrow`), equalize them (`Cmd+Ctrl+Equals`), or zoom a single pane to full view (`Cmd+Shift+F`)
- **Font control** — Increase, decrease, or reset terminal font size globally across all terminals at once, persisted in `~/.toastty/config`
- **Ghostty terminal rendering** — Embeds Ghostty's GPU-accelerated terminal engine, with Ghostty config compatibility
- **Hot-reload configuration** — Change your config and reload it live from the menu bar
- **Desktop notifications** — Notifications from coding agents and other supported processes
- **Automation socket** — JSON-RPC over Unix socket for scripting and external tool integration ([protocol spec](docs/socket-protocol.md))

## Requirements

- macOS 14.0+
- [Tuist](https://tuist.io) (build system)
- Xcode 16+ with Swift 6.0
- [sv](https://github.com/figelwump/sv) (secret vault for development credentials)
- Ghostty XCFramework (optional — Toastty can build in fallback mode without it)

## Getting Started

### 1. Clone and generate

```bash
git clone https://github.com/figelwump/toastty.git
cd toastty
tuist generate
```

`Project.swift` is the source of truth. The generated `toastty.xcworkspace` is not committed, so re-run `tuist generate` after manifest or file-layout changes.

### 2. Install sv

[sv](https://github.com/figelwump/sv) is a lightweight macOS secret vault that stores API keys and credentials in the native Keychain and injects them into processes at runtime. Automation scripts in this repo use `sv exec --` to run commands that need secrets without exposing values in shell history or environment dumps.

```bash
curl -fsSL https://raw.githubusercontent.com/figelwump/sv/main/install.sh | bash
```

After installing, store any required secrets with `sv set <KEY>`. To run a command with secrets injected:

```bash
sv exec -- <command>
```

### 3. Install Ghostty XCFramework (optional)

```bash
GHOSTTY_XCFRAMEWORK_SOURCE=/path/to/GhosttyKit.xcframework \
  ./scripts/ghostty/install-local-xcframework.sh
```

Set `GHOSTTY_XCFRAMEWORK_VARIANT=release|debug` to control the destination artifact path. The installer also auto-detects a sibling `../ghostty/macos/GhosttyKit.xcframework` checkout when present.

For the recommended upstream Ghostty build command, release note guidance, see [docs/ghostty-integration.md](docs/ghostty-integration.md).

After installing, regenerate:

```bash
tuist generate
```

To build without Ghostty:

```bash
TUIST_DISABLE_GHOSTTY=1 tuist generate
```

### 4. Build

```bash
ARCH="$(uname -m)"
xcodebuild -workspace toastty.xcworkspace -scheme ToasttyApp \
  -configuration Debug \
  -destination "platform=macOS,arch=${ARCH}" \
  -derivedDataPath Derived build
```

Or open `toastty.xcworkspace` in Xcode and hit Run.

### 5. Validate

```bash
# Full gate: generate + build + test
./scripts/automation/check.sh

# Smoke UI automation
./scripts/automation/smoke-ui.sh

# Keyboard shortcut tracing
./scripts/automation/shortcut-trace.sh
```

### 6. Build a signed release DMG

The release script expects a release Ghostty artifact at `Dependencies/GhosttyKit.Release.xcframework`, a local `Developer ID Application` certificate, and notarization credentials injected at runtime.

Use an explicit marketing version plus a monotonically increasing build number:

```bash
sv exec -- env \
  TOASTTY_VERSION=0.1.0 \
  TOASTTY_BUILD_NUMBER=1 \
  TUIST_DEVELOPMENT_TEAM=<TEAM_ID> \
  ./scripts/release/release.sh
```

The script archives the app, exports a signed bundle, creates a plain drag-to-install DMG, notarizes it, staples it, and writes outputs under `artifacts/release/`.

### 7. Publish a draft GitHub Release

After the DMG exists locally, publish it to GitHub Releases with the helper script. The script defaults to a draft release; pass `--publish` only when you want the release to go live immediately.

Prerequisites:
- `gh` is installed and authenticated for the target repo
- the matching Git tag already exists locally and on `origin`

Create release notes first. For public releases, include the embedded Ghostty commit and build flags you used for the shipped xcframework.

```bash
sv exec -- env \
  TOASTTY_VERSION=0.1.0 \
  TOASTTY_BUILD_NUMBER=1 \
  ./scripts/release/publish-github-release.sh \
  --notes-file /path/to/release-notes.md
```

Add `--dry-run` to print the exact `gh release create ...` command without creating a release. If `origin` is not a parseable GitHub remote, pass `--repo <owner/repo>` explicitly.

## Configuration

Toastty respects your Ghostty configuration. Config is loaded in this order:

1. `TOASTTY_GHOSTTY_CONFIG_PATH` environment variable
2. `$XDG_CONFIG_HOME/ghostty/config`
3. `~/.config/ghostty/config`
4. Ghostty defaults

Toastty-specific overrides (like font size) are stored in `~/.toastty/config`.

### Host-side split styling

These keys can be added to your Ghostty config to control how inactive splits appear:

| Key | Description |
|---|---|
| `unfocused-split-opacity` | Alpha value for inactive panes |
| `unfocused-split-fill` | Overlay color for inactive panes (falls back to `background`) |

## Architecture

```
Sources/
├── Core/          # Pure Swift state management (no UI dependencies)
│   ├── AppState, AppReducer, AppAction    # Redux-like state machine
│   ├── WorkspaceSplitTree, LayoutNode     # Binary tree layout engine
│   ├── Sessions/                          # Terminal session registry
│   └── Diagnostics/                       # JSON logging
└── App/           # SwiftUI application layer
    ├── Terminal/   # Ghostty surface hosting, runtime management
    ├── Commands/   # Menu and keyboard shortcut routing
    ├── Automation/ # Unix socket server
    └── Preferences/
```

The `CoreState` framework contains all business logic and state transitions, with no UI dependencies. The `App` layer handles SwiftUI views, Ghostty surface hosting, and system integration.

State flows through a single `AppStore` using a reducer pattern: views dispatch `AppAction`, the `AppReducer` produces new `AppState`, and SwiftUI re-renders.

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `Cmd+Shift+N` | New workspace |
| `Cmd+D` | Split horizontally |
| `Cmd+Shift+D` | Split vertically |
| `Cmd+]` | Focus next pane |
| `Cmd+[` | Focus previous pane |
| `Cmd+Shift+F` | Toggle focused panel (zoom) |
| `Cmd+Ctrl+Arrow` | Resize split |
| `Cmd+Ctrl+=` | Equalize splits |
| `Cmd+1`–`Cmd+9` | Switch workspace |
| `Option+1`–`Option+9` | Focus pane by position |

## Privacy and Local State

Toastty is local-first. The app itself does not send usage analytics or cloud telemetry.

- Toastty writes user config to `~/.toastty/config`.
- Toastty persists workspace layouts to `~/.toastty/workspace-layout-profiles.json`.
- By default, Toastty writes structured logs to `~/Library/Logs/Toastty/toastty.log`.
- Toastty requests macOS notification permission the first time it tries to deliver a desktop notification.

More detail is in [docs/privacy-and-local-data.md](docs/privacy-and-local-data.md).

## Logging

By default, logs are written to `~/Library/Logs/Toastty/toastty.log` in JSON format and rotate to `toastty.previous.log` at 5 MB.

```bash
tail -f ~/Library/Logs/Toastty/toastty.log | jq
```

| Environment Variable | Description |
|---|---|
| `TOASTTY_LOG_LEVEL` | Log level filter |
| `TOASTTY_LOG_FILE` | Custom log path (`none` to disable) |
| `TOASTTY_LOG_STDERR` | Set to `1` to also log to stderr |
| `TOASTTY_LOG_DISABLE` | Set to `1` to disable logging entirely |

Logs may contain local file paths, config paths, working directories, panel/workspace identifiers, and runtime diagnostics. If you do not want a persistent log file, set `TOASTTY_LOG_FILE=none` or `TOASTTY_LOG_DISABLE=1`.

## Documentation

- [Ghostty Integration](docs/ghostty-integration.md) — XCFramework setup, config bridging, action parity
- [Environment and Launch Flags](docs/environment-and-build-flags.md) — build toggles, runtime env vars, automation args, and script-level inputs
- [Privacy and Local Data](docs/privacy-and-local-data.md) — local files, permissions, sockets, logging, and Ghostty crash-reporting notes
- [Socket Protocol](docs/socket-protocol.md) — v1.0 JSON-RPC automation protocol
- [State Invariants](docs/state-invariants.md) — AppState correctness rules and validation
