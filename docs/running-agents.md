# Running Agents

Toastty can launch coding agents directly into terminal panels, with built-in session telemetry that drives sidebar status, unread badges, and desktop notifications.

## Quick start

1. Open `Agent > Manage Agents...` (creates `~/.toastty/agents.toml` if it does not exist)
2. Uncomment or add a profile
3. Click the agent name in the `Agent` menu or press its keyboard shortcut

Toastty sends the configured command into the focused terminal panel and starts tracking the session automatically.

## agents.toml

Agent profiles live in `~/.toastty/agents.toml`. Each TOML table defines one launchable profile:

```toml
[codex]
displayName = "Codex"
argv = ["codex"]
shortcutKey = "c"

[claude]
displayName = "Claude Code"
argv = ["claude"]
```

### Fields

| Field | Required | Description |
|---|---|---|
| `displayName` | yes | Label shown in the Agent menu and toolbar buttons |
| `argv` | yes | The exact command Toastty executes, as a JSON-style string array |
| `shortcutKey` | no | Single ASCII letter or digit; registers `Cmd+Ctrl+<key>` |

### Profile ID rules

The TOML table name (the value in `[brackets]`) becomes the profile's internal ID. IDs must be lowercase, start with a letter, and contain only `a-z`, `0-9`, `-`, and `_`.

IDs are used in session telemetry, the automation socket protocol, and — critically — to decide whether Toastty applies agent-specific instrumentation at launch time.

### Shortcut conflicts

If two agent profiles share the same `shortcutKey`, or an agent shortcut conflicts with a terminal-profile shortcut, Toastty disables the conflicting binding and logs a warning on startup or config reload.

## Well-known profile IDs

Toastty recognizes two well-known profile IDs that receive first-party instrumentation: `codex` and `claude`. Any other ID launches the configured command without agent-specific wiring.

### How matching works

The special handling is keyed on **the profile ID (table name)**, not on the command in `argv`. This is an important distinction:

```toml
[codex]                      # gets Codex instrumentation (ID is "codex")
argv = ["codex"]

[codex]                      # still gets Codex instrumentation (ID is "codex")
argv = ["/usr/local/bin/my-codex-wrapper"]

[my-codex]                   # no special handling (ID is "my-codex")
argv = ["codex"]
```

The profile ID is stored as an `AgentKind` internally. When a launch resolves to `AgentKind.codex` or `AgentKind.claude`, Toastty activates the corresponding instrumentation path. When the ID is anything else, the command runs as-is with only the base session context injected.

### What `codex` enables

When the profile ID is `codex`, Toastty:

1. **Creates a notification script** that pipes Codex notification payloads into `toastty session ingest-agent-event --source codex-notify`
2. **Injects Codex config** with `-c notify=["/bin/sh", "<script-path>"]` to route lifecycle events through that script
3. **Enables session recording** by setting `CODEX_TUI_RECORD_SESSION=1` and `CODEX_TUI_SESSION_LOG_PATH=<path>`
4. **Starts a log watcher** that polls the session log file (every 250 ms) for structured JSON entries and maps them to sidebar status updates:
   - `user_message` / `task_started` / `exec_command_begin` → **Working** (with detail text)
   - `*_approval_request` / `request_user_input` → **Needs approval**
   - `task_complete` → **Ready**
   - `turn_aborted` → **Idle**
5. **Logs helper-script delivery failures** to `telemetry-failures.log` inside the temporary launch artifacts directory while the session is active, so socket or CLI errors are inspectable without breaking the Codex process

The log watcher is a temporary bridge; it will be replaced once Codex exposes stable start/approval hooks.

### What `claude` enables

When the profile ID is `claude`, Toastty:

1. **Creates a hook script** that calls `toastty session ingest-agent-event --source claude-hooks`
2. **Resolves existing Claude settings** — if the profile's `argv` includes `--settings`, Toastty reads and merges with those settings rather than replacing them
3. **Injects lifecycle hooks** into the merged Claude settings JSON under `hooks`:
   - `UserPromptSubmit` — fires when the user submits a prompt
   - `Stop` — fires when Claude stops
   - `PostToolUse` (wildcard matcher) — fires after any tool use
   - `PostToolUseFailure` (wildcard matcher) — fires after a failed tool use
   - `PermissionRequest` (wildcard matcher) — fires on permission requests
   - `Notification` (wildcard matcher) — fires on Claude notifications; Toastty currently maps `idle_prompt` to **Ready**, `permission_prompt` to **Needs approval**, and `elicitation_dialog` to **Needs approval**
