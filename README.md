# Toastty

<p align="center">
  <img src="docs/assets/toastty-hero.png" alt="Toastty — built for coding with agents" width="1840">
</p>

A native macOS terminal multiplexer built with Swift and powered by the [libghostty](https://ghostty.org) rendering engine.

Toastty builds on the awesomeness of Ghostty with features that are tuned for working with coding agents: workspaces in vertical tabs, direct agent launching with real-time status in the sidebar, notifications and unread badges when agents need attention, and configurable terminal profiles for setups like `tmux`, `zmx`, or `ssh`.

There are also little features throughout: keyboard shortcuts to navigate workspaces and panels, per-window font control for moving between different displays, and the performance and layout flexibility you'd expect from Ghostty.

## Getting Started

<p align="center">
  <a href="https://github.com/figelwump/toastty/releases/latest">
    <img src="docs/assets/download-macos.png" alt="Download app for macOS" height="56">
  </a>
</p>

Requires macOS 14.0+. Download the latest `.dmg` from [GitHub Releases](https://github.com/figelwump/toastty/releases/latest), open it, and drag Toastty to Applications.

For building from source, see [Building and Releasing](docs/building-and-releasing.md).

## Features

- **Workspaces in vertical tabs** — Named workspaces as vertical tabs, switch between them with `Option+1`–`Option+9`, and persist layouts across restarts
- **Independent windows** — Open a new Toastty window with `Cmd+N`; each window gets its own sidebar and workspace list, seeded from the active terminal's cwd and profile
- **Running agents** — Launch coding agents directly into terminal panels from the `Agent` menu or top bar, with live sidebar status and notifications
- **Unread badges** — See at a glance when a workspace has a coding agent that is ready for your review or response
- **Terminal profiles** — Launch named terminal setups such as `zmx`, `tmux`, or SSH from the menu or optional profile-specific shortcuts. (See [terminal profile spec](docs/terminal-profiles.md) for more details.)
- **Desktop notifications** — Notifications from coding agents and other supported processes
- **Split panes** — Divide your workspace horizontally (`Cmd+D`) or vertically (`Cmd+Shift+D`), resize splits (`Cmd+Ctrl+Arrow`), equalize them (`Cmd+Ctrl+Equals`), or zoom a single pane to full view (`Cmd+Shift+F`)
- **Window close confirmation** — `Cmd+W` and `File > Close` close the focused panel, while the red window button confirms before closing all terminals, tabs, and workspaces in that window
- **Font control** — Increase, decrease, or reset terminal font size per window, with new windows inheriting the source window's current size and layouts remembering window-local overrides
- **Ghostty terminal rendering** — Embeds Ghostty's GPU-accelerated terminal engine, with Ghostty config compatibility
- **Hot-reload configuration** — Change your config and reload it live from the menu bar
- **Automation socket** — JSON-RPC over Unix socket for scripting and external tool integration ([protocol spec](docs/socket-protocol.md))

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `Cmd+N` | New window |
| `Cmd+B` | Show or hide sidebar |
| `Cmd+Shift+N` | New workspace |
| `Cmd+Shift+E` | Rename workspace |
| `Cmd+Shift+W` | Close workspace |
| `Cmd+D` | Split horizontally |
| `Cmd+Shift+D` | Split vertically |
| `Cmd+]` | Focus next pane |
| `Cmd+[` | Focus previous pane |
| `Cmd+Shift+A` | Jump to next unread panel, or next active managed-session panel (`working`, `needs approval`, `error`) |
| `Cmd+Shift+F` | Toggle focused panel (zoom) |
| `Cmd+Ctrl+Arrow` | Resize split |
| `Cmd+W` | Close focused panel |
| `Cmd+Ctrl+=` | Equalize splits |
| `Option+1`–`Option+9` | Switch workspace |
| `Option+Shift+1`–`Option+Shift+0` | Focus pane by position |
| `Cmd+Ctrl+<key>` | Launch agent profile (when profile defines `shortcutKey`) |
| `Cmd+Ctrl+<key>` / `Cmd+Ctrl+Shift+<key>` | Profile split right / split down (when profile defines `shortcutKey`) |

`Cmd+W` and `File > Close` use Toastty's panel-close behavior. The native red close button instead asks for confirmation before closing all terminals, tabs, and workspaces in that window.

## Running Agents

Toastty can launch coding agents directly into terminal panels from the `Agent` menu or via keyboard shortcuts. Built-in session telemetry drives sidebar status, unread badges, and desktop notifications automatically — no separate agent skill or manual wiring needed.

For full details see [docs/running-agents.md](docs/running-agents.md).

### Agent profiles

Toastty loads launchable agent profiles from `~/.toastty/agents.toml`. Open the file from `Agent > Manage Agents…`; Toastty creates a commented template automatically if the file does not exist yet.

Each profile defines the menu label and the exact command Toastty should launch:

```toml
[codex]
displayName = "Codex"
argv = ["codex"]
shortcutKey = "c"

[claude]
displayName = "Claude Code"
argv = ["claude"]
```

Configured profiles appear in the `Agent` menu and as top-bar buttons. `shortcutKey` is optional; when set, Toastty binds `Cmd+Ctrl+<key>` to launch that profile.

### Profile IDs and special behavior

The TOML table name (the value in `[brackets]`) is the profile's internal ID. Toastty recognizes two well-known IDs that receive first-party instrumentation:

- **`codex`** — Injects Codex session recording, notification hooks, and a log watcher that surfaces live status (working, needs approval, idle) in the sidebar
- **`claude`** — Injects Claude Code lifecycle hooks that report session state back to the sidebar automatically

This matching is keyed on **the profile ID**, not on the command in `argv`:

```toml
[codex]                       # gets Codex instrumentation (ID is "codex")
argv = ["codex"]

[codex]                       # still gets Codex instrumentation
argv = ["/my/codex-wrapper"]  # (ID is "codex", regardless of argv)

[my-codex]                    # no special handling
argv = ["codex"]              # (ID is "my-codex", not "codex")
```

Any other profile ID launches the configured command with base `TOASTTY_*` session context but without agent-specific instrumentation. Custom agents can report status manually via the bundled CLI path exposed in `TOASTTY_CLI_PATH` — see the [full guide](docs/running-agents.md#custom-and-third-party-agents).

## CLI

Toastty bundles a `toastty` CLI for communicating with the running app over its automation socket. When Toastty launches an agent it injects `TOASTTY_CLI_PATH` into the environment, and the CLI is how agents and wrapper scripts report status back to the sidebar.

| Command | Description |
|---|---|
| `notify <title> <body>` | Emit a macOS desktop notification |
| `session start` | Create a new agent session |
| `session status` | Update session state (`idle`, `working`, `needs_approval`, `ready`, `error`) |
| `session update-files` | Report files changed during a session |
| `session stop` | End an active session |

Most flags fall back to `TOASTTY_*` environment variables that Toastty injects automatically, so agents launched from Toastty can often call the CLI with minimal arguments:

```bash
"$TOASTTY_CLI_PATH" session status --session "$TOASTTY_SESSION_ID" --kind working --summary "Thinking"
"$TOASTTY_CLI_PATH" session stop --session "$TOASTTY_SESSION_ID"
"$TOASTTY_CLI_PATH" notify "Done" "Agent finished"
```

For the full command reference including all flags, environment variables, JSON output format, and exit codes, see [docs/cli-reference.md](docs/cli-reference.md).

## Configuration

Toastty respects your Ghostty configuration. Config is loaded in this order:

1. `TOASTTY_GHOSTTY_CONFIG_PATH` environment variable
2. `$XDG_CONFIG_HOME/ghostty/config`
3. `~/.config/ghostty/config`
4. Ghostty defaults

Toastty uses `~/.toastty/config` for user-authored defaults and a small amount of macOS `UserDefaults` state for UI behavior. Window-local font overrides are persisted with workspace/window layout snapshots instead of rewriting config files.

- `terminal-font-size` in `~/.toastty/config` sets the baseline font size Toastty should prefer before any window-local UI override
- `default-terminal-profile` in `~/.toastty/config` applies a profile ID from `~/.toastty/terminal-profiles.toml` to newly created terminals only, including ordinary split shortcuts like `Cmd+D` and `Cmd+Shift+D`
- `Increase Terminal Font`, `Decrease Terminal Font`, and `Reset Terminal Font` update the active window's persisted layout state instead of rewriting your config file

Example:

```toml
terminal-font-size = 13
default-terminal-profile = "zmx"
```

### Terminal profiles

Terminal profiles are Toastty's way to turn a new pane into a named environment with predictable startup behavior, labeling, and optional split shortcuts. They can be used to run any script at terminal pane startup; for example, run `zmx` or `tmux` for session persistence, `ssh` into a specific remote server, etc.

Features:

- restore the same profile binding after Toastty relaunches and workspace state is reloaded
- open `Split Right` and `Split Down` actions from `Terminal > <Profile Name>`
- bind optional `shortcutKey` values to `Cmd+Ctrl+<key>` and `Cmd+Ctrl+Shift+<key>` profile splits
- optionally set a default profile for every new terminal open

Profiles live in `~/.toastty/terminal-profiles.toml` for ordinary runs, or in the active runtime home's `terminal-profiles.toml` when runtime isolation is enabled. Set `TOASTTY_TERMINAL_PROFILES_PATH` if you want Toastty to load another file instead. Each profile defines the menu label, the panel-header badge label, a startup command that Toastty sends to the pane's login shell when the pane is created or restored, and an optional `shortcutKey`.

```toml
[zmx]
displayName = "ZMX"
badge = "ZMX"
startupCommand = "zmx attach toastty.$TOASTTY_PANEL_ID"
shortcutKey = "z"
```

The full schema, validation rules, and more examples are in [docs/terminal-profiles.md](docs/terminal-profiles.md).

Toastty sets these environment variables for profiled panes:

- `TOASTTY_PANEL_ID`
- `TOASTTY_TERMINAL_PROFILE_ID`
- `TOASTTY_LAUNCH_REASON` (`create` or `restore`)

Some profiles attach to long-lived shell sessions such as `zmx` or `tmux`.
In that setup, Toastty only sees live pane-title updates if the shell inside
the multiplexer emits title sequences on prompt redraws. See below for
installing the shell integration to do this.

Profile bindings are persisted with the workspace layout, so profiled panes reopen
with the same profile after restart. An example `zmx` profile is included at
[`examples/terminal-profiles/zmx.toml`](examples/terminal-profiles/zmx.toml).
When a profile still exists, the panel-header badge resolves from the live
profile definition.

If you set `default-terminal-profile` in `~/.toastty/config`, Toastty uses that
profile only for new terminals it creates automatically. Existing terminals keep
their current profile bindings.

#### Shell integration

Use `Terminal > Install Shell Integration…` to set up live pane titles automatically.

Toastty writes a managed snippet under `~/.toastty/shell/` and adds one
`source` line to the shell init file it detects:

- `zsh` → `~/.zshrc`
- `bash` → `~/.bash_profile` by default, or an existing `~/.profile`

After installing, new profiled panes pick it up automatically. Existing `zmx`
or `tmux` sessions need to restart, or you need to re-source the init file
inside that session, before panel titles start updating.

Shell integration installation is disabled while runtime isolation is enabled, because sandboxed dev/test runs must not rewrite your login shell files.

For manual dotfile setup, see [docs/shell-integration.md](docs/shell-integration.md).

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

## Privacy and Local State

Toastty is local-first. The app itself does not send usage analytics or cloud telemetry. The only outbound network connection is Sparkle's update check against `https://updates.toastty.dev/appcast.xml`.

- Toastty writes user-authored config to `~/.toastty/config`, or to `TOASTTY_RUNTIME_HOME/config` for isolated dev/test runs. `TOASTTY_DEV_WORKTREE_ROOT` also enables that isolated runtime-home behavior by deriving a stable sandbox under the worktree.
- Toastty persists window-local font overrides in its workspace layout snapshots, or in the active runtime home's snapshot file when runtime isolation is enabled.
- Toastty persists workspace layouts to `~/.toastty/workspace-layout-profiles.json`, or to the active runtime home's `workspace-layout-profiles.json` when runtime isolation is enabled.
- By default, Toastty writes structured logs to `~/Library/Logs/Toastty/toastty.log`, or to the active runtime home's `logs/toastty.log` when runtime isolation is enabled.
- Toastty requests macOS notification permission the first time it tries to deliver a desktop notification.

More detail is in [docs/privacy-and-local-data.md](docs/privacy-and-local-data.md).

## Logging

By default, logs are written to `~/Library/Logs/Toastty/toastty.log` in JSON format and rotate to `toastty.previous.log` at 5 MB. When runtime isolation is enabled, the default log moves to the active runtime home's `logs/toastty.log`.

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

- [Running Agents](docs/running-agents.md) — agents.toml configuration, profile IDs, instrumentation, launch flow, and manual integration
- [CLI Reference](docs/cli-reference.md) — `toastty` CLI commands, flags, environment variables, and integration examples
- [Building and Releasing](docs/building-and-releasing.md) — build from source, validation, signed DMGs, and GitHub release publishing
- [Ghostty Integration](docs/ghostty-integration.md) — XCFramework setup, config bridging, action parity
- [Environment and Launch Flags](docs/environment-and-build-flags.md) — build toggles, runtime env vars, automation args, and script-level inputs
- [Terminal Profiles](docs/terminal-profiles.md) — `terminal-profiles.toml` schema, shortcuts, and example profile setups
- [Shell Integration](docs/shell-integration.md) — manual shell setup for live pane titles
- [Runtime Sandboxing](docs/runtime-sandboxing.md) — runtime-home strategies, `instance.json`, and cleanup guidance
- [Privacy and Local Data](docs/privacy-and-local-data.md) — local files, permissions, sockets, logging, and Ghostty crash-reporting notes
- [Socket Protocol](docs/socket-protocol.md) — v1.0 JSON-RPC automation protocol
- [State Invariants](docs/state-invariants.md) — AppState correctness rules and validation
