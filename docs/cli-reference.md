# Toastty CLI Reference

Toastty bundles a `toastty` CLI that communicates with the running app over its automation Unix socket. The CLI is used both for agent/session reporting and for machine-first app control of a normal running Toastty instance.

When Toastty launches an agent it injects `TOASTTY_CLI_PATH` into the environment, pointing at the bundled executable. All examples below assume you invoke the CLI through that path.

## Global options

| Option | Description |
|---|---|
| `--json` | Return structured JSON instead of human-readable text |
| `--socket-path <path>` | Override the automation socket path |
| `-h`, `--help` | Print usage information |

**Socket resolution order:** `--socket-path` flag > `TOASTTY_SOCKET_PATH` env var > app-resolved default socket path. For runtime-isolated launches, that default starts from the stable runtime-home-derived socket path and can resolve to a per-process sibling such as `events-v1-<pid>.sock` if the stable path is already owned by a live listener.

## Smoke test

For a one-command local validation of the CLI's default live-control surface against a normal Toastty launch, run:

```bash
./scripts/automation/smoke-cli-live-control.sh
```

This smoke builds the app, launches a runtime-isolated non-automation instance, reads that run's `instance.json`, and validates the CLI against the matching live socket. It also strips inherited `TOASTTY_*` launch context first so an existing managed-agent shell session does not accidentally target some other running Toastty instance.

## Commands

### `doctor`

Run local checks for common Toastty troubleshooting issues.

```
toastty [--json] [--socket-path <path>] doctor
```

`doctor` checks the resolved automation socket, runtime metadata, shell
integration markers, managed agent shims, and log readability. It reads local
state and actively connects to the local Toastty automation socket for a ping
when one is present. Human output is a pass/warn/fail checklist with remediation
hints. With `--json`, the CLI returns the same structured check report for
agents and scripts.

The command does not write a diagnostics bundle, upload anything, or attempt
automatic fixes. It exits non-zero only when at least one check fails.

### `diagnostics collect`

Collect a local redacted diagnostics JSON bundle. This command reads local disk
state and probes the Toastty socket; collection itself does not upload anything.

```
toastty diagnostics collect [--shell-probe <file>] [--note <text>] [--out <file>]
```

The JSON includes embedded redacted log contents, app/runtime metadata, shell
integration status, system metadata, socket probe details, and a sanitized
in-memory audit of recent automation socket requests when the running app can
provide it. The automation audit records command/action/query IDs, caller and
selector IDs, safe boolean flags, outcome, and duration; it omits freeform
payload text such as terminal input, pasted content, argv, environment values,
file lists, and file contents. If `--out` is omitted, the CLI writes to a
temporary path. The printed summary includes the same shared check counts used
by `toastty doctor`.

### `diagnostics submit`

Submit an already-collected diagnostics JSON bundle to the configured Toastty
diagnostics Worker.

```
toastty diagnostics submit --file <file> [--contact <text>] [--endpoint <url>] [--yes] [--dry-run] [--allow-secret-scan-warning]
```

Without `--yes`, the command validates the file and prints the upload summary
without sending anything. `--dry-run` also validates and previews without
uploading, even when `--yes` is present. With `--yes` and no `--dry-run` or
`--contact`, it uploads the exact JSON bytes from `--file`; it does not rebuild
or re-redact the bundle.

When `--contact <text>` is provided, the source file is left unchanged. The
submit command appends `Contact: <text>` to the diagnostics note in the in-memory
upload payload, then validates and secret-scans that final payload before any
upload. Contact text remains cleartext in the submitted diagnostics note.

Endpoint resolution order is `--endpoint`, `TOASTTY_DIAGNOSTICS_ENDPOINT`, then
the endpoint embedded at build time. The upload key is read from
`TOASTTY_DIAGNOSTICS_UPLOAD_KEY`, `TOASTTY_DIAGNOSTICS_UPLOAD_KEY_FILE`, or a
build-injected value.

