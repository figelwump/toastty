---
name: toastty-verify
description: Read before the first Toastty validation command after code, project, dependency, build, test, UI/runtime, menu, shortcut, automation, or agent-instruction changes. Choose remote native builds, tests, smoke, and Computer Use checks, with cheap source checks allowed locally.
---

# Toastty Verify

## Overview

Use this as the Toastty verification decision layer. Keep detailed command semantics in `docs/agents/automation.md`; use this skill to choose the right validation path, run it with the project guardrails, and report what was actually verified.

Read this skill before the first validation command. Agent-driven native builds, macOS test suites, iOS Simulator runs, and GUI checks must run on toastty-mini. Cheap source checks and read-only inspection may run locally. If the mini is unavailable, wait or report the blocked checks; do not fall back to the user's Mac. An explicit user request for a local run permits that run only.

## Core Workflow

1. Inspect the diff or changed files first.
2. Identify the validation scope:
   - `working-tree`: current uncommitted changes, usually before commit.
   - `head`: the current commit only, usually after commit or for a baseline.
   - `ref --ref <rev>`: an explicit branch, tag, or commit.
3. List the scenarios a user could hit for the changed behavior, not only the main path: state combinations, relaunch and restore, interruption and cancellation, failure and retry paths, concurrent or repeated actions, boundary inputs, and interaction with adjacent features such as other panels, sessions, or the iOS client. Add any "Scenarios to verify" from a second-opinion review.
4. Choose checks from the decision tree below that together cover each scenario with a real impact. Prefer deterministic tests and smoke scripts; use live GUI checks or Computer Use for scenarios only the real surface shows. When a scenario fails, fix the root cause instead of adding guards.
5. Run commands through `sv exec --` whenever the documented wrapper needs secret-backed or service-injected environment, especially remote GUI/test wrappers. Do not probe `TOASTTY_REMOTE_GUI_HOST` outside `sv exec`; the remote GUI/test environment is injected there.
6. Report the exact command family, scope, execution target, any explicit local authorization, result, and artifact paths. List the scenarios and say which checks covered them, and which were not covered and why.

## CI Coverage

PR CI runs selected Linux script and web-panel checks. It does not build or test
native apps, and merged commits do not trigger another CI run. Continue to select
native build, test, and runtime checks below for the changed behavior. A green
`CI gate` on a PR does not replace this verification.

Full hosted native validation is available by manually dispatching `Toastty CI`.
Before TestFlight, that full run must pass on the exact `main` release commit;
follow `docs/ios-release-ci.md`. It retains macOS checks and both iOS
configurations, including full Debug UI and performance budgets.

## Decision Tree

Use the least disruptive path that covers the risk.

### Documentation Or Instruction Changes

For docs-only or agent-instruction-only changes, do not run the full app gate by default. Validate the changed artifact directly:

- Skills: run the active runtime's `skill-creator` `quick_validate.py <skill-dir>` when available. If the script is unavailable or its Python environment is missing dependencies, at minimum parse `SKILL.md` frontmatter, then state the validator blocker in the handoff.
- Shell snippets or scripts in docs: run `bash -n` only for real shell files, not Markdown examples.
- Agent workflow changes: follow the global Review Gate.

If the docs change alters build, release, automation, or validation behavior, also run a representative command or dry validation path.

### Build, Project, Or Dependency Changes

After any code, project, dependency, or merge-related change, ensure the generated Xcode project is current and the app builds cleanly on toastty-mini before handoff. The remote wrapper bootstraps its disposable worktree.

Use the remote macOS suite when the change is broad or touches generation/build settings:

```bash
sv exec -- scripts/remote/test.sh --scope working-tree
```

Use narrower remote build/test checks only when the change scope is clearly narrow and the selected checks cover the risk. Set `ARCH=arm64` explicitly for agent/remote runs unless intentionally validating Rosetta; do not derive `ARCH` from `uname -m` inside `sv exec`. The full local gate, `./scripts/automation/check.sh`, is only for an explicit user request for that local run.

For a build without tests, use `sv exec -- scripts/remote/test.sh --build-only --scope working-tree`.
The wrapper gives that build a compute slot. Inspect `sv exec -- scripts/remote/status.sh`
for active work and waits; do not create another polling script.

### Unit Or Integration Test Changes

Run agent-driven `xcodebuild test` through the remote wrapper:

```bash
sv exec -- scripts/remote/test.sh --scope working-tree -- ...
```

Pass `xcodebuild` flags after `--`. macOS suites own the shared desktop by default. Use `--resource compute` only for selected tests verified to avoid shared GUI, focus, clipboard and input state. Batch the required suites for one source revision into one invocation when practical. Prefer omitting `-destination`; if needed, use `platform=macOS,arch=arm64` unless intentionally validating Rosetta. Remote `x86_64` test destinations are blocked by default.

Use local `xcodebuild test` only when the user explicitly requests that local run. A local-only check or unavailable remote wrapper is a blocker, not permission to run locally.

### Native iOS Surface

Treat `ios/` as a separate Tuist graph from the root macOS project. Choose the tier that matches the change:

