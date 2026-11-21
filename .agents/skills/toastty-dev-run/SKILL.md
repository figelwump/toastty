---
name: toastty-dev-run
description: Use this skill when building, launching, or validating a live Toastty dev/debug/test app instance on toastty-mini with runtime isolation and instance.json targeting, or for an explicitly requested local run.
---

# Toastty Dev Run

Use this workflow when the task requires a real running Toastty app instance rather than unit tests alone.

Read `.agents/skills/toastty-verify/SKILL.md` before the first validation command. Agent-driven native builds, app launches, and GUI checks run on toastty-mini. If it is unavailable, wait or report the blocker; do not switch to the user's Mac. Use local validation only when the user explicitly requests that local run, and pair local UI interaction with the global `peekaboo` skill.

For human-like remote GUI debugging or verification beyond the supported smoke tests, use `.agents/skills/toastty-computer-use/SKILL.md`.

## When to use this

- A change needs live UI validation, menu inspection, shortcut testing, focus checks, or screenshot-based confirmation.
- The agent needs the exact PID, runtime home, logs, or socket for the instance it launched.
- The user is running Toastty from Xcode or from multiple worktrees and the agent must avoid shared local state.

Do not use this skill for release builds or pure unit-test work.

## Core rules

1. Treat the worktree as the isolation boundary for manual dev runs.
2. Before a Ghostty-backed build from a fresh worktree, run `./scripts/dev/bootstrap-worktree.sh` on the execution host. The remote wrapper handles this on toastty-mini. Run it locally only for an explicitly requested local run.
3. Prefer `TOASTTY_RUNTIME_HOME` when a task needs a one-off sandbox. Otherwise set `TOASTTY_DEV_WORKTREE_ROOT` to the worktree root and let Toastty derive a stable runtime home under `artifacts/dev-runs/`.
4. The Tuist-generated `ToasttyApp` and `ToasttyApp-Release` Xcode Run schemes already use `TOASTTY_DEV_WORKTREE_ROOT=$(SRCROOT)`. Preserve that behavior instead of hand-editing labels or run IDs.
5. Launch the app, then read `instance.json` from the runtime home before using `peekaboo`.
6. Use the PID from `instance.json` for `peekaboo ... --pid <pid>`. Do not target Toastty by app name if a PID is available. On the user's machine, only do this when the user explicitly asked for local validation.
7. Before any `peekaboo` call, confirm the PID from `instance.json` is still alive. If it is stale, relaunch instead of guessing.
8. Before any required local `peekaboo` interaction, run `peekaboo permissions --json`. If Accessibility is not granted, stop and ask the user to grant local Accessibility before continuing. Do not keep trying local `peekaboo` or improvise local screenshot/menu workarounds after a failed permissions preflight. If the user does not want to grant it locally, switch to the remote GUI path.
9. Inspect logs and runtime state inside the same runtime home you launched. Do not inspect shared `~/.toastty` data for an isolated run.
10. Runtime-isolated dev/test runs must not rewrite the user's login shell files. Shell integration installation is intentionally disabled when runtime isolation is enabled.
11. Clean up only the sandbox you launched. Use `./scripts/automation/cleanup-artifacts.sh --dry-run --category dev-runs` to preview stale run cleanup, use `--apply` only when deletion is intended, and never delete paths for a still-running PID.

## Validation planning

Before launching anything, decide what change scope you are validating:

- `working-tree`: current unstaged or staged changes in the local worktree
- `head`: the current checked-out commit as it exists now
- `ref`: an explicit commit, branch, or tag the agent wants to validate

Then derive a short validation plan from that scope:

- Inspect the diff or the relevant changed files first.
- Write down the concrete user-visible behaviors that could have changed.
- Write specific test cases that come from the changed behavior, not a generic “open the app and click around”.
- If the user already gave explicit test cases, use those instead of inventing new ones.

## Choosing the path

Use the least disruptive path that still covers the change:

