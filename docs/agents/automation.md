# Toastty Automation Reference

Use this reference when a task needs smoke automation, remote validation, shortcut tracing, local dev runs, or custom launch flows.

## GitHub CI

`.github/workflows/mobile-ios.yml` displays as **Toastty CI**. It starts on every PR, pushes to `main`, and manual dispatch. Feature-branch pushes get automatic checks through their PR; manual dispatch can validate a branch before opening one. Pushes to `main` and manual dispatch run every job and are never cancelled, so each merged commit gets a full test run; a newer push to a PR cancels that PR's older run. PR job selection uses `.github/ci-paths.yml`:

- Desktop sources, tests, scripts, and build inputs select the full macOS Debug test suite and an unsigned Release build.
- Native iOS sources select Debug and Release simulator tests. Shared protocol changes select both platforms.
- Web-panel sources and generated bundles select both apps, which embed the bundles, plus web-panel tests on Linux. `npm test` also checks generated bundle synchronization.
- Documentation-only PR changes skip app jobs.

The required check remains named **Mobile iOS gate** for compatibility with existing repository rules. It requires selection to succeed, all selected jobs to pass, and rejects failed or cancelled jobs. `npm ci --prefix Tests/CI && npm test --prefix Tests/CI` runs local selection and gate regression tests without launching either app; it installs test dependencies under `Tests/CI/node_modules`.

GitHub jobs use disposable runners and no production host. The macOS commands build/test the `ToasttyApp` scheme with `TUIST_DISABLE_GHOSTTY=1`; Release uses `CODE_SIGNING_ALLOWED=NO` and does not archive or publish. This arm64 Release compile check is not release validation: it does not cover Intel compilation, signing, the embedded Ghostty runtime, or GUI smoke flows. Ghostty-backed pre-release validation still uses the existing remote workflows below with the required local artifact.

## Remote Smoke Validation

Agent-driven smoke validation should start with:

```bash
sv exec -- scripts/remote/validate.sh --smoke-test smoke-ui
```

Use `--require-remote` when the remote path itself must succeed. Supported smoke tests are:

- `smoke-ui`
- `workspace-tabs`
- `workspace-scope`
- `shortcut-hints`
- `shortcut-trace`

Use `--scope`, `--ref`, and `--run-label` when you need a non-default export scope or stable artifact label. Do not probe `TOASTTY_REMOTE_GUI_HOST` outside `sv exec`; the remote GUI env is injected there.

For Ghostty-required remote smoke tests such as `shortcut-trace`, `validate.sh` copies local `Dependencies/GhosttyKit*.xcframework` artifacts into the disposable remote worktree. Keep the local worktree bootstrapped before invoking that path.

When a change needs real shortcut tracing or only a screenshot/state artifact, prefer remote wrapper variants such as `--smoke-test shortcut-trace` or `--smoke-test shortcut-hints` before stealing focus locally.

### Detached Browser Status

Run the focused background-browser check through a disposable remote app:

```bash
sv exec -- scripts/remote/validate.sh --require-remote \
  --validation-command 'python3 scripts/automation/browser-background-status-check.py'
```

This targets the wrapper's isolated remote Toastty instance, not the installed
production app. The check verifies `instance.json`, creates a background
workspace and browser panels only in that instance, and serves temporary HTTP
fixtures on the remote loopback interface. It never selects a workspace/tab or
moves focus, and compares the visible workspace, tab, focused panel, and right
panel before and after its checks. The wrapper owns app shutdown and disposable
runtime cleanup.

The check covers detached loading, redirects, failures, invalid URLs, local PNG
navigation, repeated polling without reload, and loading only after a state
query. It also invokes `panel.browser.reload` through the built CLI, covering a
previously unloaded panel, cached HTTP content, modified local HTML, and restart
during loading without changing selection or focus. It writes `browser-background-status.json` and
`background-browser-fixture.png` under the run's artifacts directory. These are
semantic navigation evidence and an input fixture, not screenshots or proof of
visual correctness, HTTP success, SPA readiness, or video playback. Persisted
restoration, superseded navigation callbacks, and detached screenshot rejection
require the separate runtime tests.

## Remote Computer Use

Use `.agents/skills/toastty-computer-use/SKILL.md` when a GUI bug or fix needs human-like remote interaction beyond the supported smoke tests. That skill owns prompt templates, scope selection, `scripts/remote/computer-use-run.sh` invocation, and artifact interpretation.

