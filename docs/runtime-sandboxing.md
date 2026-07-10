# Runtime Sandboxing

Toastty normally reads and writes mutable state in shared user locations such as `~/.toastty`, the app's default `UserDefaults` domain, and `~/Library/Logs/Toastty`. For dev, test, and automation work, Toastty can instead isolate that state inside a runtime home so one worktree or one run does not leak into another.

## Why it exists

Runtime sandboxing keeps:

- config edits from one worktree from changing another worktree's behavior
- workspace layout persistence from colliding across parallel runs
- terminal profile catalogs from being shared accidentally across tests
- log files, automation sockets, and `UserDefaults` state tied to the instance that produced them

## Runtime-home strategies

| Strategy | How it is enabled | Runtime-home path |
|---|---|---|
| Shared user state | default when no sandbox env var is set | none |
| Explicit runtime home | `TOASTTY_RUNTIME_HOME=/path/to/runtime-home` | exactly the path you provide |
| Worktree-derived runtime home | `TOASTTY_DEV_WORKTREE_ROOT=/path/to/worktree` | `<worktree>/artifacts/dev-runs/worktree-<basename>-<hash>/runtime-home` |

`TOASTTY_RUNTIME_LABEL=<label>` gives a runtime a run-owned identity. With `TOASTTY_DEV_WORKTREE_ROOT` and no explicit `TOASTTY_RUNTIME_HOME`, it overrides the stable worktree label and derives `<worktree>/artifacts/dev-runs/worktree-<label>/runtime-home`. With explicit `TOASTTY_RUNTIME_HOME`, it is metadata only and the provided path remains authoritative.

The automation helpers build on the same model by defaulting each run to its own isolated root under `artifacts/dev-runs/<RUN_ID>/`, setting `TOASTTY_RUNTIME_LABEL` from `RUN_ID`, and checking `instance.json` before driving socket actions.

## What moves into the runtime home

When runtime sandboxing is enabled, Toastty stores mutable app state inside the runtime home instead of the shared user locations:

- `config`
- `terminal-profiles.toml`
- `command-palette-usage.json`
- `workspace-layout-profiles.json`
- `scratchpad-documents/`
- `history/pane-journals/`
- `logs/toastty.log`
- `instance.json`
- a dedicated `UserDefaults` suite derived from the runtime-home path

Toastty also prepares a few support paths inside the runtime home:

- `run/`
- `runtime-version.txt`

## What stays outside

- The preferred automation socket still lives under the system temp directory so the Unix socket path stays short enough for macOS limits. When a runtime-isolated launch finds that stable path already owned by a live Toastty listener, it falls back to a per-process sibling path such as `events-v1-<pid>.sock` instead of stealing the existing socket.
- The app bundle and DerivedData location are only sandboxed if the caller chooses per-run paths. The automation helpers do this by default, but the app itself does not force it.
- Shell integration installation is disabled while runtime sandboxing is enabled so isolated dev/test runs never rewrite the user's login shell files. In `DEBUG` builds only, `TOASTTY_DEBUG_ALLOW_REAL_SHELL_INTEGRATION_INSTALL=1` provides an explicit opt-in bypass for manual installer validation against the real shell config from an Xcode-launched run.

## `instance.json`

When runtime sandboxing is enabled, Toastty writes `instance.json` in the runtime home at launch. This file is the source of truth for targeting the instance you actually launched.

It always records:

- `pid`
- `launchedAt`
- `bundlePath`
- `executablePath`
- `runtimeHomePath`
- `runtimeHomeStrategy`
- `runtimeLabel`
- `worktreeRootPath`
- `userDefaultsSuiteName`
- `logFilePath`
- `socketPath` (the authoritative resolved socket path for this launch, which may differ from the stable runtime-home-derived preferred path when fallback is used)

It may also record these fields when the launch flow provided them:

- `artifactsDirectory`
- `derivedPath`
- `runID`
- `arguments`

For automation and remote validation scripts, treat `runtimeLabel`, `runtimeHomePath`, and `socketPath` as a target ownership tuple. Destructive socket actions should only run after those fields match the current run.

Typical usage:

```bash
INSTANCE_JSON="$TOASTTY_RUNTIME_HOME/instance.json"
jq . "$INSTANCE_JSON"
PID="$(jq -r '.pid' "$INSTANCE_JSON")"
SOCKET_PATH="$(jq -r '.socketPath' "$INSTANCE_JSON")"
kill -0 "$PID"
```

Use the PID from `instance.json` for PID-targeted validation tools such as `peekaboo ... --pid <pid>` instead of targeting Toastty by app name. Use `socketPath` from the same file instead of reconstructing the socket path by hand.

## Common flows

### One-off sandbox

Use this when you want a disposable isolated run:

```bash
TOASTTY_RUNTIME_HOME="$PWD/artifacts/dev-runs/manual/runtime-home" \
TOASTTY_RUNTIME_LABEL="manual" \
TOASTTY_DERIVED_PATH="$PWD/artifacts/dev-runs/manual/Derived" \
/path/to/Toastty.app/Contents/MacOS/Toastty
```

### Stable worktree sandbox

Use this for repeated launches from the same worktree:

```bash
TOASTTY_DEV_WORKTREE_ROOT="$PWD" \
TOASTTY_DERIVED_PATH="$PWD/artifacts/dev-runs/manual/Derived" \
/path/to/Toastty.app/Contents/MacOS/Toastty
```

Tuist-generated Xcode Run schemes already set `TOASTTY_DEV_WORKTREE_ROOT=$(SRCROOT)` for `ToasttyApp` and `ToasttyApp-Release`.

### Automation helpers

Repo automation scripts create isolated run roots automatically, typically with this shape:

```text
artifacts/dev-runs/<RUN_ID>/
├── Derived/
├── artifacts/
└── runtime-home/
```

They also pass `TOASTTY_RUNTIME_LABEL=<RUN_ID>` and verify the manifest before sending automation or app-control requests.

This pattern is used by:

- `scripts/automation/smoke-ui.sh`
- `scripts/automation/shortcut-hints-smoke.sh`
- `scripts/automation/shortcut-trace.sh`

## Cleanup

Only clean up the sandbox you launched. Do not delete other runtime homes blindly if another Toastty instance may still be using them.

The repository-wide cleanup command evaluates `artifacts/dev-runs/` and other
managed artifact categories against `scripts/automation/artifact-retention.json`.
It defaults to a dry run:

```bash
./scripts/automation/cleanup-artifacts.sh --dry-run
```

Useful variants:

```bash
./scripts/automation/cleanup-artifacts.sh --dry-run --category dev-runs
./scripts/automation/cleanup-artifacts.sh --apply
./scripts/automation/cleanup-artifacts.sh --category dev-runs --include-unowned --apply
```

For dev runs, the cleanup helper reads `runtime-home/instance.json`, verifies
directory ownership, and retains a sandbox when its PID is live or cannot be
checked conclusively. Directories without ownership metadata require the
explicit `--include-unowned` option. Add a `.keep` file at the root of any
managed run directory to exempt it from cleanup.

## Related docs

- [README](../README.md)
- [Environment and Launch Flags](environment-and-build-flags.md)
- [Privacy and Local Data](privacy-and-local-data.md)
- [Toastty Dev Run Skill](../.agents/skills/toastty-dev-run/SKILL.md)