- Remote smoke: use `sv exec -- scripts/remote/validate.sh --require-remote --smoke-test smoke-ui --scope working-tree` when socket automation covers the change. Select `--smoke-test shortcut-hints` for always-visible shortcut badges or hint text.
- Remote foreground: use `sv exec -- scripts/remote/validate.sh --require-remote ...`; keep `--validation-command` for foreground-capable Peekaboo checks or other custom remote validation.
- Local smoke or foreground: only when the user explicitly requests that local run. Restoring focus after a smoke run does not authorize a local app launch.
- Remote Computer Use: use `.agents/skills/toastty-computer-use/SKILL.md` when the check needs human-like interaction, judgment, or exploratory GUI reproduction beyond the smoke scripts.

## Remote Validation Flow

For remote smoke on a dedicated remote Mac:

```bash
sv exec -- scripts/remote/validate.sh \
  --require-remote \
  --smoke-test smoke-ui \
  --scope working-tree
```

For foreground-capable validation on a dedicated remote Mac:

```bash
sv exec -- scripts/remote/validate.sh \
  --require-remote \
  --scope working-tree \
  --validation-command 'peekaboo menu list --pid "$TOASTTY_PID" --json | tee "$TOASTTY_ARTIFACTS_DIR/window-menu.json"'
```

Notes:

- `--scope working-tree` validates the current uncommitted local worktree by syncing it into a disposable remote worktree.
- `--scope head` validates the current checked-out commit without uncommitted changes.
- `--scope ref --ref <rev>` validates an explicit ref.
- `--smoke-test smoke-ui|workspace-tabs|workspace-scope|shortcut-hints|shortcut-trace` is the primary supported remote path for automated validation.
- The remote artifacts come back under `artifacts/remote-gui/<run-label>/remote/`.
- Always pass `--require-remote`. If remote preflight or execution fails, wait or report the blocker without a local fallback.
- Remote smoke runs forward supported behavior overrides such as `FIXTURE`, the relevant `TOASTTY_*_RESTORE_FRONT_APP` flag, `UNREAD_FIXTURE`, and shortcut-trace input overrides like `CLICK_X`, `CLICK_Y`, and the key-code env vars. Remote-owned paths such as `DEV_RUN_ROOT`, `SOCKET_PATH`, and `TRACE_LOG_PATH` are not forwarded.
- Ghostty-required smoke tests such as `shortcut-trace` also copy available local `Dependencies/GhosttyKit*.xcframework` artifacts into the disposable remote worktree before the run. If required artifacts are missing, report that blocker instead of starting a local build.
- SSH-based remote `shortcut-trace` runs skip the `Workspace > Close Panel` menu-equivalence subcheck because `System Events` menu-item dispatch is not reliable in that context. Local trace runs still keep that assertion.
- `--validation-command` remains available for foreground-capable remote validation after Toastty launches on the remote host.
- The remote Mac must be awake, unlocked, logged into the target GUI session, and have Peekaboo permissions granted there for custom remote validation commands.

## Local terminal flow (explicit user request only)

Use this only when the user asked for local validation. From the target worktree root:

```bash
ARCH="${ARCH:-arm64}"
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

- `instance.json` records `runtimeHomeStrategy`, `worktreeRootPath`, `pid`, `socketPath`, `logFilePath`, optional `derivedPath`, and `arguments` for the launched instance.

## Validation guidance

- Use `sv exec -- scripts/remote/validate.sh --require-remote --smoke-test <test> ...` for smoke, shortcut-badge, and real-shortcut checks.
- Use remote `--validation-command` or the Computer Use skill for menu, screenshot, window, and keyboard checks. Target the same PID from `instance.json`.
- The local smoke and Peekaboo equivalents require an explicit user request for that local run.
- Tail `logs/toastty.log` under the runtime home for isolated runs.
- If the app was launched from Xcode, recover the PID and paths from `instance.json` under the worktree-derived runtime home rather than guessing from app name.
