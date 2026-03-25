# Agent Command Shims Plan

Date: 2026-03-25

## Goal

Make typed `codex` and `claude` launches inside Toastty participate in the same session lifecycle as the existing explicit Agent menu launch path:

1. create a `SessionRecord` immediately
2. inject `TOASTTY_SESSION_ID` into the child process environment
3. preserve first-party Codex/Claude instrumentation and status updates
4. stop the session automatically when the process exits

The design should not require users to adopt the Agent menu, toolbar, or shortcut workflow for the common case of typing `codex` or `claude` directly.

## Non-Goals

- Do not add generic auto-detection for arbitrary `agents.toml` profiles in v1.
- Do not add shell-hook parsing as the primary mechanism.
- Do not rely on PTY output scanning or process polling as the primary launch path.
- Do not change the existing explicit Agent menu workflow beyond refactoring it to reuse shared launch preparation.

## Current State

Today the explicit launch path in `AgentLaunchService` does all of the important work in one place:

- resolves the target panel and cwd
- creates the session and initial idle status
- prepares Codex or Claude launch instrumentation
- renders a shell command with `TOASTTY_*` env assignments inline
- sends the command into the terminal
- registers the Codex log watcher and managed artifacts

This is reliable for menu/shortcut launches, but it is tightly coupled to "Toastty types the command for the user".

Separately:

- `AgentLaunchInstrumentation` already knows how to rewrite `argv` and env for first-party `codex` and `claude`
- `AutomationSocketServer` already handles `session.start`, `session.status`, `session.update_files`, and `session.stop`
- normal terminal PTYs do not currently receive the full `TOASTTY_*` launch context by default; `TOASTTY_PANEL_ID` is injected only for terminal-profile startup flows

That means a thin typed-launch wrapper that only calls `toastty session start` is insufficient. It would create the sidebar session, but it would not reuse the existing Codex watcher setup or Claude/Codex launch rewriting.

## Recommended Architecture

### 1. Introduce a Shared Managed Launch Planner

Extract the reusable "prepare a managed agent launch" logic out of the current explicit launch path into a dedicated app-side service.

Proposed shape:

```swift
struct ManagedAgentLaunchRequest: Sendable {
    let agent: AgentKind
    let panelID: UUID
    let argv: [String]
    let cwd: String?
}

struct ManagedAgentLaunchPlan: Codable, Equatable, Sendable {
    let sessionID: String
    let agent: AgentKind
    let argv: [String]
    let environment: [String: String]
}

@MainActor
protocol ManagedAgentLaunchPlanning: AnyObject {
    func prepareManagedLaunch(_ request: ManagedAgentLaunchRequest) throws -> ManagedAgentLaunchPlan
}
```

Responsibilities:

- resolve live panel context for session attachment
- infer `repoRoot`
- allocate `sessionID`
- call `AgentLaunchInstrumentation.prepare(...)`
- create the session and initial idle status
- register managed artifacts and start the Codex watcher before returning
- return the final child `argv` plus the merged launch environment

Important distinction:

- menu launches still need the current "is this panel interactive and safe to launch into?" validation before typing a command into the shell
- typed launches do not need prompt/busy validation, because the user already launched the command in that panel
- typed launches only need attachment validation: can Toastty still resolve `TOASTTY_PANEL_ID` to a live terminal panel so the session can be attached to the correct window/workspace?

If typed-launch attachment validation fails, the command should still run untracked rather than being blocked.

Important simplification:

- keep watcher setup in the app, not in the shim or CLI
- keep `AgentLaunchInstrumentation` as the source of truth for Codex/Claude launch rewriting

### 2. Reuse the Planner From the Existing GUI Launch Path

Refactor `AgentLaunchService.launch(...)` to use the shared planner instead of creating sessions and artifacts directly.

After refactor, the explicit path should become:

1. resolve profile and target panel
2. call the shared planner with the profile `argv`
3. render the returned env + `argv` into a shell command
4. add an explicit shim-bypass env assignment for menu launches only, for example `TOASTTY_MANAGED_AGENT_SHIM_BYPASS=1`
5. send it to the panel

This preserves current behavior while removing the duplication risk between menu-launch and typed-launch.

The shim-bypass marker is required once the shim directory is on `PATH`. Without it, a menu launch that types `codex ...` into the shell would re-enter the shim and create a duplicate second session.

### 3. Add a Private Shim-Only CLI / Socket Entry Point

