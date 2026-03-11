# Toastty Session CLI Workflow

## Command Resolution

Prefer the exact CLI path Toastty injected into the environment:

```bash
TOASTTY_BIN="${TOASTTY_CLI_PATH:-toastty}"
```

If neither `TOASTTY_CLI_PATH` nor `toastty` on `PATH` is available, skip status emission unless the task is specifically about fixing or validating the Toastty integration.

## Launch Context

Toastty may provide these environment variables:

- `TOASTTY_SESSION_ID`
- `TOASTTY_PANEL_ID`
- `TOASTTY_SOCKET_PATH`
- `TOASTTY_CWD`
- `TOASTTY_REPO_ROOT`
- `TOASTTY_AGENT`
- `TOASTTY_CLI_PATH`

For follow-up session commands, explicit flags override the environment. When the current process inherits the Toastty environment, `session status`, `session update-files`, and `session stop` can omit `--session` and `--panel`.

Only rely on omitted flags when the current process has the needed Toastty environment values in scope. If a wrapper, subshell, sandbox, or `env -i` boundary may have dropped them, pass `--session`, `--panel`, and any other required context explicitly.

## Built-In Toastty Launch Flow

In the normal Toastty Run Agent path:

- Toastty allocates the session
- Toastty records baseline `session.start`
- Toastty injects the launch-context environment into the agent process

That means the agent usually should not call `session start` itself. It should only emit follow-up events such as `session status`, `session update-files`, and sometimes `session stop`.

Example:

```bash
"$TOASTTY_BIN" session status \
  --kind working \
  --summary "editing sidebar" \
  --detail "Adjusting session status copy"
```

## Manual Or Wrapper-Owned Flow

If the agent is not launched by Toastty but still has enough context to report into Toastty:

1. Call `session start` once.
2. Capture the returned session ID and verify that it is non-empty.
3. Reuse that session ID for `status`, `update-files`, and `stop`.

Example:

```bash
SESSION_ID="$("$TOASTTY_BIN" session start \
  --agent codex \
  --panel "$PANEL_ID")"
[ -n "$SESSION_ID" ] || {
  printf 'toastty session start failed; skipping telemetry\n' >&2
  # Continue the main task without telemetry rather than aborting.
}
```

If a script needs structured output, use `--json` and read `result.sessionID`.

## Status Updates

Use:

```bash
"$TOASTTY_BIN" session status \
  --kind working|needs_approval|ready|error \
  --summary "short chip text" \
  --detail "optional one-line context"
```

Notes:

- `summary` is required.
- `detail` is optional.
- `needs_approval` is the blocked-on-user state.
- `ready` is the waiting-with-results state.
- `error` is the stopped-by-failure state.
- Re-emitting the same status is safe. Toastty keeps the latest value, but each emission refreshes recency, so repeated updates should still be intentional.
- Use repeated `working` updates for liveness when the work phase changed or the old summary went stale. Do not keep refreshing `ready`, `needs_approval`, or `error` while the session is still in the same user-meaningful state.
- Status updates are idempotent. Any state can transition to any other state — sending `working` after `error` resumes the session normally. If the agent recovers from a failure or the user provides new direction, just send the appropriate new status.

## Telemetry Failure Behavior

Treat telemetry as best-effort observability in normal runs.

- Do not let `session status`, `session update-files`, or `session stop` failures abort the main task by default.
- If a telemetry call fails, continue the main task when safe and surface the failure only if it matters to the user or the task is specifically about Toastty integration.
- When a task is explicitly about validating Toastty telemetry, treat non-zero CLI exits as real failures and investigate them directly.

## File Updates

Use `session update-files` when you know which files changed and the changed paths matter for Toastty visibility.

```bash
"$TOASTTY_BIN" session update-files \
  --file /Users/dev/project/Sources/App/SidebarView.swift \
  --file /Users/dev/project/skills/toastty-session-status/SKILL.md
```

Guidance:

- Batch related files together.
- Use absolute paths. Relative paths are acceptable only when `--cwd` or `TOASTTY_CWD` is present and matches the path base you are sending.
- If you changed no files, do not emit `update-files`.
- When the same milestone also changes visible session state, emit `session update-files` before the corresponding `ready` or `error` status.

## Stop Events

Use `session stop` when the run is truly ending, such as a wrapper handing control back to the shell or a one-shot agent process about to exit.

```bash
"$TOASTTY_BIN" session stop --reason "completed"
```

`--reason` is an optional free-form string. Keep it short and factual.

Do not stop the session merely because you are waiting for the user's next message. In that case, send `ready` instead.

## Missing Session Context

If `session status` or other session commands are called without valid session context (no `TOASTTY_SESSION_ID` in the environment and no `--session` flag), the CLI returns a non-zero exit. In that case, skip further telemetry for the run rather than retrying or aborting the main task.
