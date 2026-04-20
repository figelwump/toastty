---
name: toastty-dev-run
description: Use this skill when building, launching, or validating a live Toastty dev/debug/test app instance with runtime isolation, instance.json targeting, local smoke automation, and local or remote GUI validation.
---

# Toastty Dev Run

Use this workflow when the task requires a real running Toastty app instance rather than unit tests alone.

Pair this skill with the global `peekaboo` skill for local UI inspection and interaction. When foreground validation would steal focus from the current desktop, prefer the repo-local remote GUI wrapper instead of running Peekaboo locally.

## When to use this

- A change needs live UI validation, menu inspection, shortcut testing, focus checks, or screenshot-based confirmation.
- The agent needs the exact PID, runtime home, logs, or socket for the instance it launched.
- The user is running Toastty from Xcode or from multiple worktrees and the agent must avoid shared local state.

Do not use this skill for release builds or pure unit-test work.

## Core rules

1. Treat the worktree as the isolation boundary for manual dev runs.
2. Before a Ghostty-backed build from a fresh worktree, run `./scripts/dev/bootstrap-worktree.sh`. This reuses installed Ghostty artifacts from another Toastty worktree when needed, then regenerates the project.
3. Prefer `TOASTTY_RUNTIME_HOME` when a task needs a one-off sandbox. Otherwise set `TOASTTY_DEV_WORKTREE_ROOT` to the worktree root and let Toastty derive a stable runtime home under `artifacts/dev-runs/`.
4. The Tuist-generated `ToasttyApp` and `ToasttyApp-Release` Xcode Run schemes already use `TOASTTY_DEV_WORKTREE_ROOT=$(SRCROOT)`. Preserve that behavior instead of hand-editing labels or run IDs.
5. Launch the app, then read `instance.json` from the runtime home before using `peekaboo`.
6. Use the PID from `instance.json` for `peekaboo ... --pid <pid>`. Do not target Toastty by app name if a PID is available.
7. Before any `peekaboo` call, confirm the PID from `instance.json` is still alive. If it is stale, relaunch instead of guessing.
8. Before any required local `peekaboo` interaction, run `peekaboo permissions --json`. If Accessibility is not granted, stop and ask the user to grant local Accessibility before continuing. Do not keep trying local `peekaboo` or improvise local screenshot/menu workarounds after a failed permissions preflight. If the user does not want to grant it locally, switch to the remote GUI path.
9. Inspect logs and runtime state inside the same runtime home you launched. Do not inspect shared `~/.toastty` data for an isolated run.
10. Clean up only the sandbox you launched.

## Validation planning

Before launching anything, decide what change scope you are validating:

- `working-tree`: current unstaged or staged changes in the local worktree
- `head`: the current checked-out commit as it exists now
- `ref`: an explicit commit, branch, or tag the agent wants to validate

Then derive a short validation plan from that scope:

- Inspect the diff or the relevant changed files first.
- Write down the concrete user-visible behaviors that could have changed.
- Prefer 2-5 high-signal test cases over a generic “open the app and click around”.
- If the user already gave explicit test cases, use those instead of inventing new ones.

## Choosing the path

Use the least disruptive path that still covers the change:

- Local smoke: use `scripts/automation/smoke-ui.sh` first when socket automation covers the change. This is the default local path because it restores the previously frontmost app after Toastty reaches automation readiness.
- Shortcut-hints smoke: use `scripts/automation/shortcut-hints-smoke.sh` when the change only needs a visual artifact for always-visible shortcut badges or hint text.
- Local foreground: use a local isolated dev run plus Peekaboo only when you need direct inspection but the focus impact is acceptable.
- Remote validation: use `scripts/remote/validate.sh` when the validation should run on the dedicated remote Mac. Prefer `--smoke-test` for remote smoke runs; keep `--validation-command` for foreground-capable Peekaboo checks or other custom remote validation.

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

## Remote Validation Flow

For remote smoke on a dedicated remote Mac:

```bash
TOASTTY_REMOTE_GUI_HOST=mac-mini.local \
./scripts/remote/validate.sh \
  --smoke-test smoke-ui \
  --scope working-tree
```

For foreground-capable validation on a dedicated remote Mac:

```bash
TOASTTY_REMOTE_GUI_HOST=mac-mini.local \
./scripts/remote/validate.sh \
  --scope working-tree \
  --validation-command 'peekaboo menu list --pid "$TOASTTY_PID" --json | tee "$TOASTTY_ARTIFACTS_DIR/window-menu.json"'
```

Notes:

- `--scope working-tree` validates the current uncommitted local worktree by syncing it into a disposable remote worktree.
- `--scope head` validates the current checked-out commit without uncommitted changes.
- `--scope ref --ref <rev>` validates an explicit ref.
- `--smoke-test smoke-ui|workspace-tabs|shortcut-hints|shortcut-trace` is the primary supported remote path for automated validation.
- The remote artifacts come back under `artifacts/remote-gui/<run-label>/remote/`.
- Smoke runs fall back to a local smoke run if remote preflight fails; pass `--require-remote` when the remote path itself matters.
- For `--scope head` or `--scope ref`, that local fallback uses a temporary local worktree at the requested ref so the validated snapshot stays aligned with the requested scope.
- Remote smoke runs forward supported behavior overrides such as `FIXTURE`, the relevant `TOASTTY_*_RESTORE_FRONT_APP` flag, `UNREAD_FIXTURE`, and shortcut-trace input overrides like `CLICK_X`, `CLICK_Y`, and the key-code env vars. Remote-owned paths such as `DEV_RUN_ROOT`, `SOCKET_PATH`, and `TRACE_LOG_PATH` are not forwarded.
- Ghostty-required smoke tests such as `shortcut-trace` also copy the local `Dependencies/GhosttyKit*.xcframework` artifacts into the disposable remote worktree before the run. Bootstrap the local worktree first so those artifacts exist.
- SSH-based remote `shortcut-trace` runs skip the `Workspace > Close Panel` menu-equivalence subcheck because `System Events` menu-item dispatch is not reliable in that context. Local trace runs still keep that assertion.
- `--validation-command` remains available for foreground-capable remote validation after Toastty launches on the remote host.
- The remote Mac must be awake, unlocked, logged into the target GUI session, and have Peekaboo permissions granted there for custom remote validation commands.

## Runtime-home conventions

- Explicit sandbox: `TOASTTY_RUNTIME_HOME=/custom/path`
- Worktree-derived sandbox: `TOASTTY_DEV_WORKTREE_ROOT=/path/to/worktree`
- Worktree-derived runtime homes live under:

```text
<worktree>/artifacts/dev-runs/worktree-<basename>-<hash>/runtime-home
```

- `instance.json` records the runtime-home strategy, worktree root, PID, socket path, log path, derived path, and arguments for the launched instance.

## Validation guidance

- Use `scripts/automation/smoke-ui.sh` first when it covers the change.
- Use `scripts/automation/shortcut-hints-smoke.sh` for visible shortcut-badge validation before considering `peekaboo`.
- Use `scripts/remote/validate.sh --smoke-test shortcut-trace ...` when you need real-shortcut tracing without stealing focus locally.
- Use `scripts/remote/validate.sh` for remote validation when focus stealing would be disruptive locally.
- Use `peekaboo menu list --pid <pid> --json` for menu checks.
- Use `peekaboo image`, `peekaboo see`, window commands, and keyboard commands against that same PID for live UI validation.
- Tail `logs/toastty.log` under the runtime home for isolated runs.
- If the app was launched from Xcode, recover the PID and paths from `instance.json` under the worktree-derived runtime home rather than guessing from app name.
