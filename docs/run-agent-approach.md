# Run Agent approach (high-level)

## Why this exists

Toastty needs two outcomes:

- reliable live session summaries in the workspace sidebar and feed
- durable agent sessions that can survive app restart and reattach to the right panels

A wrapper-only approach can help, but adds setup friction and weakens UI-driven targeting. This document outlines a Toastty-owned `Run Agent` model that keeps wrappers optional while preserving extensibility.

## Terms

- `panelID`: the terminal panel where the agent process is running
- `sessionID`: the Toastty session identity used for attribution and telemetry
- `agent session`: one active run bound to one panel at a time (`sessionID` -> `panelID`)
- `provider`: agent family (`codex`, `claude`, custom)
- `launch profile`: how a provider is launched (argv templates, context template, optional tmux policy, telemetry mode)

In v1, one active `sessionID` maps to one `panelID`.

## Goals

- make agent launch first-class in Toastty UI (new panel or existing panel)
- keep `toastty session ...` telemetry as the canonical contract
- support optional `tmux`-backed persistence and restore
- ship built-in providers for Codex and Claude Code
- allow user-defined providers with declarative launch profiles
- keep fallback behavior useful when rich telemetry is unavailable

## Non-goals (v1)

- mandatory wrapper-based launch for all users
- arbitrary script execution in provider config
- perfect semantic summaries without agent cooperation

## Core design

### 1) Toastty-owned launch orchestration

`Run Agent` is initiated by Toastty and routed through a shared launch service.

At launch time, Toastty resolves:

- target panel/workspace
- provider + launch profile
- launch mode (direct process or optional `tmux`)
- `sessionID` + routing metadata (`panelID`, `workspaceID`)
- optional initial context payload (for actions like "Ask Agent About This File")

Because Toastty owns launch, it can guarantee panel placement and consistent session identity before process start.

### 2) Provider model (extensibility)

Behavior is profile-driven instead of hardcoded.

Built-ins:

- Codex
- Claude Code

User extensibility:

- users can add provider launch profiles in config files
- profile fields are declarative only (argv templates, variable interpolation, policy flags, context templates)

Security constraint:

- interpolation is argument-level only (argv array), never shell-string execution
- unknown/missing template variables fail validation
- profile loading is local-user only

### 3) Telemetry contract stays stable

`toastty session ...` remains the canonical protocol surface:

- `start`
- `status`
- `update-files`
- `stop`

Producer can vary by capability:

- app-owned runtime events (always-available baseline)
- agent skill/hook events (richer data when available)
- optional adapter/wrapper events (protocol-compatible path)

Coexistence rule:

- wrappers remain supported as optional producers
- Toastty-owned `Run Agent` is the default UX path

### 4) tmux is a durability layer (optional)

`tmux` is an optional persistence feature, not a telemetry substitute.

When enabled, Toastty:

- creates/attaches a tmux session for the target panel
- runs the agent process inside tmux
- persists mapping between `panelID`, `sessionID`, and tmux target

On relaunch, Toastty can restore layout and reattach terminals to mapped tmux sessions.

## Launch flows

### Run Agent

1. user triggers `Run Agent`
2. Toastty resolves provider + target panel strategy (current/new adjacent/etc.)
3. Toastty allocates `sessionID` and records launch intent
4. Toastty launches provider directly or through tmux
5. Toastty emits baseline `session.start` and passes `TOASTTY_SESSION_ID`, `TOASTTY_PANEL_ID`, `TOASTTY_SOCKET_PATH`, `TOASTTY_CWD`, `TOASTTY_REPO_ROOT`, and `TOASTTY_AGENT` to the launched agent

### Ask Agent About This File

1. user triggers action from diff or markdown panel
2. Toastty opens/reuses an adjacent terminal panel in the same workspace
3. Toastty resolves source context (file path, selection/hunk, repo/cwd)
4. Toastty launches provider in target panel
5. Toastty injects context payload as initial message (size-limited and action-scoped)

### Feed reply / continuation

1. user comments on a feed item
2. if original session is active, Toastty routes feedback to that panel
3. if not active, Toastty starts a new run in original workspace context
4. dedup guard: rapid repeated feedback on same item/session is coalesced into one launch window

## Summary quality model

### Baseline (no agent cooperation)

Toastty still provides operational summaries from:

- process/session lifecycle state
- terminal activity heuristics
- file reconciliation against repo state

### Rich mode (with agent cooperation)

Richer summaries come from telemetry support:

- skill/hook-emitted `session.status` and `session.update_files`
- structured `kind` / `summary` / `detail` payloads for higher-fidelity feed/sidebar summaries

Current practical note:

- Codex currently has no first-class hooks, so rich telemetry for Codex relies on skill/adapter cooperation

## Operational constraints

### Credentials/auth

Toastty does not own provider credentials. Child processes inherit user auth environment/config exactly as normal CLI launches do.

### Partial/out-of-order telemetry

The UI/runtime model must tolerate:

- missing optional events
- duplicated events
- out-of-order arrival

Baseline app-owned lifecycle events ensure minimum attribution continuity when rich telemetry is absent.

### tmux failure behavior

- if tmux is not installed, launch falls back to direct mode with a visible status message
- if a stored tmux mapping is stale, Toastty marks mapping invalid and starts a fresh session
- naming collisions are avoided with deterministic names that include stable workspace/panel identity

## Why this is better than wrapper-only default

- stronger panel/workspace targeting from UI actions
- less user setup friction (no required shell alias/PATH wrapper)
- better baseline lifecycle attribution when telemetry is partial
- cleaner restore path with app-owned panel/session mapping
- still compatible with wrappers/adapters for advanced workflows

## Delivery strategy

### Phase 1

- enable `toastty session` telemetry in normal runtime
- add launch service with built-in Codex/Claude profiles
- define done-state: launch from Toastty into a chosen panel with stable `sessionID`, baseline `start/stop`, and launch-context env for follow-up telemetry

### Phase 2

- expand first-class agent actions beyond basic Run Agent (`Ask Agent About This File`, feed continuation)
- ship telemetry health/debug visibility in UI (baseline vs rich)

### Phase 3

- add optional tmux persistence + restore mapping
- add stale-mapping recovery behavior and fallback messaging

### Phase 4

- add user-defined provider profiles
- add richer structured status payload support for sidebar/feed summaries

## Open questions

- how much provider profile editing should be exposed in UI vs file-only
- minimum fields that qualify a session as "rich-summary-ready"
- how much structured status should be standardized beyond `kind` / `summary` / `detail`