4. **Writes a temporary settings file** and passes `--settings <path>` to Claude

These hooks report state changes that Toastty translates into sidebar status (working, needs approval, ready). Non-actionable notifications such as `auth_success` are ignored.
When the helper script cannot deliver a hook event back to Toastty, it appends the CLI error to `telemetry-failures.log` inside the temporary launch artifacts directory while the session is active, but still exits successfully so Claude keeps running.

## Launch flow

When you trigger an agent launch (menu click, keyboard shortcut, or socket command):

1. **Resolve target** — Toastty picks the focused terminal panel in the selected workspace, or falls back to the first terminal panel in the workspace
2. **Check panel state** — The panel must be at an interactive prompt; Toastty refuses to launch into a panel that appears busy
3. **Prepare instrumentation** — Based on the profile ID, Toastty sets up agent-specific scripts, config files, and environment variables in a temporary artifacts directory
4. **Render shell command** — Toastty builds a single shell command line with all `TOASTTY_*` context variables inline, the instrumentation environment, and the profile's `argv`
5. **Start session** — A session record is created in the session runtime store with initial status "Idle / Ready for prompt"
6. **Send to terminal** — The rendered command line is sent to the target terminal panel and submitted
7. **Begin monitoring** — For Codex, the log watcher starts polling; for Claude, hooks report events back through the CLI

When the agent process exits and the session is stopped, Toastty cleans up the temporary artifacts directory automatically.

## Manual command shims

Outside the Agent menu, Toastty can also track manual `codex` and `claude`
invocations typed directly into Toastty terminals. By default, Toastty prepends
managed wrappers for those commands into the terminal `PATH`, and those wrappers
prepare the same managed-session context before handing off to the real binary.

If you do not want Toastty intercepting those commands, set this in
`~/.toastty/config`:

```toml
enable-agent-command-shims = false
```

That opt-out affects only manual `codex` / `claude` invocations inside Toastty
terminals. Agent menu launches still use the built-in profile-ID-based
instrumentation described above.

If you change this flag while Toastty is already running, new terminals and new
shell processes pick it up immediately. Existing shells may need a new shell or
pane before their `PATH` and `TOASTTY_AGENT_SHIM_DIR` environment fully match
the new setting.

## Session context environment

Every agent launched through Toastty receives these environment variables, set inline in the rendered shell command:

| Variable | Description |
|---|---|
| `TOASTTY_SESSION_ID` | Unique session UUID |
| `TOASTTY_PANEL_ID` | UUID of the terminal panel the agent was launched into |
| `TOASTTY_SOCKET_PATH` | Path to Toastty's automation Unix socket. Built-in Claude/Codex helpers use this explicit value directly rather than relying on CLI socket discovery fallback. |
| `TOASTTY_CLI_PATH` | Path to the bundled `toastty` CLI executable |
| `TOASTTY_CWD` | Panel's working directory (if available) |
| `TOASTTY_REPO_ROOT` | Inferred git repository root (if available) |

Agent-specific variables are added on top of these (e.g. `CODEX_TUI_RECORD_SESSION` for Codex launches).

## Notifications and badges

Actionable lifecycle events — `needs_approval`, `ready`, and `error` — drive:

- **Unread badges** on the workspace tab in the sidebar
- **macOS desktop notifications** (if the user has granted notification permission)

While a managed agent session is active, Toastty suppresses overlapping terminal-originated desktop notifications for that panel so the session status path stays authoritative.

## Custom and third-party agents

For agents that are not `codex` or `claude`, Toastty still provides the base `TOASTTY_*` session context. Toastty has already created the session before your command starts, so the agent (or a wrapper script) should update and stop that existing session via the injected `TOASTTY_CLI_PATH`:

```bash
"$TOASTTY_CLI_PATH" session status --session "$TOASTTY_SESSION_ID" --kind working --summary "Thinking"
"$TOASTTY_CLI_PATH" session update-files --session "$TOASTTY_SESSION_ID" --file changed.txt
"$TOASTTY_CLI_PATH" session stop --session "$TOASTTY_SESSION_ID"
"$TOASTTY_CLI_PATH" notify "Done" "Agent finished"
```

