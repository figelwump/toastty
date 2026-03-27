# Toastty Privacy and Local Data

Toastty is designed to run locally on your machine. The app itself does not send usage analytics or cloud telemetry.

## What Toastty writes locally

- `~/.toastty/config`
  - User-authored Toastty defaults such as `terminal-font-size`, `default-terminal-profile`, and `enable-agent-command-shims`.
- `~/.toastty/bin/` for ordinary runs, or `<runtime-home>/bin/` when runtime isolation is enabled and agent command shims are enabled
  - Managed `codex` and `claude` wrapper symlinks used to track manual agent invocations inside Toastty terminals.
- macOS `UserDefaults` for Toastty
  - UI-managed settings that Toastty remembers locally, currently the terminal font-size override changed from the menu.
- `~/.toastty/terminal-profiles.toml`
  - Named terminal profile definitions loaded at startup and on config reload.
- `~/.toastty/workspace-layout-profiles.json`
  - Saved workspace and window layout snapshots.
- `~/.toastty/shell/` (created by `Terminal > Install Shell Integration…`)
  - Managed shell-integration snippets. The installer also appends a `source` line to your shell init file (`~/.zshrc` for zsh, `~/.bash_profile` or `~/.profile` for bash).
- By default, `~/Library/Logs/Toastty/toastty.log`
  - Structured JSON logs.
- By default, `~/Library/Logs/Toastty/toastty.previous.log`
  - Rotated copy of the previous log file once the active log exceeds 5 MB.
- When runtime isolation is enabled for an isolated dev/test run, either by setting `TOASTTY_RUNTIME_HOME` directly or by setting `TOASTTY_DEV_WORKTREE_ROOT` and letting Toastty derive a runtime home under `artifacts/dev-runs/`:
  - `<runtime-home>/config`
  - `<runtime-home>/terminal-profiles.toml`
  - `<runtime-home>/workspace-layout-profiles.json`
  - `<runtime-home>/logs/toastty.log`
  - `<runtime-home>/instance.json`
  - a dedicated `UserDefaults` suite derived from that runtime-home path

## What Toastty creates temporarily

- Automation mode creates a Unix domain socket at a short temp path derived from the active runtime home when runtime isolation is enabled, otherwise under `$TMPDIR/toastty-$UID/events-v1.sock`, unless `TOASTTY_SOCKET_PATH` overrides it.
- Automation runs can also write screenshots and state dumps under `artifacts/` or the directory provided via `--artifacts-dir`.

## Permissions and platform integrations

- Toastty requests macOS notification permission the first time it attempts to deliver a desktop notification.
- Apps launched inside Toastty can trigger macOS camera and microphone permission prompts. Toastty declares those permissions so terminal-hosted child processes can ask for access, but Toastty itself does not capture audio or video on its own.
- The `shortcut-trace.sh` automation script requires Accessibility and Automation permissions because it drives keyboard shortcuts through `osascript`.
- Sparkle checks `https://updates.toastty.dev/appcast.xml` for available updates. This is the only outbound network connection the app makes. No usage data or telemetry is sent with the request.
- Toastty does not request contacts, calendars, photos, or location access.

## Logging behavior

Default logs are persistent so GUI builds have a supportable place to write diagnostics.

Logs can include:

- local file paths
- working directories
- config paths
- socket paths
- panel, workspace, and window identifiers
- runtime and error diagnostics

If you do not want a persistent log file:

- set `TOASTTY_LOG_FILE=none`, or
- set `TOASTTY_LOG_DISABLE=1`

You can also redirect logs to a custom path with `TOASTTY_LOG_FILE=/path/to/file.log`.

## Ghostty note

Toastty embeds Ghostty through a locally supplied `GhosttyKit.xcframework`. That artifact is built outside this repository.

For public releases, the recommended Ghostty build disables Sentry:

```bash
zig build -Demit-macos-app=false -Demit-xcframework=true -Dxcframework-target=universal -Dsentry=false
```

That keeps Toastty local-only and avoids initializing Ghostty crash reporting inside the embedded runtime.