App discovery has a 60-second startup timeout; ordinary protocol requests keep their 20-second timeout. The runner supports legacy `computer-use` events and current `cua_repl` events. For the current runtime, unattended approval is limited to the Computer Use connector's empty-form app-access requests for native inspection, clicking, dragging, scrolling, keyboard, and text-entry operations for `com.GiantThings.toastty`; other requests are declined. This grants access for the isolated test request and does not save an always-allow permission. If the default model is unavailable to the signed-in account, use the existing invocation-only `CODEX_COMPUTER_USE_MODEL` override with a model available to that account.

Run `node --test Tests/RemoteScripts/ComputerUseProtocolTests.mjs` locally to check approval boundaries and server-name compatibility without connecting to an app or remote host. The full `scripts/automation/check.sh` gate also includes these tests.

## Remote Xcode Tests

Agent-driven `xcodebuild test` runs should start with:

```bash
sv exec -- scripts/remote/test.sh -- ...
```

Pass `xcodebuild` flags after `--`. The wrapper defaults workspace, scheme, configuration, and destination when omitted. It owns the `test` action, `-derivedDataPath`, and `-resultBundlePath`.

Remote macOS tests require Ghostty in the generated project, even when selecting focused tests that omit the coverage canary. The wrapper reports a setup error before xcodebuild if Ghostty is absent or disabled. Native iOS tests do not need Ghostty.

Provision the dedicated remote source checkout's ignored `Dependencies/GhosttyKit.Debug.xcframework` and `Dependencies/GhosttyKit.Release.xcframework`, with their matching metadata sidecars, using artifacts installed as described in [Ghostty Integration](../ghostty-integration.md#installing-a-local-ghostty-artifact). Copy the actual files when local artifacts are symlinks. `scripts/dev/bootstrap-worktree.sh` links those artifacts into disposable remote worktrees before generation, so ordinary tests, smoke runs, and Computer Use builds can reuse them without transferring binaries each time. Refresh the remote artifacts and sidecars together whenever the intended Ghostty build changes; exporting a Toastty git ref does not pin these ignored binaries.

The remote wrappers wake the host display and hold it awake (`caffeinate -u`, then `caffeinate -dis` bound to the run) for the duration of a run. AppKit window animations inside the test host never complete while the display is asleep, and each one leaks a dispatch worker thread; once the pool fills, socket-backed and concurrency tests hang until the watchdog fires. If a full `ToasttyApp` gate hangs in `AutomationSocketServerAppControlTests` after `ToasttyUserSkillCatalogTests`/`ToasttySkillArtifactSweeperTests` timeouts, check `pmset -g log | grep "Display is turned"` on the host first.

Prefer omitting `-destination` for remote tests. If a destination is required, use `platform=macOS,arch=arm64` unless intentionally testing Rosetta. Remote `x86_64` test destinations are blocked by default after Rosetta hangs left orphaned `xcodebuild` or test-host processes; only override with `TOASTTY_ALLOW_REMOTE_X86_64_TESTS=1` when intentionally validating Rosetta.

Use `--scope`, `--ref`, and `--run-label` as needed. Remote `xcodebuild` is killed after `TOASTTY_REMOTE_TEST_TIMEOUT_SECONDS` seconds (default `3600`; set `0` to disable), and the wrapper cleans up the spawned process tree on timeout or interruption.

### Native iOS Tests

The native client is an independent Tuist graph under `ios/`; root `Project.swift` and root `Tuist/` remain the macOS host graph. Generate and test the iOS graph through its dispatcher:

```bash
node ios/scripts/toastty-ios.mjs generate
node ios/scripts/toastty-ios.mjs test
```

Each dispatcher command accepts `--dry-run`. For agent-driven testing, keep simulator work on toastty-mini:

```bash
sv exec -- scripts/remote/test.sh \
  --platform ios \
  --scope working-tree \
  --run-label <label>
```

`--platform ios` makes the wrapper run the iOS dispatcher generation step in the disposable remote worktree and default to `ios/ToasttyMobile.xcworkspace`, scheme `ToasttyMobileApp`, Debug, and serial test execution. Custom xcodebuild flags after `--` supplement those defaults; an explicit workspace or project, scheme, configuration, parallel-testing setting, or destination wins. When no `-destination` is passed, the wrapper clones a clean shutdown `Toastty Remote Template`, records immutable run and simulator ownership, boots and targets that exact clone, and deletes it during run-scoped cleanup. Explicit destinations remain caller-owned and are never shut down or deleted by the wrapper. Do not pass `-derivedDataPath`, `-resultBundlePath`, or an action.