The submit command refuses bundles that are missing redaction metadata, use an
old schema/redaction version, exceed the upload size limit, or still appear to
contain high-confidence secret patterns. Use `--allow-secret-scan-warning` only
after manually reviewing a false positive.

On success, the Worker returns a `reportID`. Operators can fetch the stored
report through the diagnostics Worker admin endpoint, or from an agent session
with:

```bash
sv exec -- .agents/skills/toastty-diagnostics/scripts/fetch-diagnostics-report.py
sv exec -- .agents/skills/toastty-diagnostics/scripts/fetch-diagnostics-report.py <reportID>
```

The no-argument form lists recent submissions. The report-ID form fetches and
saves the selected report envelope for deeper analysis.

### `action list`

List the always-on app-control actions exposed by the running app.

```
toastty action list
```

Human-readable output prints one command per line as `id<TAB>summary`. With `--json`, the CLI returns the raw socket response, including each command descriptor's `id`, `summary`, `selectors`, `parameters`, and `aliases`.

```bash
"$TOASTTY_CLI_PATH" action list
"$TOASTTY_CLI_PATH" --json action list
```

### `action run`

Run an app action against a live Toastty instance. This surface is available in normal launches by default; it does not require automation mode.

```
toastty action run <id> [--window <id>] [--workspace <id>] [--panel <id>] [--stdin <key>] [key=value ...]
```

Selectors map directly to the socket request's `windowID`, `workspaceID`, and `panelID` arguments. Additional `key=value` arguments are passed through as action arguments. Repeating the same key produces an array, which is how repeatable arguments such as `files=... files=...` are encoded.

The CLI sends `key=value` arguments as strings. The app-control executor coerces supported argument types such as booleans (`true`, `false`, `1`, `0`, `yes`, `no`), integers, UUIDs, and string arrays.

`--stdin <key>` reads UTF-8 stdin and sends it as the named argument. Use it for payloads that are awkward to pass as a shell argument, such as Scratchpad HTML content or Scratchpad patch JSON.

```bash
"$TOASTTY_CLI_PATH" action run window.sidebar.toggle --window "$WINDOW_ID"
"$TOASTTY_CLI_PATH" action run workspace.rename --workspace "$WORKSPACE_ID" title="Infra"
"$TOASTTY_CLI_PATH" action run panel.create.local-document \
  --workspace "$WORKSPACE_ID" \
  filePath=/tmp/README.md \
  placement=newTab
"$TOASTTY_CLI_PATH" action run terminal.drop-image-files \
  --panel "$PANEL_ID" \
  files=/tmp/README.md \
  files=/tmp/installer.dmg \
  allowUnavailable=true
"$TOASTTY_CLI_PATH" --json action run workspace.create \
  --window "$WINDOW_ID" \
  title=background-worktree \
  activate=false
"$TOASTTY_CLI_PATH" action run workspace.select \
  --window "$WINDOW_ID" \
  index=2 \
  focusUnreadSessionPanel=true
"$TOASTTY_CLI_PATH" action run workspace.move \
  --window "$WINDOW_ID" \
  index=3 \
  toIndex=1
"$TOASTTY_CLI_PATH" action run workspace.tab.move \
  --workspace "$WORKSPACE_ID" \
  index=2 \
  toIndex=1
"$TOASTTY_CLI_PATH" action run panel.scratchpad.set-content \
  sessionID="$TOASTTY_SESSION_ID" \
  filePath=artifacts/scratchpad.html \
  title="Review notes"
printf '%s' "$html" | "$TOASTTY_CLI_PATH" action run panel.scratchpad.set-content \
  --stdin content \
  sessionID="$TOASTTY_SESSION_ID" \
  createPolicy=new \
  title="Separate artifact"
printf '%s' "$html" | "$TOASTTY_CLI_PATH" action run panel.scratchpad.set-content \
  --stdin content \
  sessionID="$TOASTTY_SESSION_ID"
printf '%s' "$patch" | "$TOASTTY_CLI_PATH" --json action run panel.scratchpad.patch-content \
  --stdin patch \
  sessionID="$TOASTTY_SESSION_ID" \
  expectedRevision=3
"$TOASTTY_CLI_PATH" --json action run panel.scratchpad.export \
  sessionID="$TOASTTY_SESSION_ID"
```

