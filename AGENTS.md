# Toastty

## Instruction Scope

- This project file is shared across agent runtimes. Follow the active agent's global instructions for interaction style, review mechanics, and tool availability; the Toastty commands and project constraints here win for this repository.
- When a workflow points at `.agents/skills/.../SKILL.md`, read that file as the authoritative task guide when the task applies. If the active runtime does not load skill files automatically, read the referenced file directly and follow the documented workflow intent.
- Keep this file concise. Detailed reference material lives under `docs/agents/`:
  - `docs/agents/automation.md` for smoke, remote, test, and dev-run details.
  - `docs/agents/menu-performance.md` for menu-related regressions and shortcuts.
  - `docs/agents/manual-interaction.md` for local UI scripting notes.

## Build And Generate

- Source of truth: `Project.swift`. Never hand-edit generated Xcode project/workspace files.
- Install packages with `tuist install` after cloning and whenever `Tuist/Package.swift` or `Tuist/Package.resolved` changes. Repo scripts do this automatically where needed.
- For a fresh worktree, run `./scripts/dev/bootstrap-worktree.sh`. It links local Ghostty artifacts when needed, then runs `tuist install` and `tuist generate --no-open`.
- Regenerate with `tuist generate` after project/dependency/build-setting changes, source file adds/renames/deletes, or branch switches. Generated `.xcodeproj` and `.xcworkspace` files are gitignored and can otherwise keep stale references.
- Build:
  ```bash
  ARCH="${ARCH:-$(if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" == "1" ]]; then echo arm64; else uname -m; fi)}"; xcodebuild -workspace toastty.xcworkspace -scheme ToasttyApp -configuration Debug -destination "platform=macOS,arch=${ARCH}" -derivedDataPath Derived build
  ```
- Full local gate: `./scripts/automation/check.sh` (generate, build, test).
- After any code, project, dependency, or merge-related change, ensure the generated Xcode project is current and the app builds cleanly before handoff. This includes branch merges and branch switches that may leave generated project state stale.
- Avoid deriving `ARCH` from `uname -m` in translated shells or inside `sv exec`; it may report `x86_64` on arm64 hosts. Set `ARCH=arm64` explicitly for agent/remote runs unless intentionally validating Rosetta. Prefer invocation-scoped overrides such as `ARCHS` and `ONLY_ACTIVE_ARCH=YES` over mutating project settings.

## Validation

For UI/runtime changes, validate beyond unit tests: run automation and inspect visually when appropriate. Read `docs/agents/automation.md` before custom validation flows.

```bash
# Agent default: remote smoke via the wrapper, with fallback handled by validate.sh
sv exec -- scripts/remote/validate.sh --smoke-test smoke-ui

# Require the remote path itself when that is what you are validating
sv exec -- scripts/remote/validate.sh --smoke-test smoke-ui --require-remote

# Agent-driven remote xcodebuild tests
sv exec -- scripts/remote/test.sh -- ...
```

- Agent-driven smoke validation should start with `sv exec -- scripts/remote/validate.sh --smoke-test ...`. Do not probe `TOASTTY_REMOTE_GUI_HOST` outside `sv exec`; the remote GUI env is injected there.
- Agent-driven `xcodebuild test` runs should start with `sv exec -- scripts/remote/test.sh -- ...`, not direct local `xcodebuild test`.
- Prefer omitting `-destination` for remote tests, or set `arch=arm64` explicitly. Remote `x86_64` test destinations are blocked by default; override only when intentionally validating Rosetta.
- Use local smoke helpers only when the user explicitly wants a local run, the check is local-only, or the remote wrapper has already fallen back or failed and you are intentionally continuing locally.
- For live UI validation of a running app instance, follow `.agents/skills/toastty-dev-run/SKILL.md` and the `peekaboo` workflow if available.
- Before required local `peekaboo`, run `peekaboo permissions --json`. If Accessibility is missing, stop and ask the user to grant it; do not improvise local GUI workarounds.
- When a change needs real shortcut tracing or only a screenshot/state artifact, prefer remote wrapper variants such as `--smoke-test shortcut-trace` or `--smoke-test shortcut-hints` before stealing focus locally.
- In handoffs, say whether validation ran remotely, locally, or through `validate.sh` with local fallback.
- Artifacts are stored in `artifacts/` (gitignored). Manual captures go in `artifacts/manual/`. Committed planning docs belong in `docs/plans/`, not `artifacts/`.

## Dev/Test Runs

