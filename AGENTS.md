# Toastty

## Instruction Scope

- This project file is shared across agent runtimes. Follow the active agent's global instructions for interaction style, review mechanics, and tool availability; the Toastty commands and project constraints here win for this repository.
- When a workflow points at `.agents/skills/.../SKILL.md`, read that file as the authoritative task guide when the task applies. If the active runtime does not load skill files automatically, read the referenced file directly and follow the documented workflow intent.
- Keep this file concise. Detailed reference material lives under `docs/agents/`:
  - `.agents/skills/toastty-verify/SKILL.md` for choosing, running, and reporting Toastty verification.
  - `docs/agents/automation.md` for smoke, remote, test, and dev-run details.
  - `docs/agents/menu-performance.md` for menu-related regressions and shortcuts.
  - `docs/agents/manual-interaction.md` for background notes on interaction pitfalls.
  - `.agents/skills/toastty-computer-use/SKILL.md` for remote Computer Use GUI debugging and verification beyond smoke-test coverage.

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

Use `.agents/skills/toastty-verify/SKILL.md` as the authoritative workflow for choosing, running, and reporting validation after implementation, build, project, dependency, automation, UI/runtime, menu/shortcut, or agent-instruction changes.

- Keep detailed smoke, remote, test, and local-helper command semantics in `docs/agents/automation.md`.
- Do not probe `TOASTTY_REMOTE_GUI_HOST` outside `sv exec`; remote GUI/test env is injected there.
- In handoffs, say whether validation ran remotely, locally, or through `validate.sh` with local fallback.
- Artifacts are stored in `artifacts/` (gitignored). Manual captures go in `artifacts/manual/`. Committed planning docs belong in `docs/plans/`, not `artifacts/`.

## Dev/Test Runs

- For local dev/debug/test Toastty runs, use an isolated runtime home and per-run filesystem paths.
- Either set `TOASTTY_RUNTIME_HOME` explicitly or set `TOASTTY_DEV_WORKTREE_ROOT` to the repo/worktree root and let Toastty derive a stable runtime home under `artifacts/dev-runs/`.
- Tuist-generated Xcode Run schemes already set `TOASTTY_DEV_WORKTREE_ROOT=$(SRCROOT)` for `ToasttyApp` and `ToasttyApp-Release`. Preserve that behavior when editing `Project.swift`.
- Before a Ghostty-backed build from a fresh worktree, run `./scripts/dev/bootstrap-worktree.sh`. The smoke, shortcut-trace, and check helpers already do this.
- Capture launched app PID and use runtime-specific tooling whenever possible. Avoid generic `osascript` or app-name-only targeting when multiple Toastty instances may be running.
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

- First identify the target being debugged:
  - Production/installed Toastty runs log to `~/Library/Logs/Toastty/toastty.log`.
  - Worktree/Xcode/dev/smoke runs use runtime isolation; resolve `instance.json` in that worktree and read `logFilePath`.
- If the user names a worktree, use that worktree's `artifacts/dev-runs/worktree-*/runtime-home/instance.json`.
- If the target is ambiguous, default to the current worktree's runtime-isolated instance. Look under `artifacts/dev-runs/worktree-*/runtime-home/instance.json`, validate the PID is alive, then read `logFilePath`.
- Only if the current-worktree target is still ambiguous or stale, inspect running Toastty processes with `pgrep -af Toastty` and use `lsof -p <pid>` to find open `toastty.log` paths.
- Xcode `Release` configuration is still a worktree run when launched from the generated scheme; do not treat it as production logging.
- Runtime-isolated logs rotate at 5 MB to `<runtime-home>/logs/toastty.previous.log`; production logs rotate under `~/Library/Logs/Toastty/`.
- Useful env vars: `TOASTTY_LOG_LEVEL`, `TOASTTY_LOG_FILE` (`none` disables), `TOASTTY_LOG_STDERR=1`, `TOASTTY_LOG_DISABLE=1`.

## Menu And Interaction Gotchas

- Read `docs/agents/menu-performance.md` before touching menu rebuilds, hidden system menu items, workspace shortcuts, or `Cmd+W` handling.
- Do not recreate broad `NSMenu` mutation observer refresh loops. Keep menu refresh bounded, coalesced, idempotent, and separate from dynamic bridge reinsertion.
- Menu-advertised `Option+digit` workspace shortcuts are not sufficient by themselves; keep app-level interception for workspace switching.
- Do not retarget native File > Close / Close All slots in place. Prefer Toastty-owned File menu items wired to the same command paths as `Cmd+W` and workspace close.
- For manual GUI reproduction, prefer the remote Computer Use workflow in `.agents/skills/toastty-computer-use/SKILL.md`; `docs/agents/manual-interaction.md` is background context for interaction pitfalls.