`workspace.create` accepts optional `title` and `activate` arguments. When
`activate=false`, Toastty appends the workspace without changing the currently
visible selection, returns the created `workspaceID` and `windowID`, and marks
the background workspace as `New` in the sidebar until the user visits it once.

`workspace.select` accepts a `workspaceID` selector or a 1-based `index`
argument. By default it changes only the selected workspace and preserves that
workspace's selected tab and focused panel. Set `focusUnreadSessionPanel=true`
when foreground navigation should also focus the newest unread managed-session
panel visible in the selected workspace tab.

`workspace.move` and `workspace.tab.move` use 1-based `index` and `toIndex`
arguments. Reordering keeps the selected workspace or tab selected, but changes
which item each numeric shortcut targets because shortcuts follow the current
visual order.

Prefer `action list --json` to discover the current canonical IDs. Common actions include:

- `window.create`
- `window.sidebar.toggle`
- `workspace.create`
- `workspace.select`
- `workspace.move`
- `workspace.rename`
- `workspace.close`
- `workspace.tab.create`
- `workspace.tab.select`
- `workspace.tab.move`
- `workspace.tab.rename`
- `workspace.tab.close`
- `panel.close`
- `panel.create.browser`
- `panel.create.local-document`
- `panel.scratchpad.set-content`
- `panel.scratchpad.patch-content`
- `panel.scratchpad.rebind`
- `panel.scratchpad.export`
- `panel.focus-mode.toggle`
- `agent.launch`
- `config.reload`
- `terminal.send-text`
- `terminal.drop-image-files` (historical name; drops local file paths of any type)

Descriptors can also advertise compatibility aliases. Those aliases are accepted by the socket executor, but canonical IDs are preferred for new integrations.

Scratchpad actions are intended for agent and automation integrations:

- `panel.scratchpad.set-content` creates or updates the Scratchpad linked to an active managed session. It requires `sessionID` plus either `filePath` or `content`, accepts optional `title`, `expectedRevision`, and `createPolicy`, resolves relative `filePath` values from the active session's `cwd` when available, and returns `windowID`, `workspaceID`, `panelID`, `documentID`, `revision`, and `created`. Session-linked Scratchpads open the source session's right panel and make the Scratchpad active there without activating another window, workspace, or workspace tab, and without moving keyboard focus into the Scratchpad. No CLI flag is needed for background creation. `createPolicy` defaults to `reuse`; set `createPolicy=new` to create a fresh session-linked Scratchpad and leave the previous one open but unbound.
- `panel.scratchpad.patch-content` updates the existing Scratchpad linked to an active managed session without sending a full HTML snapshot. It requires `sessionID`, `expectedRevision`, and `patch` as a JSON string, returns `windowID`, `workspaceID`, `panelID`, `documentID`, `previousRevision`, `revision`, `appliedEdits`, and `created=false`, and does not create a Scratchpad when none is linked. Patch JSON is limited to 262,144 UTF-8 bytes. The top-level patch object only accepts `replacements`; each replacement object only accepts `oldText` and `newText`, and unknown fields are rejected. Patch replacements apply sequentially; each `oldText` must be non-empty and occur exactly once in the current intermediate HTML. Successful patches still reload the generated Scratchpad iframe from the updated full HTML snapshot.
- `panel.scratchpad.rebind` rebinds an existing Scratchpad panel to another active managed session in the same workspace tab. It requires `sessionID` and targets the Scratchpad by `--panel`, workspace/window selectors, or the focused/active Scratchpad.
- `panel.scratchpad.export` writes a Scratchpad document to an app-chosen local HTML file and returns `filePath`, `workspaceID`, `panelID`, `documentID`, `revision`, and `title`. It can target by `sessionID` or by the normal Scratchpad panel selectors.
- `agent.launch` starts a managed agent profile in a resolved terminal panel. It
  requires `profileID` and accepts optional `cwd`, repeatable
  `initialCommands=<command>`, repeatable `env.NAME=value`, and `initialPrompt`
  arguments. `cwd` must be absolute or `~`-expanded and becomes both the launch
  directory and the session working directory; `initialCommands` are raw
  single-line shell snippets rendered after `cd <cwd>` and before the final
  agent command; `env.NAME` entries are injected before Toastty's managed launch
  context on the final agent command and are not exported to
  `initialCommands`; `initialPrompt` is appended only for supported profiles.
  Callers own side effects and trust changes in `initialCommands`, such as
  `direnv allow`. Built-in `codex`, `claude`, `opencode`, `mimocode`, and `pi` automation launches work
  even when the user has not created `~/.toastty/agents.toml`. CLI/app-control
  `agent.launch` preserves the current AppKit first responder; focus the target
  workspace or panel separately when it should become the interactive keyboard
  target. When an active managed session invokes `agent.launch`, Toastty records
  that caller as the new session's parent so the child can appear nested in the
  sidebar and contribute to the parent's orchestration status.

