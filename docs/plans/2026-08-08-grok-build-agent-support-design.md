# Grok Build first-party agent support

**Date:** 2026-08-08  
**Status:** Design approved (brainstorm)  
**Target depth:** Claude parity (not Codex depth)  
**Hook ownership:** Per-launch session-scoped files under `~/.grok/hooks/` (no durable installer)

## Summary

Add Toastty first-party support for [Grok Build](https://x.ai) (`grok`) at roughly the same product depth as Claude Code: managed launches, typed command shims, live sidebar status, native resume, and basic subagent rows.

Grok does not offer Claude’s per-process `--settings` injection for hooks. Hooks are discovered from fixed roots (including always-trusted `~/.grok/hooks/*.json`). Toastty will therefore use **session-scoped hook files** written at launch and deleted on cleanup, rather than a Codex-style one-time global installer.

## Goals

1. Well-known profile ID `grok` with Claude-level managed-session behavior.
2. Typed `grok` shim produces the same instrumentation as menu / automation launches.
3. Sidebar status: Working, Ready, Needs approval (best-effort), Error.
4. Native resume via `grok --resume <session-id>` for restored managed panels.
5. Basic subagent / background-activity rows from Grok hook events.
6. No durable “Set Up Agent Status Hooks” flow for Grok in v1.

## Non-goals (v1)

- Codex-depth session-log / rollout watchers and stable hook trust UX.
- Isolated `GROK_HOME` process sandboxes.
- Packaging Toastty as a Grok plugin/marketplace entry.
- Full workflow / Agent Dashboard correlation.
- Accepting alternate profile IDs such as `grok-build` (only `grok` is built-in).

## Product surface

| Item | Value |
|------|--------|
| Profile / `AgentKind` ID | `grok` |
| Display name | Grok Build |
| Default argv | `["grok"]` |
| Typed shim basename | `grok` |
| Automation | Implicit `agent.launch` profile when no `agents.toml` entry exists |
| `initialPrompt` | Trailing argv for direct first-party `grok` (same rules as Claude for single-command argv) |
| Wrapper support | Built-in instrumentation when `grok` appears as its own argv element; `manualCommandNames` for typed wrappers |

Example profile:

```toml
[grok]
displayName = "Grok Build"
argv = ["grok"]
shortcutKey = "g"
```

## Context: how Toastty supports other harnesses

Toastty layers agent support:

1. **Generic profile** — any `agents.toml` ID launches a command (already works for `grok`).
2. **Built-in `AgentKind`** — profile ID selects instrumentation.
3. **Typed command shims** — PATH wrappers for manual invocations.
4. **Launch instrumentation** — hooks / plugins / extensions.
5. **Event ingestion** — provider events → session status.
6. **Native resume** — restore panels with provider resume argv.
7. **Subagent rows** — nested background activity.

Depth today: Codex (deepest) → Claude → OpenCode/MiMo → Pi. This design targets **Claude parity**.

## Why Grok is a good fit

Grok Build exposes a lifecycle hook surface very close to Claude Code:

- Events: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionDenied`, `Stop`, `StopFailure`, `Notification`, `SubagentStart`, `SubagentStop`, `PreCompact`, `PostCompact`, `SessionEnd`
- Global hooks: `~/.grok/hooks/*.json` (always trusted)
- Resume: `grok --resume <session-id-or-title>`
- Sessions on disk: `~/.grok/sessions/<url-encoded-cwd>/<session-id>/`
- Trailing initial prompt: `grok "fix the bug"`
- Subagents with start/stop hooks and Stop `backgroundTasks`

### PermissionRequest caveat

Claude emits a `PermissionRequest` hook that Toastty maps to **Needs approval**.

Grok’s **documented** lifecycle hook table does **not** include `PermissionRequest`. It documents `PermissionDenied` (post-denial, not “waiting for user”). Approval is a real product concept via:

- UI notification events such as `approval_required` (`[ui.notifications]`)
- In-TUI permission prompts
- Related binary/UI strings (e.g. permission prompt copy)

**Working hypothesis:** no Claude-style `PermissionRequest` lifecycle hook. **Not yet proven** with a live capture. Implementation must include an early spike that logs raw hook stdin during a real permission prompt and freezes the Needs-approval mapping from that evidence (or documents the gap).

## Approaches considered

### Hook injection

| Approach | Description | Decision |
|----------|-------------|----------|
| Stable global forwarder | One-time install under `~/.grok/hooks/` (Codex-like) | Rejected for v1 (user chose per-launch ownership) |
| Session-scoped files in `~/.grok/hooks/` | Write `toastty-<session>.json` at launch; delete on cleanup | **Chosen** |
| Project-local `.grok/hooks/` | Write into repo tree | Rejected (trust, pollution, multi-session races) |
| Isolated `GROK_HOME` | Temp home with hooks + symlinked auth/sessions | Deferred; heavy and fragile |

“Per-launch” here means **ownership and lifecycle** (create for this session, clean up after), not Claude’s exact `--settings` mechanism. Grok has no documented per-process settings path for hooks.

## Architecture

### Launch prepare (`prepareGrokLaunch`)

On managed `grok` launch (Agent menu, top bar, palette, shortcut, automation, or typed shim):

1. Create temp artifacts directory `toastty-grok-launch-<sessionID>/` containing:
   - `grok-hook.sh` — telemetry forwarder (stdin JSON → `toastty session ingest-agent-event --source grok-hooks`)
   - `telemetry-failures.log` / stderr fallback (fail-open; do not block Grok)
2. Write session-scoped discovery file:
   - Path: `$GROK_HOME/hooks/toastty-<sessionID>.json` (default `GROK_HOME` = `~/.grok`)
   - Hooks point at `/bin/sh <artifacts>/grok-hook.sh` with appropriate timeouts
   - Cover at least: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop, StopFailure, Notification, SubagentStart, SubagentStop, SessionEnd (exact set may trim after spike)
3. Leave argv otherwise unchanged (no fake `--settings`).
4. Return `PreparedAgentLaunchArtifacts` tracking:
   - artifacts directory
   - hook JSON path (for cleanup; may extend the artifacts struct)
   - cleanup policy: **retain briefly after session stop** (Claude-like) so late hooks do not hit missing files, then delete artifacts + hook JSON

### Session gating

- Managed launches set base `TOASTTY_*` env (session id, panel id, socket, CLI path, cwd, repo root).
- Forwarder only ingests when `TOASTTY_SESSION_ID` is present and matches the managed session.
- Concurrent Toastty Grok sessions may each install a JSON file. Grok merges all `~/.grok/hooks/*`; other sessions’ hook entries may still be *invoked*, but each forwarder no-ops unless env matches (cheap exit 0).
- Outside Toastty, an orphaned Toastty hook file is a no-op when `TOASTTY_*` is absent.

### Typed shims

Same prepare path as UI launch before `exec` of the real `grok` binary. Built-in basename: `grok`.

### Cleanup and orphans

| Trigger | Action |
|---------|--------|
| Session stop (+ grace) | Delete artifacts dir and `toastty-<sessionID>.json` |
| App startup | Sweep `toastty-*.json` for unknown/stopped sessions past grace |
| Prepare failure | Remove partial artifacts / hook file before surfacing error |
| Hooks dir missing/unwritable | Fail prepare with a clear error; do not launch half-instrumented |

## Event mapping

**New ingest source:** `grok-hooks`.

Parser sibling to `ClaudeHookEventParser`. Prefer Grok’s **camelCase** envelope (`hookEventName`, `sessionId`, `toolName`, …) with light snake_case fallbacks where useful.

| Grok event | Toastty effect |
|------------|----------------|
| `SessionStart` | Capture native resume metadata |
| `UserPromptSubmit` | **Working** (+ optional prompt detail) |
| `PreToolUse` | **Working** (tool progress detail) |
| `PostToolUse` | Keep **Working** / optional file updates; spawn-shaped payloads may start subagent rows |
| `Stop` with `reason == end_turn` | **Ready** (+ last assistant summary when present); sync `backgroundTasks` |
| `Stop` session-end observe fire | Do not treat as turn-complete Ready by itself (filter on reason) |
| `StopFailure` | **Error** |
| `Notification` | Approval-ish types → **Needs approval**; idle/complete → **Ready** (types frozen after spike) |
| `SubagentStart` / `SubagentStop` | Background activity rows |
| `SessionEnd` | No status flip; optional cleanup signal |
| `PermissionDenied` | Ignore or non-actionable detail (not “waiting for approval”) |

### Native resume

- From `SessionStart`: native `sessionId`, cwd / workspace root.
- Persist a filesystem path for existence checks, derived if needed:
  - Prefer `$GROK_HOME/sessions/<url-encoded-cwd>/<sessionId>/` (directory) or `summary.json` inside it.
- Resume argv: `grok --resume <nativeSessionID>` (preserve profile argv prefix like Claude).
- `ManagedAgentResumeResolver.expectedNativeSessionID`: recognize `--resume <uuid>` as resume-shaped.
- If session path or cwd is missing on restore: clear stale record; cold-start.

### Subagents

- Prefer `SubagentStart` / `SubagentStop` for row lifecycle.
- Use Stop `backgroundTasks` entries with `type == subagent` to reconcile outstanding children (Claude Stop snapshot pattern).

## Data flow

```
Launch (menu / shim / agent.launch)
  → AgentLaunchInstrumentation.prepare(grok)
      write artifacts + $GROK_HOME/hooks/toastty-<session>.json
  → shell: TOASTTY_* + grok argv
  → Grok SessionStart → grok-hooks ingest
      → sessionUpdateResumeRecord (+ optional Working)
  → UserPromptSubmit / PreToolUse → Working
  → Notification? (validated) → Needs approval
  → Stop (end_turn) → Ready + backgroundTasks sync
  → process exit / sessionStop
      → grace retain → delete artifacts + hook JSON
```

### Failure behavior

| Case | Behavior |
|------|----------|
| Hook cannot reach socket/CLI | Log to launch `telemetry-failures.log`; exit 0 |
| Wrong/missing `TOASTTY_SESSION_ID` | No-op exit 0 |
| Orphan hook JSON after crash | Startup + stop sweep |
| User’s other global hooks | Additive; Toastty file is one more source |
| Late hooks after stop | Retain policy; ingest no-ops if session is gone |

## Code touch points

| Area | Change |
|------|--------|
| `Sources/Core/Sessions/AgentKind.swift` + `ManagedAgentCommandResolver` | `.grok`, built-in basenames, shim set |
| `Sources/App/Agents/AgentLaunchInstrumentation.swift` | `prepareGrokLaunch` |
| Launch artifacts model | Track hook JSON path for cleanup |
| Session stop / app lifecycle | Delete session hook file; orphan sweep |
| `Sources/CLIKit/AgentEventSource.swift` + CLI help | `grok-hooks` |
| New `GrokHookEventParser` | camelCase envelope → CLI commands |
| `AgentEventIngestor` | Route `grok-hooks` → parser |
| `ManagedAgentResumeResolver` | `grok --resume`, path validation |
| Agent shim / launch planner / catalog | Treat `grok` as built-in |
| Docs | `docs/running-agents.md`, README, privacy notes for ephemeral hooks |
| Tests | Prepare/cleanup, parser fixtures, resume argv, shim inference, orphan sweep |

## Testing and validation

### Unit / integration

1. **`prepareGrokLaunch`**
   - Writes forwarder + valid hook JSON under a temp `GROK_HOME/hooks/`
   - Cleanup removes artifacts and hook JSON
   - Prepare fails clearly if hooks dir cannot be created
2. **`GrokHookEventParser`**
   - Fixtures: SessionStart, UserPromptSubmit, PreToolUse, Stop (`end_turn` vs session-end), StopFailure, SubagentStart/Stop, Notification
   - SessionStart → resume record
   - Malformed payloads → empty command list
3. **Resolver / shim**
   - Exact + wrapper basename inference for `grok`
   - Resume argv and `expectedNativeSessionID` for `--resume`
4. **Orphan sweep**
   - Deletes stale files; leaves active sessions alone

### Live checks

| Check | Pass criteria |
|-------|----------------|
| Menu / palette launch | Managed session; Working → Ready on a short turn |
| Typed `grok` shim | Same instrumentation without menu |
| Permission prompt spike | Raw hook log; map Needs approval or document gap |
| Subagent | Child row appears/clears |
| Restore panel | `grok --resume <id>` after restart with valid record |
| Cleanup | No leftover `toastty-*.json` for stopped session after grace |
| Non-Toastty `grok` | Unaffected; orphaned Toastty hook is no-op without `TOASTTY_*` |

### Docs gate

- `running-agents.md`: “What `grok` enables”
- Privacy: ephemeral `$GROK_HOME/hooks/toastty-*.json`
- Sample `agents.toml` profile

## Risks

| Risk | Mitigation |
|------|------------|
| Concurrent Grok processes invoke every Toastty hook file | Session-gated no-op forwarders |
| Crash leaves hook JSON | Stop cleanup + startup sweep |
| Weak Needs approval signal | Spike first; ship Working/Ready/Error if needed |
| Hook schema drift | Tolerant parser; real capture fixtures |
| Privacy concern writing under `~/.grok` | Document ephemeral lifecycle |
| Odd `GROK_HOME` / missing hooks dir | Respect env; fail prepare clearly |
| Session path layout changes | Prefer dir + `summary.json`; validate before resume |

## Open questions (resolve in spike / first PR)

1. Exact `Notification` type strings (and whether permission prompts emit hooks at all).
2. Best resume path to store: session directory vs `summary.json` vs `updates.jsonl`.
3. Whether `SessionStart` includes a transcript/session path or only `sessionId` + cwd (derive path if needed).
4. Grace window length for late hooks (start from Claude retain policy).

### Spike findings (2026-08-08 live capture)

Full redacted notes: `artifacts/manual/grok-hook-spike/CATALOG.md` (gitignored dumps).

- **Wire `hookEventName` values are snake_case** (`session_start`, `user_prompt_submit`, `pre_tool_use`, `post_tool_use`, `permission_denied`, `stop`, `notification`, `subagent_start`, `subagent_stop`, `session_end`). Field names stay camelCase (`sessionId`, `transcriptPath`, …). Parser must normalize; do not require PascalCase event values.
- **Needs approval: YES.** Map `notification` + `notificationType == "permission_prompt"` (message observed: `Tool permission requested`, `level`: `info`). No Claude-style `PermissionRequest` lifecycle event.
- Also observed `notificationType == "task_complete"` for background task completion — not an approval signal.
- `permission_denied` is post-deny (deny rules), not waiting-for-user.
- `SessionStart` has `sessionId`, `cwd`, `workspaceRoot`, `source` (`new`); **no** `transcriptPath`. Later events include `transcriptPath` under `~/.grok/sessions/<urlencoded-cwd>/<sessionId>/updates.jsonl`.
- `Stop.reason`: `end_turn` (turn complete) and `shutdown` (session-end observe fire). Gate Ready on `end_turn`.
- Subagent identity: `subagentId`, `subagentType` (e.g. `general-purpose`), `description`; `SubagentStop.phase` was `gate`.

## Phased delivery

1. **Spike** — catch-all hook capture for SessionStart, Stop, and a real permission prompt.
2. **Core** — `AgentKind`, prepare/cleanup, parser (Working/Ready/Error/resume), shim, unit tests.
3. **Approval + subagents** — map from spike; background activity rows.
4. **Polish** — docs, privacy, orphan sweep, automation/`initialPrompt`, light live smoke.

## Success criteria

From menu, palette, shortcut, automation, or typing `grok` in a Toastty pane:

- A managed session appears with accurate Working / Ready (and Needs approval if the spike finds a signal).
- Restored managed panels resume with `grok --resume <id>` when metadata is valid.
- No durable Toastty installer remains in `~/.grok` beyond ephemeral per-session hook files that are cleaned up after stop.

## Next steps

1. Optional: implementation plan via writing-plans skill.
2. Implement in a worktree/branch following phased delivery.
3. Validate with unit tests + focused live Grok checks.
