# Terminal Profiles

Terminal profiles let Toastty create named panes with consistent startup commands, panel badges, restore behavior, and optional keyboard shortcuts.

## File location

Toastty loads terminal profiles from:

- `~/.toastty/terminal-profiles.toml` for ordinary runs
- `<runtime-home>/terminal-profiles.toml` when runtime isolation is enabled
- `TOASTTY_TERMINAL_PROFILES_PATH` when you want to override the file path explicitly

`TOASTTY_TERMINAL_PROFILES_PATH` supports absolute paths and `~/`-prefixed paths.

Use `Terminal > Manage Terminal Profiles…` to open or create the file from Toastty.

## File format

Toastty accepts a narrow TOML-like profile file rather than the full TOML spec. In practice:

- each top-level table defines one profile
- supported keys are only `displayName`, `badge`, `startupCommand`, and `shortcutKey`
- string values must use quoted string syntax
- duplicate keys and unknown keys are rejected

Each top-level table looks like this:

```toml
[profile-id]
displayName = "Shown in Toastty menus"
badge = "Shown in the panel header"
startupCommand = "Sent to the pane's login shell"
shortcutKey = "p"
```

Profile IDs:

- must not be empty
- may contain letters, digits, `.`, `_`, and `-`
- must not start with `-`

Field reference:

| Field | Required | Notes |
|---|---|---|
| `displayName` | yes | Shown in `Terminal > <Profile Name>` menus. |
| `badge` | no | Panel-header pill label. Defaults to `displayName` when omitted. |
| `startupCommand` | yes | Sent to the pane's login shell when the pane is created or restored. |
| `shortcutKey` | no | Single letter or digit. Registers `Cmd+Opt+<key>` for Split Right and `Cmd+Opt+Shift+<key>` for Split Down. Shortcut keys are case-insensitive and must be unique across profiles. |

If the file fails to parse at startup, Toastty logs a warning and continues with an empty profile catalog until the file is fixed and reloaded.

## Launch and restore behavior

- Toastty sends `startupCommand` when the pane is created and again when a profiled pane is restored from persisted workspace state.
- Profile bindings are persisted with workspace layouts, so the same profile comes back after relaunch.
- If the referenced profile no longer exists, Toastty falls back to a degraded badge based on the stored profile ID instead of silently pretending the pane was unprofiled.
- `default-terminal-profile` in `~/.toastty/config` applies only to new terminals Toastty creates automatically, including the standard `Cmd+D` and `Cmd+Shift+D` split shortcuts. It does not rewrite existing pane bindings.

## Environment variables available to profiled panes

Toastty sets these variables before running the profile startup command:

- `TOASTTY_PANEL_ID`
- `TOASTTY_TERMINAL_PROFILE_ID`
- `TOASTTY_LAUNCH_REASON`

`TOASTTY_LAUNCH_REASON` is:

- `create` for a newly created pane
- `restore` when Toastty is reconstructing a persisted pane after relaunch

## Keyboard shortcuts

When a profile defines `shortcutKey`, Toastty registers two split actions:

- `Cmd+Opt+<key>` for `Split Right`
- `Cmd+Opt+Shift+<key>` for `Split Down`

These shortcuts point at the same profile-specific actions exposed in the `Terminal` menu.

## Shell integration, history, and live titles

Profile startup commands are good for bootstrapping a session, but long-lived multiplexers such as `tmux` or `zmx` take over the shell after launch. For Toastty to keep seeing live pane titles from inside those sessions, and for restored `zsh` or `bash` panes to re-import pane-local command journals while preserving shared shell history, install Toastty's shell integration from `Toastty > Install Shell Integration…` or follow the manual setup instructions in the README. Existing multiplexer sessions may only need a re-source for title updates, but restored-pane command recall only applies to shells launched after Toastty injects the launch context environment, so older sessions usually need a restart.

Without shell integration:

- the initial title can come from the startup command
- later prompt-driven title updates inside `tmux` or `zmx` may not reach Toastty
- restored panes fall back to shared shell history instead of their pane-local recent-command context

Shell integration installation is disabled while runtime isolation is enabled, because sandboxed dev/test runs must not rewrite the user's shell dotfiles.

## Examples

### `zmx`

```toml
[zmx]
displayName = "ZMX"
badge = "ZMX"
startupCommand = "zmx attach toastty.$TOASTTY_PANEL_ID"
shortcutKey = "z"
```

This maps one Toastty pane to one persistent `zmx` session name derived from the stable Toastty panel ID.

### `tmux`

```toml
[tmux]
displayName = "tmux"
badge = "TMUX"
startupCommand = "tmux new-session -A -s toastty.$TOASTTY_PANEL_ID"
shortcutKey = "t"
```

This gives each pane its own reusable `tmux` session, which makes restore behavior line up cleanly with Toastty's persisted panel IDs.

### `ssh`

```toml
[ssh-prod]
displayName = "SSH Prod"
badge = "SSH"
startupCommand = "ssh prod"
shortcutKey = "s"
```

This is the simplest form of a profile: create a pane, connect to a host, and let the badge show at a glance that the pane is a remote session.

## Related docs

- [README](../README.md)
- [Configuration](configuration.md)
- [Ghostty Integration](ghostty-integration.md)
- [Runtime Sandboxing](runtime-sandboxing.md)
- [Environment and Launch Flags](environment-and-build-flags.md)