```bash
"$TOASTTY_CLI_PATH" action run agent.launch \
  --workspace "$WORKSPACE_ID" \
  profileID=codex \
  cwd="$HOME/new-work-tree" \
  "initialCommands=direnv allow" \
  env.TOASTTY_DEV_WORKTREE_ROOT="$HOME/new-work-tree" \
  initialPrompt="/work-on POP-1234"
```

`terminal.send-text` writes directly to the resolved terminal surface and does
not move AppKit keyboard focus. This lets automation prepare or start work in a
background workspace without causing the user's next physical keystrokes to go
to that hidden terminal. To make a terminal the interactive keyboard target,
select/focus the workspace or panel separately before sending text.

Patch JSON uses exact text replacements:

```json
{
  "replacements": [
    {
      "oldText": "<section id=\"risk\">Old copy</section>",
      "newText": "<section id=\"risk\">New copy</section>"
    }
  ]
}
```

### `query list`

List the always-on app-control queries exposed by the running app.

```
toastty query list
```

Like `action list`, human-readable output prints `id<TAB>summary`, and `--json` returns the full descriptor payload.

```bash
"$TOASTTY_CLI_PATH" query list
"$TOASTTY_CLI_PATH" --json query list
```

### `query run`

Run a read-only app query against a live Toastty instance.

```
toastty query run <id> [--window <id>] [--workspace <id>] [--panel <id>] [key=value ...]
```

Query selectors and `key=value` argument handling follow the same rules as `action run`.

```bash
"$TOASTTY_CLI_PATH" query run workspace.snapshot --workspace "$WORKSPACE_ID"
"$TOASTTY_CLI_PATH" query run terminal.visible-text --panel "$PANEL_ID" contains="ready"
```

Prefer `query list --json` to discover the current canonical IDs. Common queries include:

- `workspace.snapshot`
- `terminal.state` (returns `windowID`, `workspaceID`, `panelID`, and terminal metadata)
- `terminal.visible-text`
- `panel.local-document.state`
- `panel.browser.state`
- `panel.scratchpad.lookup`
- `panel.scratchpad.state`

`panel.scratchpad.state` returns Scratchpad panel metadata, including the document ID, revision, linked session ID when present, host lifecycle state, current bootstrap diagnostics, and content hashes for automation checks.

`panel.scratchpad.lookup` requires `sessionID` and returns metadata for the
Scratchpad linked to that active session without exporting its content. A
successful lookup with no linked Scratchpad returns `linked: false` with null
panel, document, revision, and title fields; a linked result returns
`linked: true`, the panel and document identifiers, revision, title, and the
source session metadata. The query does not scan other Scratchpad panels or
infer a link from focus state.

### Internal managed-agent commands

These commands are used by Toastty-owned command shims and app integration code.
They are not intended as third-party agent integration APIs. Custom agents should
use `session start`, `session status`, `session update-files`, and
`session stop` directly.

