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

The automation helpers build on the same model by defaulting each run to its own isolated root under `artifacts/dev-runs/<RUN_ID>/`.

## What moves into the runtime home

When runtime sandboxing is enabled, Toastty stores mutable app state inside the runtime home instead of the shared user locations:

- `config`
- `terminal-profiles.toml`
- `workspace-layout-profiles.json`
- `logs/toastty.log`
- `instance.json`
- a dedicated `UserDefaults` suite derived from the runtime-home path

Toastty also prepares a few support paths inside the runtime home:

- `run/`
- `runtime-version.txt`

## What stays outside

- The default automation socket still lives under the system temp directory so the Unix socket path stays short enough for macOS limits.
- The app bundle and DerivedData location are only sandboxed if the caller chooses per-run paths. The automation helpers do this by default, but the app itself does not force it.
- Shell integration installation is disabled while runtime sandboxing is enabled so isolated dev/test runs never rewrite the user's login shell files.

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

It may also record these fields when the launch flow provided them:

- `socketPath`
- `artifactsDirectory`
- `derivedPath`
- `runID`
- `arguments`

Typical usage:

```bash
INSTANCE_JSON="$TOASTTY_RUNTIME_HOME/instance.json"
jq . "$INSTANCE_JSON"
PID="$(jq -r '.pid' "$INSTANCE_JSON")"
kill -0 "$PID"
```

Use the PID from `instance.json` for PID-targeted validation tools such as `peekaboo ... --pid <pid>` instead of targeting Toastty by app name.

## Common flows

### One-off sandbox

Use this when you want a disposable isolated run:

```bash
TOASTTY_RUNTIME_HOME="$PWD/artifacts/dev-runs/manual/runtime-home" \
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

This pattern is used by:

- `scripts/automation/smoke-ui.sh`
- `scripts/automation/shortcut-hints-smoke.sh`
- `scripts/automation/shortcut-trace.sh`

## Cleanup

Only clean up the sandbox you launched. Do not delete other runtime homes blindly if another Toastty instance may still be using them.

For stale per-run sandboxes under `artifacts/dev-runs/`, use:

```bash
./scripts/automation/cleanup-dev-runs.sh
```

Useful variants:

```bash
./scripts/automation/cleanup-dev-runs.sh --dry-run
OLDER_THAN_HOURS=12 ./scripts/automation/cleanup-dev-runs.sh
```

The cleanup helper reads `runtime-home/instance.json` and skips sandboxes whose recorded PID is still alive.

## Related docs

- [README](../README.md)
- [Environment and Launch Flags](environment-and-build-flags.md)
- [Privacy and Local Data](privacy-and-local-data.md)
- [Toastty Dev Run Skill](../.agents/skills/toastty-dev-run/SKILL.md)
