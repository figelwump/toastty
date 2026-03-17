---
name: toastty-dev-run
description: Use this skill when building, launching, or validating a live Toastty dev/debug/test app instance with runtime isolation, instance.json targeting, and Peekaboo-based UI inspection.
---

# Toastty Dev Run

Use this workflow when the task requires a real running Toastty app instance rather than unit tests or socket-only automation.

Pair this skill with the global `peekaboo` skill for UI inspection and interaction.

## When to use this

- A change needs live UI validation, menu inspection, shortcut testing, focus checks, or screenshot-based confirmation.
- The agent needs the exact PID, runtime home, logs, or socket for the instance it launched.
- The user is running Toastty from Xcode or from multiple worktrees and the agent must avoid shared local state.

Do not use this skill for release builds, pure unit-test work, or smoke/trace cases already covered by `scripts/automation/smoke-ui.sh` or `scripts/automation/shortcut-trace.sh`.

## Core rules

1. Treat the worktree as the isolation boundary for manual dev runs.
2. Before a Ghostty-backed build from a fresh worktree, run `./scripts/dev/bootstrap-worktree.sh`. This reuses installed Ghostty artifacts from another Toastty worktree when needed, then regenerates the project.
3. Prefer `TOASTTY_RUNTIME_HOME` when a task needs a one-off sandbox. Otherwise set `TOASTTY_DEV_WORKTREE_ROOT` to the worktree root and let Toastty derive a stable runtime home under `artifacts/dev-runs/`.
4. The Tuist-generated `ToasttyApp` and `ToasttyApp-Release` Xcode Run schemes already use `TOASTTY_DEV_WORKTREE_ROOT=$(SRCROOT)`. Preserve that behavior instead of hand-editing labels or run IDs.
5. Launch the app, then read `instance.json` from the runtime home before using `peekaboo`.
6. Use the PID from `instance.json` for `peekaboo ... --pid <pid>`. Do not target Toastty by app name if a PID is available.
7. Before any `peekaboo` call, confirm the PID from `instance.json` is still alive. If it is stale, relaunch instead of guessing.
8. Inspect logs and runtime state inside the same runtime home you launched. Do not inspect shared `~/.toastty` data for an isolated run.
9. Clean up only the sandbox you launched.

## Typical terminal flow

From the target worktree root:

```bash
ARCH="${ARCH:-$(uname -m)}"
DERIVED_PATH="${DERIVED_PATH:-$PWD/artifacts/dev-runs/manual/Derived}"
TOASTTY_DEV_WORKTREE_ROOT="$PWD"

./scripts/dev/bootstrap-worktree.sh
xcodebuild \
  -workspace toastty.xcworkspace \
  -scheme ToasttyApp \
  -configuration Debug \
  -destination "platform=macOS,arch=${ARCH}" \
  -derivedDataPath "$DERIVED_PATH" \
  build

TOASTTY_DEV_WORKTREE_ROOT="$TOASTTY_DEV_WORKTREE_ROOT" \
TOASTTY_DERIVED_PATH="$DERIVED_PATH" \
"$DERIVED_PATH/Build/Products/Debug/Toastty.app/Contents/MacOS/Toastty" &
APP_PID=$!
```

After launch:

```bash
INSTANCE_JSON="$(find "$PWD/artifacts/dev-runs" -path '*/runtime-home/instance.json' -print | sort | tail -n 1)"
jq . "$INSTANCE_JSON"
PID="$(jq -r '.pid' "$INSTANCE_JSON")"
kill -0 "$PID"
peekaboo menu list --pid "$PID" --json
```

## Runtime-home conventions

- Explicit sandbox: `TOASTTY_RUNTIME_HOME=/custom/path`
- Worktree-derived sandbox: `TOASTTY_DEV_WORKTREE_ROOT=/path/to/worktree`
- Worktree-derived runtime homes live under:

```text
<worktree>/artifacts/dev-runs/worktree-<basename>-<hash>/runtime-home
```

- `instance.json` records the runtime-home strategy, worktree root, PID, socket path, log path, derived path, and arguments for the launched instance.

## Validation guidance

- Use `scripts/automation/smoke-ui.sh` or `scripts/automation/shortcut-trace.sh` first when they cover the change.
- Use `peekaboo menu list --pid <pid> --json` for menu checks.
- Use `peekaboo image`, `peekaboo see`, window commands, and keyboard commands against that same PID for live UI validation.
- Tail `logs/toastty.log` under the runtime home for isolated runs.
- If the app was launched from Xcode, recover the PID and paths from `instance.json` under the worktree-derived runtime home rather than guessing from app name.