```
toastty agent prepare-managed-launch --agent <id> --panel <id> --arg <value> [--arg <value> ...] [--cwd <path>] [--preflight-policy skip|interactive]
toastty agent managed-launch-preflight-decision --token <id>
```

`agent prepare-managed-launch` asks the running app to build the managed launch
plan for a built-in agent command. `--arg` is repeatable and supplies the exact
agent command argv. `--preflight-policy` defaults to `skip`; `interactive`
allows the app to pause a Codex launch for status-hook setup or trust warnings.

When interactive preflight is required, the response reports
`kind: "preflightRequired"` with a token. The shim then calls
`agent managed-launch-preflight-decision --token <id>` and either continues with
the returned decision or exits before starting the real agent command.

### `notify`

Emit a macOS desktop notification.

```
toastty notify <title> <body> [--workspace <id>] [--panel <id>]
```

| Argument / Option | Required | Description |
|---|---|---|
| `<title>` | yes | Notification title |
| `<body>` | yes | Notification body |
| `--workspace <id>` | no | Target workspace UUID |
| `--panel <id>` | no | Target panel UUID |

```bash
"$TOASTTY_CLI_PATH" notify "Build Complete" "All tests passed"
```

### `session start`

Create a new agent session for a terminal panel.

```
toastty session start --agent <id> --panel <id> [--session <id>] [--cwd <path>] [--repo-root <path>]
```

| Option | Required | Env var fallback | Description |
|---|---|---|---|
| `--agent <id>` | yes | `TOASTTY_AGENT` | Agent profile ID |
| `--panel <id>` | yes | `TOASTTY_PANEL_ID` | Terminal panel UUID |
| `--session <id>` | no | `TOASTTY_SESSION_ID` | Session ID (auto-generated if omitted) |
| `--cwd <path>` | no | `TOASTTY_CWD` | Panel working directory |
| `--repo-root <path>` | no | `TOASTTY_REPO_ROOT` | Git repository root |

Returns the resolved session ID.

### `session status`

Update the status of an active session. This drives the sidebar indicator and can trigger unread badges and desktop notifications.

```
toastty session status --session <id> --kind <kind> --summary <text> [--panel <id>] [--detail <text>]
```

| Option | Required | Env var fallback | Description |
|---|---|---|---|
| `--session <id>` | yes | `TOASTTY_SESSION_ID` | Existing session ID |
| `--kind <kind>` | yes | — | One of `idle`, `working`, `needs_approval`, `ready`, `error` |
| `--summary <text>` | yes | — | Short status line (non-empty) |
| `--panel <id>` | no | `TOASTTY_PANEL_ID` | Panel UUID |
| `--detail <text>` | no | — | Additional detail text |

**Kind values:**

| Kind | Meaning | Triggers notification? |
|---|---|---|
| `idle` | Waiting for input | no |
| `working` | Actively processing | no |
| `needs_approval` | Awaiting user approval | yes |
| `ready` | Finished, ready for review | yes |
| `error` | Error state | yes |

```bash
"$TOASTTY_CLI_PATH" session status \
  --session "$TOASTTY_SESSION_ID" \
  --kind working \
  --summary "Analyzing code"
```

### `session background-activity`

Report child-agent or provider-subagent activity for an active managed session.
This is an internal command used by Toastty-owned provider instrumentation; it
is not a general-purpose third-party integration API.

```
toastty session background-activity start|finish \
  --session <id> --activity <id> --kind child_agent|subagent \
  [--panel <id>] [--display-name <text>] [--command <text>] [--pid <pid>]
```

| Option | Required | Env var fallback | Description |
|---|---|---|---|
| `start` / `finish` | yes | — | Add/update or finish the activity |
| `--session <id>` | yes | `TOASTTY_SESSION_ID` | Parent managed session |
| `--activity <id>` | yes | — | Stable activity identifier |
| `--kind <kind>` | yes | — | `child_agent` or `subagent` |
| `--panel <id>` | no | `TOASTTY_PANEL_ID` | Parent terminal panel UUID |
| `--display-name <text>` | no | — | Activity label shown in the sidebar |
| `--command <text>` | no | — | Optional provider command/context text |
| `--pid <pid>` | no | — | Positive process ID for stale-activity checks |