Add a new private launch-preparation request that the bundled shims can call. This should return JSON because the shim needs structured `argv` and env data.

Candidate CLI shape:

```bash
"$TOASTTY_CLI_PATH" agent prepare-managed-launch \
  --agent codex \
  --cwd "$PWD" \
  --arg codex \
  --arg --model \
  --arg gpt-5.4
```

Candidate JSON response:

```json
{
  "sessionID": "sess-123",
  "agent": "codex",
  "argv": [
    "codex",
    "-c",
    "notify=[\"/bin/sh\",\"/tmp/toastty-codex-launch-sess-123/codex-notify.sh\"]",
    "--model",
    "gpt-5.4"
  ],
  "environment": {
    "TOASTTY_SESSION_ID": "sess-123",
    "TOASTTY_PANEL_ID": "....",
    "TOASTTY_SOCKET_PATH": "/tmp/....sock",
    "TOASTTY_CLI_PATH": "/Applications/Toastty.app/Contents/Helpers/toastty",
    "TOASTTY_CWD": "/Users/vishal/GiantThings/repos/toastty",
    "TOASTTY_REPO_ROOT": "/Users/vishal/GiantThings/repos/toastty",
    "CODEX_TUI_RECORD_SESSION": "1",
    "CODEX_TUI_SESSION_LOG_PATH": "/tmp/toastty-codex-launch-sess-123/codex-session.jsonl"
  }
}
```

Implementation note:

- model this as a request/response command in the automation socket, not as a fire-and-forget event
- treat it as an internal CLI surface used by Toastty-owned shims, not a public stable integration contract in v1
- this is additive to the existing request/response socket protocol, not a new transport design

### 4. Add a Bundled Generic Shim Binary

Add one new command-line tool target, for example `toastty-agent-shim`, that is symlinked as:

- `codex`
- `claude`

The shim should infer the desired `AgentKind` from `argv[0]`.

Shim algorithm:

1. read `argv[0]` and remaining args
2. if `TOASTTY_MANAGED_AGENT_SHIM_BYPASS=1` is present, pass through unchanged
3. if `TOASTTY_PANEL_ID` or `TOASTTY_CLI_PATH` is missing, pass through to the real binary unchanged
4. if `TOASTTY_SESSION_ID` is already present, pass through unchanged
5. resolve the real binary path by searching `PATH` after removing the shim directory from consideration
6. if real-binary resolution fails, print a concise error and exit `127`
7. call `toastty agent prepare-managed-launch ...`
8. if prepare-managed-launch fails before returning a plan, log the failure back to Toastty if possible and pass through untracked without terminal noise rather than hanging
9. spawn the real binary with the returned env + `argv`
10. wait for exit
11. call `toastty session stop --session <id> --reason process_exit`
12. exit with the child termination status

The pass-through-on-existing-`TOASTTY_SESSION_ID` rule keeps v1 small and avoids nested top-level session clobbering when one managed agent launches another. This means nested managed agent launches are intentionally not tracked as separate top-level sessions in v1.

TTY / signal constraints:

- the shim must be transparent to stdin/stdout/stderr during normal operation
- the shim must not read from stdin, change terminal modes, or emit progress text
- the child process must inherit the PTY file descriptors directly
- signal handling must preserve normal TUI behavior; test `SIGINT` and `SIGTSTP` explicitly
- if the shim receives termination while waiting on the child, the v1 fallback is existing session cleanup heuristics rather than a second watchdog layer

### 5. Add a Managed Shim Directory to the PTY Launch Environment

Add a runtime-aware shim directory that Toastty prepends to `PATH` for every terminal PTY it launches.

Recommended location:

- user-home runs: `~/.toastty/bin`
- runtime-isolated runs: `<runtime-home>/bin`

Add a `ToasttyRuntimePaths` accessor for this directory so runtime isolation remains the source of truth.

Add an app-side `AgentCommandShimInstaller` that:

- resolves the bundled `toastty-agent-shim` helper path
- creates the shim directory
- creates or refreshes symlinks for `codex` and `claude`, pointing directly into the current app bundle helper
- is safe to run repeatedly

Important simplification:

- do not touch the user’s shell init files
- do not make this a global system PATH change
- inject the shim directory only into Toastty-owned PTYs
- enable the shim `PATH` prepend only once the shim binary and prepare-managed-launch path are both live; do not land the `PATH` change by itself

Freshness rule:

- do not copy shim binaries into the shim directory
- symlinks should always target the currently installed app bundle helper so app updates refresh behavior automatically

