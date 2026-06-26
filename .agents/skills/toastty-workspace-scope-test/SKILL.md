---
name: toastty-workspace-scope-test
description: Use when validating Toastty cooperative workspace-scoped automation, especially after changing session scope state, app-control enforcement, callerSessionID stamping, managed agent launch inheritance, CLI `toastty session scope ...` commands, or `scope_denied` behavior.
---

# Toastty Workspace Scope Test

Use this skill to run a focused live orchestration smoke for cooperative workspace scope. The smoke launches an isolated Toastty app, creates an out-of-scope workspace, scopes a session to its current workspace, verifies denial, adds the assigned workspace, verifies access, and clears scope.

## Quick Start

From the Toastty repo root:

```bash
ARCH=arm64 .agents/skills/toastty-workspace-scope-test/scripts/workspace_scope_smoke.sh
```

The script builds and launches an isolated app under `artifacts/dev-runs/<run-id>/`, then cleans up the launched app process on exit. It writes the app log and per-run artifacts under that same run directory.

## Expected Result

Successful output ends with:

```text
ok: workspace scope smoke passed
```

The smoke must prove all of these behaviors:

- `session scope set-current` stores an empty explicit scope and reports the current workspace as effective scope.
- A scoped caller is denied when reading a terminal in a pre-existing unassigned workspace, with error code `scope_denied`.
- `session scope add --workspace <id>` grants access to that assigned workspace.
- `session scope clear` returns the session to unrestricted automation.

## Failure Handling

If the smoke fails:

1. Read the script error first; it prints the failing JSON response when available.
2. Inspect the app log path printed by the script or under `artifacts/dev-runs/<run-id>/artifacts/`.
3. Keep scope semantics cooperative. A nil, empty, unknown, or stopped caller is intentionally unrestricted in v1; do not treat this smoke as a hard sandbox test.
4. If the failure involves app launch, use `.agents/skills/toastty-dev-run/SKILL.md`.
5. If the failure involves validation selection or remote wrappers, use `.agents/skills/toastty-verify/SKILL.md`.

## Useful Overrides

- `RUN_ID=<name>`: choose the artifact/run directory name.
- `DEV_RUN_ROOT=<path>`: place the isolated run somewhere specific.
- `ARCH=arm64`: build for arm64. Use x86_64 only when intentionally validating Rosetta.
- `TOASTTY_WORKSPACE_SCOPE_RESTORE_FRONT_APP=0`: skip restoring the previously frontmost app after launch.