`start` creates or refreshes a child row; `finish` removes it. The corresponding
socket event also supports provider-owned `sync` payloads for replacing the
current subagent set and reporting pending background-task counts. Outstanding
activity contributes to the parent session's waiting projection.

### `session update-files`

Report files changed during a session.

```
toastty session update-files --session <id> --file <path> [--file <path> ...] [--panel <id>] [--cwd <path>] [--repo-root <path>]
```

| Option | Required | Env var fallback | Description |
|---|---|---|---|
| `--session <id>` | yes | `TOASTTY_SESSION_ID` | Existing session ID |
| `--file <path>` | yes | — | Changed file path (repeatable) |
| `--panel <id>` | no | `TOASTTY_PANEL_ID` | Panel UUID |
| `--cwd <path>` | no | `TOASTTY_CWD` | Base directory for relative paths |
| `--repo-root <path>` | no | `TOASTTY_REPO_ROOT` | Git repository root |

Multiple `--file` arguments can be provided. Relative paths are resolved against `--cwd`. File updates are coalesced server-side with a 0.5-second window per session.

```bash
"$TOASTTY_CLI_PATH" session update-files \
  --session "$TOASTTY_SESSION_ID" \
  --file src/main.rs \
  --file Cargo.toml
```

### `session stop`

End an active session.

```
toastty session stop --session <id> [--panel <id>] [--reason <text>]
```

| Option | Required | Env var fallback | Description |
|---|---|---|---|
| `--session <id>` | yes | `TOASTTY_SESSION_ID` | Existing session ID |
| `--panel <id>` | no | `TOASTTY_PANEL_ID` | Panel UUID |
| `--reason <text>` | no | — | Reason for stopping |

```bash
"$TOASTTY_CLI_PATH" session stop \
  --session "$TOASTTY_SESSION_ID" \
  --reason "User cancelled"
```

### `session scope`

Manage cooperative workspace scope for an active managed session. Workspace
scope is an orchestration guardrail, not a security sandbox; see
[Workspace Scope](agents/workspace-scope.md) for semantics and enforcement
coverage.

```
toastty session scope show [--session <id>]
toastty session scope set-current [--session <id>]
toastty session scope set --workspace <id> [--workspace <id> ...] [--session <id>]
toastty session scope add --workspace <id> [--workspace <id> ...] [--session <id>]
toastty session scope clear [--session <id>]
```

| Subcommand | Description |
|---|---|
| `show` | Print whether the session is unrestricted or workspace-scoped. With `--json`, returns `sessionID`, `isScoped`, `workspaceIDs`, and `effectiveWorkspaceIDs`. |
| `set-current` | Scope the current managed session to its current workspace only. Requires `TOASTTY_PANEL_ID` and can only target the caller session. |
| `set` | Replace the explicit workspace scope with the supplied workspace IDs. |
| `add` | Add workspace IDs to the existing explicit scope. |
| `clear` | Return the session to unrestricted automation. |

When `--session` is omitted, the CLI uses `TOASTTY_SESSION_ID`. `set-current`
also uses `TOASTTY_PANEL_ID` to verify the current panel still belongs to a
Toastty workspace. Use `set` or `add` for another active session or for
additional workspaces the user explicitly assigned.

### `session ingest-agent-event`

Process agent lifecycle events from stdin. This is a CLI-local command used by the built-in Claude, Codex, OpenCode, MiMo Code, and Pi instrumentation. It reads structured event JSON from stdin and translates it into source-specific socket events, including status updates, stops, file updates, Codex hook/notify events, and provider-native resume-record updates when the source supports them.

```
toastty session ingest-agent-event --source <source> [--session <id>] [--panel <id>]
```

| Option | Required | Env var fallback | Description |
|---|---|---|---|
| `--source <source>` | yes | — | `claude-hooks`, `codex-hooks`, `codex-notify`, `opencode-plugin`, `mimocode-plugin`, or `pi-extension` |
| `--session <id>` | no | `TOASTTY_SESSION_ID` | Session ID |
| `--panel <id>` | no | `TOASTTY_PANEL_ID` | Panel UUID |