### 6. Add a Base PTY Launch Context For All Terminal Panels

Today `TerminalProfileLaunchResolver` injects `TOASTTY_PANEL_ID` only for profiled startup commands. The shim design needs a base environment for every panel.

Introduce a small builder that merges:

- universal PTY env for every terminal panel
- existing profile-specific launch env and startup input

Base env should include:

- `TOASTTY_PANEL_ID`
- `TOASTTY_SOCKET_PATH`
- `TOASTTY_CLI_PATH`
- prepended shim `PATH`

Keep these out of the current inline `ShellCommandRenderer` path only after the typed-launch flow is working. The existing inline env injection for explicit agent launch can remain in place initially; it is still the safest way to ensure the spawned agent gets the correct session-specific values.

Audit every PTY creation path before landing this. The universal builder must cover:

- fresh panels
- split panels
- restored panels
- any alternate surface creation flows that bypass terminal-profile startup

### 7. Preserve Explicit Non-Goals For v1

Accept these v1 gaps explicitly:

- typed `/full/path/to/codex` bypasses the shim
- user wrappers that hardcode the real binary path bypass the shim
- arbitrary `agents.toml` profiles are not auto-shimmed
- `cdx()`-style shell functions work only when they eventually call bare `codex` or `command codex`
- nested managed agent launches are pass-through in v1, not separate tracked child sessions

These are acceptable trade-offs for a first-party-only command-name design.

## Runtime Constraints

### Latency Budget

Typed `codex` / `claude` launches should stay under an added Toastty overhead budget of roughly 200 ms on a cold shim start.

Measure during implementation:

- shim process startup
- CLI/socket round-trip
- app-side launch planning
- total time to child exec

If the measured overhead is consistently above budget, revisit whether the shim implementation should remain Swift or move to a lighter helper.

### Failure UX

Different failure classes should surface differently:

- real binary missing: print to stderr and exit `127`
- Toastty tracking setup failed but the agent can still run: pass through silently in the terminal, emit an app log entry, and surface a non-modal Toastty warning

Preferred v1 UI for tracking-attach failures:

- a panel-scoped warning chip or equivalent non-modal panel chrome state
- optional sidebar warning indicator for the affected panel/workspace
- no alert dialog for typed launches
- no fake managed session entry if tracking was never attached

## File / Module Plan

### New or Extracted App-Side Code

- `Sources/App/Agents/ManagedAgentLaunchPlanner.swift`
  - shared app-side launch-preparation service
- `Sources/App/Runtime/AgentCommandShimInstaller.swift`
  - runtime-home aware shim directory manager
- `Sources/App/Terminal/TerminalLaunchEnvironmentBuilder.swift`
  - merges universal PTY env with existing profile-specific startup config

### Existing App Files To Change

- `Sources/App/Agents/AgentLaunchService.swift`
  - call the shared planner and stop owning watcher/session setup directly
  - keep menu-launch prompt/busy validation separate from typed-launch attachment validation
- `Sources/App/Automation/AutomationSocketServer.swift`
  - add request handling for managed launch preparation
- `Sources/App/Sessions/...`
  - add a lightweight path for panel-scoped tracking-attach warnings if the existing session UI does not already have a suitable surface
- `Sources/App/Terminal/TerminalRuntimeRegistry.swift`
  - use the base PTY launch environment for every panel
- `Sources/App/TerminalProfiles/TerminalProfileLaunchResolver.swift`
  - stop being the sole owner of `TOASTTY_PANEL_ID` injection
- `Sources/App/ToasttyApp.swift`
  - wire in the shim installer and planner dependencies

### Existing Core / CLI Files To Change

- `Sources/Core/Runtime/ToasttyRuntimePaths.swift`
  - add `agentShimDirectoryURL`
- `Sources/CLIKit/ToasttyCLI.swift`
  - add a private `agent prepare-managed-launch` JSON-returning command
- `Sources/CLIKit/...`
  - add Codable request / response types for the new command
- `Sources/Core/Sessions/ToasttyLaunchContextEnvironment.swift`
  - add a shim-bypass env key constant

### New Helper Target

- `Sources/AgentShim/main.swift`
  - generic shim entry point
- `Project.swift`
  - add the new command-line tool target and ensure it is bundled alongside `toastty`

### Docs To Update After Implementation

- `README.md`
- `docs/running-agents.md`
- `docs/cli-reference.md`
- `docs/privacy-and-local-data.md`
- optionally `docs/shell-integration.md` to explain why shell init changes are not required for first-party typed launches

