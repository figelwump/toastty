---
name: toastty-session-status
description: Keep Toastty session telemetry current for agents running inside Toastty or reporting back to Toastty. Use when `TOASTTY_SESSION_ID`, `TOASTTY_CLI_PATH`, or other Toastty launch-context variables are present, when a run was launched from Toastty, or when the user explicitly wants Toastty session visibility. Emit concise `toastty session status` updates at meaningful state changes, use `needs_approval` only for real user blockers, `ready` when waiting with a useful result, and `error` for failures that stop progress.
---

# Toastty Session Status

Use this skill to keep Toastty's session UI informative without turning it into a command log.

## When To Use It

Use this skill when any of these are true:

- the environment includes Toastty launch-context variables such as `TOASTTY_SESSION_ID`, `TOASTTY_PANEL_ID`, `TOASTTY_SOCKET_PATH`, or `TOASTTY_CLI_PATH`
- the agent was launched from Toastty's Run Agent flow
- the user explicitly asks for Toastty status visibility or observability
- a wrapper/manual integration has enough routing context to call `toastty session start`

Do not use this skill just to narrate trivial work. If the run is so short that no meaningful intermediate state exists, a final `ready` update is enough.

## Core Rules

- In Toastty-owned launches, assume Toastty already handled `session start`. Send follow-up telemetry only.
- Only omit `--session` or `--panel` when the current process still has the matching Toastty environment variables.
- Prefer one update per meaningful state change: investigation, implementation, validation, blocked, or handoff.
- Do not emit a new status for every shell command, every file read, or every tiny substep.
- Send a fresh `working` update when the current status would become misleading or stale during longer work, or after several minutes of steady long-running work.
- Use `session.update-files` when you know which files changed. Batch related paths instead of sending one event per file.
- When a milestone both changes files and changes visible state, send `session.update-files` before the corresponding status update.
- Use `ready` when the agent is waiting on the user with a useful result or decision point.
- Use `needs_approval` only when the agent is actually blocked on user approval, missing input, or an access decision.
- Use `error` when progress has stopped because of a failure the agent cannot reasonably route around.
- Treat telemetry failures as best-effort in normal runs. Do not let a failed status emission abort the main task unless the task is specifically about Toastty telemetry.
- Use `session stop` only when the run or wrapper is actually ending. Do not stop a still-live session just because the agent is waiting for the next user turn.

## Quick Start

Resolve the CLI from launch context when available:

```bash
TOASTTY_BIN="${TOASTTY_CLI_PATH:-toastty}"
```

In a normal Toastty-launched run, the environment usually provides session, panel, socket, and path context already, so follow-up updates can be minimal:

```bash
"$TOASTTY_BIN" session status \
  --kind working \
  --summary "inspecting repo" \
  --detail "Reviewing the CLI and status model"
```

If the run edits files:

```bash
"$TOASTTY_BIN" session update-files \
  --file skills/toastty-session-status/SKILL.md \
  --file skills/toastty-session-status/references/status-writing.md
```

When you reach a handoff point:

```bash
"$TOASTTY_BIN" session status \
  --kind ready \
  --summary "ready for review" \
  --detail "Skill docs drafted and verified"
```

## Writing Guidance

- The summary and detail are both single-line UI elements. Keep them short, specific, and user-meaningful.

Read [references/status-writing.md](references/status-writing.md) when choosing wording or cadence.

## Command Reference

Read [references/cli-workflow.md](references/cli-workflow.md) for:

- launch-context environment behavior
- when `session start` is needed and when it is not
- `session status`, `session update-files`, `session stop`, and `notify`
- manual wrapper flows outside the built-in Toastty launch path