Manual integrations can report any supported session state, including `error`, through `session status --kind ...`.

The `toastty session ingest-agent-event` subcommand is a CLI-local helper for the built-in Claude/Codex instrumentation. It is not a general-purpose integration point.

## Instructions for agents

If a user asks you to help configure Toastty agent profiles, your goal is to produce or update `~/.toastty/agents.toml` with valid launch profiles that match the user's local setup.

### Recommended workflow

1. Check whether `~/.toastty/agents.toml` already exists. If it does, inspect and preserve existing profiles unless the user explicitly wants a replacement.
2. Try to detect locally installed coding agents using best-effort heuristics such as checking the user's `PATH`, common wrapper scripts, or explicit executable paths the user mentions.
3. Prefer Toastty's well-known profile IDs when they apply:
   - Use profile ID `codex` when the launch command is Codex
   - Use profile ID `claude` when the launch command is Claude Code
4. For any other agent, choose a lowercase ID that matches Toastty's ID rules and reflects the command being launched, such as `gemini`, `pi`, or `amp`.
5. Propose the exact `agents.toml` contents to the user before writing the file. Confirm profile IDs, display names, launch commands, and optional shortcuts.
6. Only create or update `~/.toastty/agents.toml` after the user confirms.

### Discovery guidance

Discovery is heuristic. Do not claim that Toastty can authoritatively identify every installed agent.

When probing a system, prefer evidence in this order:

1. Commands already mentioned by the user
2. Existing `~/.toastty/agents.toml` entries that should be preserved or extended
3. Executables available on the user's `PATH`
4. User-specific wrapper scripts or absolute executable paths

Common launch commands you may encounter include:

| Agent | Typical command | Suggested profile ID |
|---|---|---|
| Codex | `codex` | `codex` |
| Claude Code | `claude` | `claude` |
| Gemini CLI | `gemini` or `gemini-cli` | match the executable name |
| Aider | `pi` | `pi` |
| Custom wrapper | absolute path or script name | stable lowercase ID that matches the wrapper |

The command you detect should usually become the first element of `argv`. For agents other than `codex` and `claude`, prefer using the executable name as the profile ID when that produces a valid Toastty ID. Include additional fixed flags in later array entries only when the user wants them every time Toastty launches that profile.

### Generation rules

Generate TOML that follows the same schema documented above:

- `displayName` should be a readable label for menus and toolbar buttons
- `argv` must be a TOML string array
- `shortcutKey` is optional and must be a single ASCII letter or digit

Remember that only the profile IDs `codex` and `claude` receive first-party Toastty instrumentation. If you launch Codex or Claude Code under another ID, the command still runs, but Toastty will not inject the built-in session hooks for that agent.

### Example suggestion

If you detect both Codex and Claude Code on the user's `PATH`, a reasonable proposal is:

```toml
[codex]
displayName = "Codex"
argv = ["codex"]
shortcutKey = "c"

[claude]
displayName = "Claude Code"
argv = ["claude"]
shortcutKey = "l"
```

If the user confirms, you can create or update `~/.toastty/agents.toml` with the agreed contents.

## Troubleshooting

**"No agents configured"** — `~/.toastty/agents.toml` does not exist or has no uncommented profiles. Open `Agent > Manage Agents...` to create or edit it.

**"The target terminal is not at an interactive prompt"** — Toastty inspects the terminal's visible text to determine if a command is running. Wait for the current command to finish, or use a different panel.

**Agent launches but sidebar does not update** — If the profile ID is not `codex` or `claude`, Toastty does not inject instrumentation automatically. Either use a well-known profile ID or report status manually via the `toastty` CLI.

**Shortcut does not work** — Check for conflicts with other agent or terminal-profile shortcuts. Toastty logs a warning when it detects a conflict.

**Claude settings conflict** — If your Claude profile includes `--settings` pointing to a file, Toastty merges its hooks into those settings. If the settings argument is malformed or the file cannot be read, Toastty logs a warning and launches without instrumentation.

**Telemetry helper failures** — While a managed `claude` or `codex` session is still active, inspect `telemetry-failures.log` inside that session's temporary launch artifacts directory if the sidebar stops updating. The helper scripts keep the agent process running, but they now preserve socket and CLI stderr there instead of discarding it.