- For local dev/debug/test Toastty runs, use an isolated runtime home and per-run filesystem paths.
- Either set `TOASTTY_RUNTIME_HOME` explicitly or set `TOASTTY_DEV_WORKTREE_ROOT` to the repo/worktree root and let Toastty derive a stable runtime home under `artifacts/dev-runs/`.
- Tuist-generated Xcode Run schemes already set `TOASTTY_DEV_WORKTREE_ROOT=$(SRCROOT)` for `ToasttyApp` and `ToasttyApp-Release`. Preserve that behavior when editing `Project.swift`.
- Before a Ghostty-backed build from a fresh worktree, run `./scripts/dev/bootstrap-worktree.sh`. The smoke, shortcut-trace, and check helpers already do this.
- Capture launched app PID and use PID-targeted tooling whenever possible. Prefer `peekaboo ... --pid <pid>` and avoid generic `osascript` or app-name-only targeting when multiple Toastty instances may be running.
- Runtime isolation writes `instance.json` inside the runtime home. Treat it as authoritative for `pid`, `bundlePath`, `runtimeHomePath`, `logFilePath`, `socketPath`, derived path, and worktree root.
- For Xcode-launched Toastty runs, assume runtime isolation is active unless you have evidence otherwise. Start from `artifacts/dev-runs/worktree-*/runtime-home/instance.json`, not global logs.
- Shell integration installation is intentionally disabled when runtime isolation is enabled. Sandboxed dev/test runs must not rewrite the user's login shell files.
- When a run is finished, clean up only its own per-run directories. Use `./scripts/automation/cleanup-dev-runs.sh` for stale run cleanup, and never delete paths for a still-running PID.

## Ghostty Integration

- Default-on when a local xcframework exists in `Dependencies/` and disable env is not set.
- Opt out with `TUIST_DISABLE_GHOSTTY=1` or `TOASTTY_DISABLE_GHOSTTY=1`.
- Install/update artifact: `./scripts/ghostty/install-local-xcframework.sh`.
- Bootstrap a fresh worktree: `./scripts/dev/bootstrap-worktree.sh`.
- Use `GHOSTTY_XCFRAMEWORK_VARIANT=release|debug` to pick variant, or `GHOSTTY_XCFRAMEWORK_SOURCE=/path/to/GhosttyKit.xcframework` to override source.
- Config loading order: `TOASTTY_GHOSTTY_CONFIG_PATH`, then `$XDG_CONFIG_HOME/ghostty/config`, then `~/.config/ghostty/config`, then Ghostty defaults.
- Toastty config: `~/.toastty/config` stores user-authored defaults such as `terminal-font-size` and `default-terminal-profile`.
- UI font override: Toastty remembers menu-driven terminal font changes per window in persisted layout state. `Reset Terminal Font` clears that window-local override.
- Host-side split styling: `unfocused-split-opacity`, `unfocused-split-fill` (falls back to Ghostty `background`).
- Runtime config reload: `Toastty -> Reload Configuration`.
- When linked, `Project.swift` adds `TOASTTY_HAS_GHOSTTY_KIT` and linker flags (`-lc++`, `-framework Carbon`).
- After changing artifacts or settings, regenerate and rebuild before validating.

## Release Workflow

- Ghostty release provenance: install release artifacts with `GHOSTTY_BUILD_FLAGS=... ./scripts/ghostty/install-local-xcframework.sh`; the installer writes ignored sidecar metadata under `Dependencies/GhosttyKit.Release.metadata.env`.
- Build release DMG and draft notes: follow `.agents/skills/toastty-release/SKILL.md`. `scripts/release/release.sh` requires a clean Toastty git tree and a clean Ghostty metadata snapshot, then writes `release-metadata.env`, `ghostty-metadata.env`, `sparkle-metadata.env`, and drafted `release-notes.md` into `artifacts/release/<version>-<build>/`.
- Publish later: follow `.agents/skills/toastty-publish/SKILL.md`. It verifies existing drafted notes and release metadata, then runs `scripts/release/publish-github-release.sh --create-tag`.

## Logging

- Ordinary runs log to `~/Library/Logs/Toastty/toastty.log`.
- Runtime-isolated runs log to `<runtime-home>/logs/toastty.log` and rotate at 5 MB to `toastty.previous.log`.
- For a specific dev/Xcode instance, resolve `instance.json` first and read `logFilePath` from there.
- Useful env vars: `TOASTTY_LOG_LEVEL`, `TOASTTY_LOG_FILE` (`none` disables), `TOASTTY_LOG_STDERR=1`, `TOASTTY_LOG_DISABLE=1`.
- Key instrumentation points: `TerminalHostView` (key events), `GhosttyRuntimeManager` (action routing), `TerminalRuntimeRegistry` (dispatch), `AppReducer` (split resize/equalize).

## Menu And Interaction Gotchas

- Read `docs/agents/menu-performance.md` before touching menu rebuilds, hidden system menu items, workspace shortcuts, or `Cmd+W` handling.
- Do not recreate broad `NSMenu` mutation observer refresh loops. Keep menu refresh bounded, coalesced, idempotent, and separate from dynamic bridge reinsertion.
- Menu-advertised `Option+digit` workspace shortcuts are not sufficient by themselves; keep app-level interception for workspace switching.
- Do not retarget native File > Close / Close All slots in place. Prefer Toastty-owned File menu items wired to the same command paths as `Cmd+W` and workspace close.
- For manual local UI scripting, read `docs/agents/manual-interaction.md`. Click into the target terminal panel before typing; activation alone is insufficient.
