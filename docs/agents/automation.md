# Toastty Automation Reference

Use this reference when a task needs smoke automation, remote validation, shortcut tracing, local dev runs, or custom launch flows.

## Remote Smoke Validation

Agent-driven smoke validation should start with:

```bash
sv exec -- scripts/remote/validate.sh --smoke-test smoke-ui
```

Use `--require-remote` when the remote path itself must succeed. Supported smoke tests are:

- `smoke-ui`
- `workspace-tabs`
- `shortcut-hints`
- `shortcut-trace`

Use `--scope`, `--ref`, and `--run-label` when you need a non-default export scope or stable artifact label. Do not probe `TOASTTY_REMOTE_GUI_HOST` outside `sv exec`; the remote GUI env is injected there.

For Ghostty-required remote smoke tests such as `shortcut-trace`, `validate.sh` copies local `Dependencies/GhosttyKit*.xcframework` artifacts into the disposable remote worktree. Keep the local worktree bootstrapped before invoking that path.

When a change needs real shortcut tracing or only a screenshot/state artifact, prefer remote wrapper variants such as `--smoke-test shortcut-trace` or `--smoke-test shortcut-hints` before stealing focus locally.

## Remote Xcode Tests

Agent-driven `xcodebuild test` runs should start with:

```bash
sv exec -- scripts/remote/test.sh -- ...
```

Pass `xcodebuild` flags after `--`. The wrapper defaults workspace, scheme, configuration, and destination when omitted. It owns the `test` action, `-derivedDataPath`, and `-resultBundlePath`.

Prefer omitting `-destination` for remote tests. If a destination is required, use `platform=macOS,arch=arm64` unless intentionally testing Rosetta. Remote `x86_64` test destinations are blocked by default after Rosetta hangs left orphaned `xcodebuild` or test-host processes; only override with `TOASTTY_ALLOW_REMOTE_X86_64_TESTS=1` when intentionally validating Rosetta.

Use `--scope`, `--ref`, and `--run-label` as needed. Remote `xcodebuild` is killed after `TOASTTY_REMOTE_TEST_TIMEOUT_SECONDS` seconds (default `3600`; set `0` to disable), and the wrapper cleans up the spawned process tree on timeout or interruption.

## Local Helpers

Use local smoke helpers only when the user explicitly wants a local run, the check is local-only, or the remote wrapper path has already fallen back or failed and you are intentionally continuing locally.

- `smoke-ui.sh`: builds/runs app in automation mode, drives socket actions, emits screenshots/state dumps, and restores the previously frontmost app after Toastty is ready.
- `smoke-cli-live-control.sh`: builds/runs app in a normal runtime-isolated launch, then validates the CLI's always-on `action`/`query` surface against that exact instance via `instance.json`.
- `shortcut-hints-smoke.sh`: builds/runs app in automation mode, captures one screenshot focused on visible shortcut hints, emits a matching state dump, and restores the previously frontmost app.
- `shortcut-trace.sh`: drives real keyboard shortcuts through AppKit and verifies split/focus/resize workflows.

`shortcut-trace.sh` requires Accessibility and Automation permissions, a Ghostty-enabled build, `nc`, `osascript`, and `uuidgen`. It performs a timed `System Events` preflight and fails fast when permissions are missing. SSH-based remote runs skip the `Workspace > Close Panel` menu-equivalence subcheck because `System Events` menu-item dispatch is not reliable in that context; local trace runs still keep that assertion.

Default focus coordinates for shortcut tracing are `CLICK_X=760`, `CLICK_Y=420`; override them for your display layout.

## Runtime Isolation

For any local dev/debug/test Toastty run, use an isolated runtime home and per-run filesystem paths. Treat PID, bundle path, and per-run directories as required targeting data.

Automation helpers default to `artifacts/dev-runs/<RUN_ID>/...` and set unique `TOASTTY_RUNTIME_HOME`, `DERIVED_PATH`, `ARTIFACTS_DIR`, and `SOCKET_PATH` for each run. Follow the same pattern for custom launch flows.

For `shortcut-trace.sh` or other trace-style runs, also use a unique `TRACE_LOG_PATH` per instance instead of a shared log path.

When runtime isolation is enabled, Toastty writes `instance.json` inside the runtime home. Use it to find the exact sandbox, log path, socket path, derived path, worktree root, bundle path, and PID for the running instance you launched.

Before any `peekaboo` call, get the PID from `instance.json` and confirm it is still alive. If the PID is stale, relaunch instead of guessing.

## Peekaboo And Visual Checks

Use `peekaboo` for menus, shortcuts, focus, window state, and visual inspection of a running Toastty instance. Do not use it for build verification, log inspection, or checks that automation/unit tests already cover.

Before required local `peekaboo`, run:

```bash
peekaboo permissions --json
```

If Accessibility is missing, stop and ask the user to grant it before continuing locally. If the user does not want to grant local Accessibility, switch to `sv exec -- scripts/remote/validate.sh`.

For menu validation, target the exact built app instance by PID or full app bundle path. Prefer:

```bash
peekaboo menu list --pid <pid> --json
```

This is more reliable than generic AppleScript enumeration for nested SwiftUI/AppKit menus.

If visual validation is taking several minutes or several turns and keeps failing due to flakiness in `peekaboo`, Accessibility, focus, or app targeting, pause. Summarize what was validated, what is flaky or blocked, and exact remaining manual checks.

## Artifacts And Environment

Artifacts are stored in `artifacts/` (gitignored). Manual captures go in `artifacts/manual/`.

Common smoke env: `RUN_ID`, `DEV_RUN_ROOT`, `TOASTTY_RUNTIME_HOME`, `DERIVED_PATH`, `ARTIFACTS_DIR`, `SOCKET_PATH`, `ARCH`.

CLI live-control env: `RUN_ID`, `DEV_RUN_ROOT`, `TOASTTY_RUNTIME_HOME`, `DERIVED_PATH`, `ARTIFACTS_DIR`, `ARCH`, `TOASTTY_CLI_LIVE_RESTORE_FRONT_APP`.

Shortcut-hints env: `RUN_ID`, `FIXTURE`, `DEV_RUN_ROOT`, `TOASTTY_RUNTIME_HOME`, `DERIVED_PATH`, `ARTIFACTS_DIR`, `SOCKET_PATH`, `ARCH`, `TOASTTY_SHORTCUT_HINTS_RESTORE_FRONT_APP`.

Shortcut-trace env: `RUN_ID`, `DEV_RUN_ROOT`, `TOASTTY_RUNTIME_HOME`, `DERIVED_PATH`, `ARTIFACTS_DIR`, `SOCKET_PATH`, `CLICK_X`, `CLICK_Y`, `SPLIT_KEY_CODE`, `FOCUS_NEXT_KEY_CODE`, `FOCUS_PREVIOUS_KEY_CODE`, `RESIZE_KEY_CODE`, `EQUALIZE_KEY_CODE`, `TRACE_LOG_PATH`, `TOASTTY_SHORTCUT_TRACE_SKIP_MENU_CLOSE`.

Remote GUI env: `TOASTTY_REMOTE_GUI_HOST`, `TOASTTY_REMOTE_GUI_REPO_ROOT`, `TOASTTY_REMOTE_GUI_ROOT`.

Remote test env: `TOASTTY_REMOTE_TEST_TIMEOUT_SECONDS`, `TOASTTY_ALLOW_REMOTE_X86_64_TESTS`.

Manual/Xcode env: `TOASTTY_RUNTIME_HOME` or `TOASTTY_DEV_WORKTREE_ROOT`, plus `TOASTTY_SOCKET_PATH` if you need a specific socket path.