The `Toastty CI` workflow runs secret-free dispatcher and release-script tests, then separate Debug and Release simulator jobs. Debug runs the fixture UI suite as well as app/domain tests. Setting `TOASTTY_IOS_CONFIGURATION=Release` on the dispatcher selects only app/domain tests and enables internal test imports without defining `DEBUG`; fixture UI launches require Debug. The remote wrapper invokes xcodebuild directly, so select the same focused Release tier explicitly:

```bash
sv exec -- scripts/remote/test.sh --platform ios --scope working-tree \
  --run-label ios-release-tests -- \
  -configuration Release ENABLE_TESTABILITY=YES \
  -only-testing:ToasttyMobileAppTests \
  -only-testing:ToasttyMobileDomainTests
```

This generates, builds, and tests a disposable remote checkout and simulator; it does not sign or upload a release or pair with a production host. To inspect the dispatcher plan locally without invoking Tuist or a simulator, use `TOASTTY_IOS_CONFIGURATION=Release node ios/scripts/toastty-ios.mjs test --dry-run`.

Automatic dispatcher selection uses the newest installed compatible iOS runtime. It does not establish coverage of the iOS 18 minimum or compact phones. Before a release, record the installed runtime/device inventory and, where available, run the focused suite on an explicitly provisioned iOS 18 compact iPhone destination. Use an exact simulator ID through `TOASTTY_IOS_DESTINATION` in CI or `-destination` after the remote wrapper's `--`; caller-supplied remote devices remain caller-owned. Record unavailable runtime/device coverage as a gap rather than substituting a newer large phone silently.