## Suggested Execution Order

1. Add runtime-path support for a managed shim directory and an app-side shim installer.
2. Extract the shared managed launch planner out of `AgentLaunchService`.
3. Add the private socket request + CLI wrapper for "prepare managed launch".
4. Refactor `AgentLaunchService` to use the planner and add the menu-launch shim-bypass env marker.
5. Add the generic shim binary and symlink installation for `codex` / `claude`.
6. Add the universal PTY launch environment, including shim `PATH`, only after the prepare path and shim binary are both working.
7. Add non-modal tracking-failure UI and logging for typed-launch attach failures.
8. Update docs after code and validation are complete.

This order keeps the refactor incremental and lets the existing explicit launch path stay working throughout.

## Testing Plan

### Unit Tests

- `AgentLaunchServiceTests`
  - explicit launch still renders the same env / `argv` after refactor
  - explicit menu launch produces exactly one session record when the shim directory is present on `PATH`
- new planner tests
  - session creation
  - typed-launch attachment validation behavior when the panel is stale or missing
  - repo-root inference
  - managed artifact registration
  - Codex watcher startup
  - duplicate-session prevention / deterministic behavior when a panel already has an active managed session
- `AutomationSocketServerTests`
  - prepare-managed-launch request returns structured JSON plan
  - invalid panel / invalid agent / missing args are rejected
- `ToasttyCLITests`
  - new `agent prepare-managed-launch` parsing and JSON output
- `TerminalProfileLaunchResolverTests`
  - profile startup env is merged on top of universal PTY env
- `ToasttyRuntimePathsTests` or equivalent
  - shim directory path resolves correctly in user-home and runtime-isolated modes
- new shim tests
  - pass-through when panel context is missing
  - pass-through when the menu-launch shim-bypass env key is present
  - pass-through when `TOASTTY_SESSION_ID` is already set
  - real-binary resolution skips the shim directory
  - dead or unreachable app/socket does not hang the shim
  - `SIGINT` / `SIGTSTP` behavior stays compatible with TUI expectations
  - child receives returned env and `argv`
  - exit code propagation
  - abnormal child termination still leads to deterministic stop / cleanup behavior

### Integration Tests

Use fake `codex` and `claude` executables in temp directories rather than relying on real installs.

Test fixture behavior:

- fake real binary writes its received env and args to a temp file
- shim dir is prepended ahead of the fake real binary dir
- shim is invoked as `codex`
- test asserts:
  - Toastty session is created
  - the fake real binary saw `TOASTTY_SESSION_ID`
  - the fake real binary saw the Codex recording env vars
  - the rewritten `-c notify=[...]` args were present
  - the session was stopped on exit

Repeat the same end-to-end check for `claude` so the `argv[0]`-based branching is exercised for both first-party names.

Add a Claude-specific integration case where the typed launch already includes `--settings` and verify the planned `argv` merges Toastty hooks instead of clobbering user settings.

### Validation

- `tuist generate`
- targeted unit tests for the new planner, shim, CLI, and terminal launch env
- full `./scripts/automation/check.sh`
- explicit latency measurement against the typed-launch budget
- manual local validation with a fake `codex` binary before trying a real Codex install
- optional real Codex manual run inside an isolated dev runtime after the fake-binary path is green

## Open Questions / Decisions

### Request Naming

Use a clearly internal name for the typed-launch prepare endpoint. Avoid making this look like the public long-term integration surface.

### Stop Timing

The shim should stop the session on child exit, but the existing prompt-based stop heuristics should remain as a backstop for crash or forced-termination paths.

If the shim is killed after spawning the child, v1 will rely on the existing prompt-based panel stop heuristics as the backstop rather than adding a second watchdog layer immediately.

### Future Scope

If this lands cleanly, a later phase can add explicit opt-in custom shims for non-first-party profiles. That should be a separate design, because it reopens profile-to-command ambiguity and config synchronization complexity.

## Self-Review

Potential over-engineering risks and the corresponding simplifications:

- Do not build a generic profile-driven shim registry in v1.
- Do not add shell-hook parsing in v1.
- Do not move watcher logic into the shim or CLI.
- Do not replace the explicit inline env injection path for Agent menu launches immediately; reuse the planner first, then collapse duplication later if it is still worthwhile.

The narrowest version that still solves the problem is:

- one shared planner
- one generic shim target
- two symlinks (`codex`, `claude`)
- one universal PTY env builder