- Baseline/dispatcher: cheap dispatcher source checks may run locally if they do not build a native app or start a simulator.
- Agent-driven simulator: use `sv exec -- scripts/remote/test.sh --platform ios --scope working-tree`. The remote wrapper generates the iOS graph before `xcodebuild`, resolves a compatible simulator when no destination was supplied, and copies the log, result JSON, and xcresult back under `artifacts/remote-tests/`.
- User surface: use remote simulator screenshots or a live paired phone check. State explicitly whether evidence came from fixtures, an iOS Simulator, or a physical device.

Changes to `Sources/RemoteProtocol/` or its fixtures must validate both graphs: root macOS generation/build/tests and the native iOS test tier. Do not treat a green iOS run as proof that the macOS host still compiles the shared contract.

Both graphs also compile `Sources/ConversationUI/`, the SwiftUI conversation transcript views. A change there must build on both platforms and pass the native iOS test tier, which covers the views on the iPhone. On macOS, `ToasttyAppTests/ConversationUIRenderTests` hosts the views and keeps a PNG on the test result.

Do not boot or interact with a local iOS Simulator unless the user explicitly requests that local run. Pass `--platform ios`; merely supplying an iOS workspace without that mode is intentionally insufficient because the wrapper must select the correct bootstrap path.

### UI, Runtime, Menu, Or Shortcut Changes

For remote-access input changes (send, queue, steer, stop, or send confirmation),
run the live check against each changed provider's real CLI. Synthetic feeds
do not verify provider transcript formats. See **Remote input control** in
`docs/agents/automation.md` for commands and prerequisites.

Start with remote smoke validation through the wrapper:

```bash
sv exec -- scripts/remote/validate.sh --require-remote --scope working-tree --smoke-test smoke-ui
```

Supported smoke tests:

- `smoke-ui`: general UI/socket smoke.
- `workspace-tabs`: workspace tab behavior.
- `workspace-scope`: cooperative workspace-scoped automation through the live app, CLI, and socket path.
- `shortcut-hints`: visible shortcut hints or screenshot/state artifacts.
- `shortcut-trace`: real AppKit keyboard shortcut tracing.

Always pass `--require-remote` for agent-driven validation. A remote preflight or execution failure is a validation failure; wait or report the blocker instead of continuing locally.

Use remote `shortcut-trace` or `shortcut-hints` when the change is about keyboard shortcuts, menu-advertised hints, screenshots, or state artifacts.

Read `docs/agents/menu-performance.md` before validating or changing menu rebuilds, hidden system menu items, workspace shortcuts, or `Cmd+W` handling.

### Live GUI Or Human-Like Checks

Use `.agents/skills/toastty-dev-run/SKILL.md` when a task needs a live app instance, exact PID, runtime home, socket, logs, local Peekaboo, or foreground-capable remote validation.

Use `.agents/skills/toastty-computer-use/SKILL.md` when a GUI bug or fix needs human-like remote interaction beyond supported smoke tests, such as modal navigation, onboarding, visual/focus checks, menu flows, or ambiguous reproduction steps.

Only after an explicit user request for local validation, and before required local Peekaboo interaction, run:

```bash
peekaboo permissions --json
```

If Accessibility is missing, stop and ask the user to grant it before continuing locally. If the user does not want to grant local Accessibility, switch to the remote GUI path.

### Deeper User-Perspective Checks

Run a deeper user-perspective check yourself when a meaningful user-facing change needs validation that deterministic checks do not cover well. Use the change as a user would, through the live GUI and Computer Use paths above. Good triggers:

- Broad UI, navigation, onboarding, menu, shortcut, or multi-window behavior changes.
- Changes with design/mockup references or visual acceptance criteria.
- Workflows with several adjacent regressions where exploratory testing is useful.
- A fix that passed narrow automation but still has UX, accessibility, focus, or state-transition risk.

Do not use this check as a substitute for relevant deterministic tests.

## Local Helpers

Use local smoke helpers only when the user explicitly requests that local run. A local-only check or remote failure is a blocker, not permission to run locally. See `docs/agents/automation.md` for details.

Common helpers:

- `scripts/automation/smoke-ui.sh`
- `scripts/automation/workspace-tabs-smoke.sh`
- `scripts/automation/workspace-scope-smoke.sh`
- `scripts/automation/shortcut-hints-smoke.sh`
- `scripts/automation/shortcut-trace.sh`
- `scripts/automation/smoke-cli-live-control.sh`

For any local dev/debug/test app run, use runtime isolation and target the exact `instance.json`. Never drive a generic Toastty app name when a PID or bundle path is available.

## Handoff Checklist

State:

- What scope was validated: `working-tree`, `head`, or `ref`.
- Which commands or skills ran, with execution targets and any explicit local authorization.
- Whether generated project/build currency was validated when applicable.
- Whether remote GUI/test environment was accessed only through `sv exec --`.
- Whether a deeper user-perspective check was run, skipped as unnecessary, or blocked, with the reason.
- What user-visible behaviors were covered.
- What remains untested or blocked, with the reason.
- Artifact paths under `artifacts/` when produced.
