---
name: toastty-verify
description: Use this skill when selecting, running, or reporting Toastty verification after code, project, dependency, build, test, UI/runtime, menu, shortcut, automation, or agent-instruction changes. It chooses the right mix of remote smoke validation, remote xcodebuild tests, local helpers, live GUI checks, Computer Use, and the global qa subagent for deeper user-perspective QA.
---

# Toastty Verify

## Overview

Use this as the Toastty verification decision layer. Keep detailed command semantics in `docs/agents/automation.md`; use this skill to choose the right validation path, run it with the project guardrails, and report what was actually verified.

## Core Workflow

1. Inspect the diff or changed files first.
2. Identify the validation scope:
   - `working-tree`: current uncommitted changes, usually before commit.
   - `head`: the current commit only, usually after commit or for a baseline.
   - `ref --ref <rev>`: an explicit branch, tag, or commit.
3. List the user-visible behaviors and adjacent regressions that could have changed.
4. Choose 1-4 high-signal checks from the decision tree below. Prefer deterministic tests and smoke scripts before exploratory GUI work.
5. Run commands through `sv exec --` whenever the documented wrapper needs secret-backed or service-injected environment, especially remote GUI/test wrappers. Do not probe `TOASTTY_REMOTE_GUI_HOST` outside `sv exec`; the remote GUI/test environment is injected there.
6. Report the exact command family, scope, remote/local target, fallback status, result, and any artifact paths.

## Decision Tree

Use the least disruptive path that covers the risk.

### Documentation Or Instruction Changes

For docs-only or agent-instruction-only changes, do not run the full app gate by default. Validate the changed artifact directly:

- Skills: run the active runtime's `skill-creator` `quick_validate.py <skill-dir>` when available. If the script is unavailable or its Python environment is missing dependencies, at minimum parse `SKILL.md` frontmatter and `agents/openai.yaml`, then state the validator blocker in the handoff.
- Shell snippets or scripts in docs: run `bash -n` only for real shell files, not Markdown examples.
- Agent workflow changes: get the required second-opinion review if the repo instructions or active runtime require it.

If the docs change alters build, release, automation, or validation behavior, also run a representative command or dry validation path.

### Build, Project, Or Dependency Changes

After any code, project, dependency, or merge-related change, ensure the generated Xcode project is current and the app builds cleanly before handoff.

Use the full local gate when the change is broad or touches generation/build settings:

```bash
./scripts/automation/check.sh
```

Use narrower build/test commands only when the change scope is clearly narrow and the selected checks cover the risk. Set `ARCH=arm64` explicitly for agent/remote runs unless intentionally validating Rosetta; do not derive `ARCH` from `uname -m` inside `sv exec`.

### Unit Or Integration Test Changes

Agent-driven `xcodebuild test` should start with the remote wrapper:

```bash
sv exec -- scripts/remote/test.sh --scope working-tree -- ...
```

Pass `xcodebuild` flags after `--`. Prefer omitting `-destination`; if needed, use `platform=macOS,arch=arm64` unless intentionally validating Rosetta. Remote `x86_64` test destinations are blocked by default.

Use local `xcodebuild test` only when the user explicitly wants a local run, the check is local-only, or the remote wrapper is unavailable and you intentionally continue locally.

### UI, Runtime, Menu, Or Shortcut Changes

Start with remote smoke validation through the wrapper:

```bash
sv exec -- scripts/remote/validate.sh --scope working-tree --smoke-test smoke-ui
```

Supported smoke tests:

- `smoke-ui`: general UI/socket smoke.
- `workspace-tabs`: workspace tab behavior.
- `workspace-scope`: cooperative workspace-scoped automation through the live app, CLI, and socket path.
- `shortcut-hints`: visible shortcut hints or screenshot/state artifacts.
- `shortcut-trace`: real AppKit keyboard shortcut tracing.

Use `--require-remote` when the remote path itself is under validation. With `--require-remote`, a remote preflight or execution failure is a validation failure; stop and report the blocker instead of continuing locally. Otherwise, `validate.sh` may fall back to a local smoke run if remote preflight fails; report that fallback clearly.

Prefer `shortcut-trace` or `shortcut-hints` before local focus-stealing checks when the change is about keyboard shortcuts, menu-advertised hints, screenshots, or state artifacts.

Read `docs/agents/menu-performance.md` before validating or changing menu rebuilds, hidden system menu items, workspace shortcuts, or `Cmd+W` handling.

### Live GUI Or Human-Like Checks

Use `.agents/skills/toastty-dev-run/SKILL.md` when a task needs a live app instance, exact PID, runtime home, socket, logs, local Peekaboo, or foreground-capable remote validation.

Use `.agents/skills/toastty-computer-use/SKILL.md` when a GUI bug or fix needs human-like remote interaction beyond supported smoke tests, such as modal navigation, onboarding, visual/focus checks, menu flows, or ambiguous reproduction steps.

Before required local Peekaboo interaction, run:

```bash
peekaboo permissions --json
```

If Accessibility is missing, stop and ask the user to grant it before continuing locally. If the user does not want to grant local Accessibility, switch to the remote GUI path.

### Deeper QA

Invoke the global `qa` custom subagent when a meaningful user-facing change needs independent user-perspective validation that deterministic checks do not cover well. Good triggers:

- Broad UI, navigation, onboarding, menu, shortcut, or multi-window behavior changes.
- Changes with design/mockup references or visual acceptance criteria.
- Workflows with several adjacent regressions where exploratory testing is useful.
- A fix that passed narrow automation but still has UX, accessibility, focus, or state-transition risk.

Do not use QA as a substitute for relevant deterministic tests. Give the QA agent a concise packet: intended behavior, changed files or diff scope, validation already run, target commands or wrappers, fixtures, design references, known risk areas, and cleanup expectations. If the runtime cannot invoke the global `qa` subagent, say that in the handoff and rely on the deterministic checks you ran.

## Local Helpers

Use local smoke helpers only when the user explicitly wants a local run, the check is local-only, or the remote wrapper has already fallen back or failed and you are intentionally continuing locally. See `docs/agents/automation.md` for details.

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
- Which commands or skills ran, with remote/local/fallback status.
- Whether generated project/build currency was validated when applicable.
- Whether remote GUI/test environment was accessed only through `sv exec --`.
- Whether deeper QA was run, skipped as unnecessary, or unavailable in the active runtime.
- What user-visible behaviors were covered.
- What remains untested or blocked, with the reason.
- Artifact paths under `artifacts/` when produced.