For pre-release host/client coverage, see the disposable-host procedure in [iOS Release CI](../ios-release-ci.md#disposable-host-validation). Ordinary CI does not configure live pairing inputs, so its live-gateway skips are expected and do not prove host interoperability.

The remote timeout watchdog owns a separate timer child and reaps it on success, timeout, or interruption. Cleanup first stops the run's xcodebuild tree, then terminates only Toastty host executables under that run's DerivedData path, and finally removes only a matching manifest-owned simulator clone. `result.json` records test and cleanup failures separately. A run is marked `COMPLETED` only after cleanup succeeds; interrupted or ambiguous runs stay on the remote host for fail-closed review. Never use broad `pkill` cleanup for remote tests.

Evaluate abandoned manifest-owned remote runs before simulator cleanup:

```bash
sv exec -- ./scripts/remote/cleanup-remote-runs.sh --dry-run
sv exec -- ./scripts/remote/cleanup-remote-runs.sh --apply
sv exec -- ./scripts/remote/cleanup-simulators.sh --dry-run
sv exec -- ./scripts/remote/cleanup-simulators.sh --apply
sv exec -- ./scripts/remote/cleanup-simulator-app.sh --dry-run
sv exec -- ./scripts/remote/cleanup-simulator-app.sh --apply
```

`cleanup-remote-runs.sh` requires exact root-child paths, immutable ownership, an expired retention window, no matching live owner or path-scoped process, and no `.keep` marker. It removes paired worktrees through `git worktree remove`, caps each apply to ten runs, and treats unowned, malformed, symlinked, live, or booted-simulator cases as retained/manual review. The simulator cleaner remains the legacy cleanup path for old `Plate Remote remote-test-*` and `Plate Remote remote-validate-*` devices.

Run `cleanup-simulator-app.sh` last to close stale Simulator.app window shells
that can survive after their CoreSimulator devices shut down or are deleted.
It never changes device state. Apply mode terminates only an exact
Xcode-provided Simulator.app process that is at least 15 minutes old, after
repeated checks confirm that no device is booted and no live or path-active
iOS remote test exists. Unexpected process identity or age, a booted device,
a live iOS owner, or a state change during the recheck is retained for manual
review.

For changes under `Sources/RemoteProtocol/` or `Tests/RemoteProtocol/`, run both this iOS tier and the root macOS graph. Report whether each iOS result came from fixture tests, a remote simulator, or a physical device.

## Local Helpers

Use local smoke helpers only when the user explicitly wants a local run, the check is local-only, or the remote wrapper path has already fallen back or failed and you are intentionally continuing locally.

- `smoke-ui.sh`: builds/runs app in automation mode, drives socket actions, emits screenshots/state dumps, and restores the previously frontmost app after Toastty is ready.
- `smoke-cli-live-control.sh`: builds/runs app in a normal runtime-isolated launch, then validates the CLI's always-on `action`/`query` surface against that exact instance via `instance.json`.
- `workspace-scope-smoke.sh`: builds/runs app in a normal runtime-isolated launch, then validates cooperative workspace scope through the CLI and socket path, including `scope_denied`, `session scope add`, and `session scope clear`.
- `shortcut-hints-smoke.sh`: builds/runs app in automation mode, captures one screenshot focused on visible shortcut hints, emits a matching state dump, and restores the previously frontmost app.
- `shortcut-trace.sh`: drives real keyboard shortcuts through AppKit and verifies split/focus/resize workflows.

`shortcut-trace.sh` requires Accessibility and Automation permissions, a Ghostty-enabled build, `nc`, `osascript`, and `uuidgen`. It performs a timed `System Events` preflight and fails fast when permissions are missing. SSH-based remote runs skip the `Workspace > Close Panel` menu-equivalence subcheck because `System Events` menu-item dispatch is not reliable in that context; local trace runs still keep that assertion.

Default focus coordinates for shortcut tracing are `CLICK_X=760`, `CLICK_Y=420`; override them for your display layout.

## Runtime Isolation

For any local dev/debug/test Toastty run, use an isolated runtime home and per-run filesystem paths. Treat PID, bundle path, and per-run directories as required targeting data.

Automation helpers default to `artifacts/dev-runs/<RUN_ID>/...` and set unique `TOASTTY_RUNTIME_HOME`, `TOASTTY_RUNTIME_LABEL`, `DERIVED_PATH`, `ARTIFACTS_DIR`, and `SOCKET_PATH` for each run. Follow the same pattern for custom launch flows.

Use `TOASTTY_RUNTIME_LABEL` as the run-owned targeting label. Before a script sends destructive socket actions, verify the target `instance.json` has the expected `runtimeLabel`, `runtimeHomePath`, and `socketPath`; do not drive a stable worktree-derived Xcode runtime by accident.

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

### Retention And Cleanup

`scripts/automation/artifact-retention.json` is the versioned retention policy.
`./scripts/automation/cleanup-artifacts.sh --dry-run` explicitly previews the
policy without deleting anything; pass `--apply` to delete eligible
directories. The managed categories are:

- `dev-runs`: inactive, safely owned runs older than 24 hours
- `remote-tests` and `remote-gui`: passing runs older than 7 days, and failed,
  setup-error, timeout, or agent-error runs older than 30 days
- release, manual, diagnostics, review, local-test, and other named categories:
  manual retention only

The cleaner fails closed. It retains directories with `.keep`, missing or
malformed metadata, unknown result statuses, recent activity, live PIDs, or
ambiguous PID state. Categories absent from the policy are not scanned.
`--include-unowned` is an explicit dev-run recovery option and should not be
used by scheduled cleanup.

The repository does not invoke cleanup from smoke, remote, Computer Use, or
release scripts. Configure a once-daily Codex App scheduled task in this local
project to run a preview before applying the same policy:

```bash
./scripts/automation/cleanup-artifacts.sh --dry-run
./scripts/automation/cleanup-artifacts.sh --apply
```

The dedicated remote validation Mac also needs three separate cleanup passes.
`scripts/remote/cleanup-remote-runs.sh` removes expired manifest-owned test
runs and their exact shutdown simulator clones. Then
`scripts/remote/cleanup-simulators.sh` targets only the legacy
`Plate Remote remote-test-*` and `Plate Remote remote-validate-*` devices
created by earlier automation.
It considers a device eligible only when it is shut down and its last boot is
more than 24 hours old. Booted devices, recent devices, ambiguous metadata,
ordinary Xcode simulators, and current `Toastty Mobile *` dispatcher devices
are never deleted by this policy. Apply mode verifies the configured remote
repository/validation-root tuple, takes a remote lock, and rechecks every
candidate immediately before deletion.

Finally, `scripts/remote/cleanup-simulator-app.sh` closes stale Simulator.app
window shells without shutting down or deleting devices. It acts only when an
exact Simulator.app process is at least 15 minutes old, no Simulator device is
booted, and no live iOS remote run is present. It first sends a bounded
graceful application-quit request, validates process identity again before a
`TERM` fallback, and does not escalate to `KILL` if Simulator.app refuses to
exit.

Preview and apply that policy through the manifest-scoped environment:

```bash
sv exec -- ./scripts/remote/cleanup-remote-runs.sh --dry-run
sv exec -- ./scripts/remote/cleanup-remote-runs.sh --apply
sv exec -- ./scripts/remote/cleanup-simulators.sh --dry-run
sv exec -- ./scripts/remote/cleanup-simulators.sh --apply
sv exec -- ./scripts/remote/cleanup-simulator-app.sh --dry-run
sv exec -- ./scripts/remote/cleanup-simulator-app.sh --apply
```

Use this scheduled-task prompt so local artifacts and remote simulators retain
separate failure boundaries:

```text
In /Users/vishal/GiantThings/repos/toastty, run these four cleanup groups independently. Within each group, run the dry-run first and run apply only when that dry-run succeeds. If a command fails, skip the rest of that group, record the failure, and continue to the next group.

1. Local artifacts:
./scripts/automation/cleanup-artifacts.sh --dry-run
./scripts/automation/cleanup-artifacts.sh --apply

2. Manifest-owned remote runs and their simulator clones:
sv exec -- ./scripts/remote/cleanup-remote-runs.sh --dry-run
sv exec -- ./scripts/remote/cleanup-remote-runs.sh --apply

3. Legacy remote simulators:
sv exec -- ./scripts/remote/cleanup-simulators.sh --dry-run
sv exec -- ./scripts/remote/cleanup-simulators.sh --apply

4. Stale Simulator.app window shells:
sv exec -- ./scripts/remote/cleanup-simulator-app.sh --dry-run
sv exec -- ./scripts/remote/cleanup-simulator-app.sh --apply

Do not edit source, use --include-unowned, invoke simctl directly, or manually shut down/delete booted simulators. Report all eight summary lines, every manual-review count, and every skipped or failed group.
```

The scheduled task must use the main local checkout, not an isolated worktree,
because artifact directories belong to that checkout. If the machine or Codex
App is not running, cleanup waits until a later scheduled run; there is no cron
or LaunchAgent fallback. The remote steps also require the three
`TOASTTY_REMOTE_GUI_*` values from the repository's `.secrets` manifest.

Common smoke env: `RUN_ID`, `DEV_RUN_ROOT`, `TOASTTY_RUNTIME_HOME`, `TOASTTY_RUNTIME_LABEL`, `DERIVED_PATH`, `ARTIFACTS_DIR`, `SOCKET_PATH`, `ARCH`.

CLI live-control env: `RUN_ID`, `DEV_RUN_ROOT`, `TOASTTY_RUNTIME_HOME`, `TOASTTY_RUNTIME_LABEL`, `DERIVED_PATH`, `ARTIFACTS_DIR`, `ARCH`, `TOASTTY_CLI_LIVE_RESTORE_FRONT_APP`.

Workspace-scope env: `RUN_ID`, `DEV_RUN_ROOT`, `TOASTTY_RUNTIME_HOME`, `TOASTTY_RUNTIME_LABEL`, `DERIVED_PATH`, `ARTIFACTS_DIR`, `ARCH`, `TOASTTY_WORKSPACE_SCOPE_RESTORE_FRONT_APP`.

Shortcut-hints env: `RUN_ID`, `FIXTURE`, `DEV_RUN_ROOT`, `TOASTTY_RUNTIME_HOME`, `TOASTTY_RUNTIME_LABEL`, `DERIVED_PATH`, `ARTIFACTS_DIR`, `SOCKET_PATH`, `ARCH`, `TOASTTY_SHORTCUT_HINTS_RESTORE_FRONT_APP`.

Shortcut-trace env: `RUN_ID`, `DEV_RUN_ROOT`, `TOASTTY_RUNTIME_HOME`, `TOASTTY_RUNTIME_LABEL`, `DERIVED_PATH`, `ARTIFACTS_DIR`, `SOCKET_PATH`, `CLICK_X`, `CLICK_Y`, `SPLIT_KEY_CODE`, `FOCUS_NEXT_KEY_CODE`, `FOCUS_PREVIOUS_KEY_CODE`, `RESIZE_KEY_CODE`, `EQUALIZE_KEY_CODE`, `TRACE_LOG_PATH`, `TOASTTY_SHORTCUT_TRACE_SKIP_MENU_CLOSE`.

Remote GUI env: `TOASTTY_REMOTE_GUI_HOST`, `TOASTTY_REMOTE_GUI_REPO_ROOT`, `TOASTTY_REMOTE_GUI_ROOT`.

Remote test env: `TOASTTY_REMOTE_TEST_TIMEOUT_SECONDS`, `TOASTTY_ALLOW_REMOTE_X86_64_TESTS`. Select the native client with the `--platform ios` CLI flag.

Manual/Xcode env: `TOASTTY_RUNTIME_HOME` or `TOASTTY_DEV_WORKTREE_ROOT`, plus `TOASTTY_SOCKET_PATH` if you need a specific socket path.