This command is not intended for third-party integrations. Custom agents should use `session status` and `session stop` directly.

Toastty's built-in Claude, Codex, OpenCode, MiMo Code, and Pi launch helpers invoke this command with an explicit `TOASTTY_SOCKET_PATH` injected at launch time. That injected value is the authoritative resolved socket path for the target app instance, including runtime-isolated fallback cases. If a helper cannot reach the app, it keeps the agent process alive and logs the CLI failure details. Installed Codex status hooks write to `~/.toastty/codex-hooks/telemetry-failures.log`; per-session helpers write to `telemetry-failures.log` in that session's temporary launch artifacts directory. Codex, OpenCode, MiMo Code, and Pi keep per-session artifacts only while the session is active; Claude can retain hook artifacts briefly after session stop so late hooks fail softly instead of hitting missing-file shell errors.

## Environment variables

When Toastty launches an agent, these variables are injected into the agent's environment:

| Variable | Description |
|---|---|
| `TOASTTY_CLI_PATH` | Absolute path to the bundled `toastty` CLI |
| `TOASTTY_SESSION_ID` | Session ID for the current agent run |
| `TOASTTY_PANEL_ID` | Terminal panel UUID |
| `TOASTTY_SOCKET_PATH` | Resolved automation socket path for the target app instance |
| `TOASTTY_CWD` | Resolved launch working directory: explicit automation `cwd` when supplied, otherwise the target or restored panel working directory when available |
| `TOASTTY_REPO_ROOT` | Git repository root inferred from the resolved launch working directory when available |

Most CLI flags fall back to their corresponding environment variable when not provided explicitly, so agents launched by Toastty can often omit flags like `--session` and `--panel`.

To recover the owning Toastty window for the current thread, query the current panel:

```bash
window_id="$("$TOASTTY_CLI_PATH" --json query run terminal.state --panel "$TOASTTY_PANEL_ID" \
  | python3 -c '
import json, sys
data = json.load(sys.stdin)
value = data["result"].get("windowID")
if not value:
    raise SystemExit("missing windowID in terminal.state result")
print(value)
')"
```

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | Runtime error (socket failure, validation error, bad response) |
| `64` | Usage error (invalid arguments, missing required flags) |

## Agent ID format

Agent IDs must be lowercase, start with a letter (`a-z`), and contain only letters, digits, hyphens, and underscores. Examples: `claude`, `codex`, `my-agent`, `custom_agent_2`.

## JSON output

When `--json` is passed, responses follow the automation protocol envelope:

```json
{
  "protocolVersion": "1.0",
  "kind": "response",
  "requestID": "...",
  "ok": true,
  "result": { ... }
}
```

Error responses set `ok: false` and include an `error` object with `code` and `message` fields.

For `action list` and `query list`, `result.commands` contains an array of descriptors:

```json
{
  "id": "workspace.rename",
  "kind": "action",
  "summary": "Rename a workspace.",
  "selectors": ["windowID", "workspaceID"],
  "parameters": [
    {
      "name": "title",
      "summary": "Title text.",
      "valueType": "string",
      "required": true,
      "repeatable": false
    }
  ],
  "aliases": []
}
```

## Custom agent integration example

A minimal wrapper script that reports status back to Toastty:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Toastty injects TOASTTY_CLI_PATH, TOASTTY_SESSION_ID, etc.
cli="$TOASTTY_CLI_PATH"
session="$TOASTTY_SESSION_ID"

"$cli" session status --session "$session" --kind working --summary "Starting"

# ... do work ...

"$cli" session update-files --session "$session" --file output.txt
"$cli" session status --session "$session" --kind ready --summary "Done"
"$cli" session stop --session "$session"
"$cli" notify "Agent finished" "Check the results"
```

See [running-agents.md](running-agents.md#custom-and-third-party-agents) for the full integration guide.
