# Toastty

## Instruction Scope

- This project file is shared across agent runtimes. Follow the active agent's global instructions for interaction style, review mechanics, and tool availability; the Toastty commands and project constraints here win for this repository.
- When a workflow points at `.agents/skills/.../SKILL.md`, read that file as the authoritative task guide when the task applies. If the active runtime does not load skill files automatically, read the referenced file directly and follow the documented workflow intent.
- Keep this file concise. Detailed workflows and reference material live here:
  - `.agents/skills/toastty-verify/SKILL.md` for choosing, running, and reporting Toastty verification.
  - `.agents/skills/toastty-debug/SKILL.md` for debugging, log discovery, runtime target selection, and focused repro planning.
  - `.agents/skills/toastty-dev-run/SKILL.md` for isolated live dev/debug app instances.
  - `docs/agents/automation.md` for smoke, remote, and xcodebuild test details.
  - `docs/agents/workspace-scope.md` for cooperative workspace-scoped automation semantics and CLI commands.
  - `docs/agents/menu-performance.md` for menu-related regressions and shortcuts.
  - `docs/agents/manual-interaction.md` for background notes on interaction pitfalls.
  - `docs/ghostty-integration.md` for Ghostty artifact, build, config, and validation details.
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

## Live App Runs

Use `.agents/skills/toastty-dev-run/SKILL.md` for live Toastty dev/debug app instances and user-observable runtime checks. For pure unit/integration tests, remote smoke, or remote xcodebuild wrappers, use `.agents/skills/toastty-verify/SKILL.md` and `docs/agents/automation.md`.

- Use runtime isolation and per-run filesystem paths for local dev/debug/test runs.
- Preserve `TOASTTY_DEV_WORKTREE_ROOT=$(SRCROOT)` in the Tuist-generated `ToasttyApp` and `ToasttyApp-Release` Run schemes.
- Treat `instance.json` as authoritative for PID, paths, logs, and socket targeting.

## Release Workflow

- Ghostty release provenance: install release artifacts with `GHOSTTY_BUILD_FLAGS=... ./scripts/ghostty/install-local-xcframework.sh`; the installer writes ignored sidecar metadata under `Dependencies/GhosttyKit.Release.metadata.env`.
- Build release DMG and draft notes: follow `.agents/skills/toastty-release/SKILL.md`. `scripts/release/release.sh` requires a clean Toastty git tree and a clean Ghostty metadata snapshot, then writes `release-metadata.env`, `ghostty-metadata.env`, `sparkle-metadata.env`, and drafted `release-notes.md` into `artifacts/release/<version>-<build>/`.
- Publish later: follow `.agents/skills/toastty-publish/SKILL.md`. It verifies existing drafted notes and release metadata, then runs `scripts/release/publish-github-release.sh --create-tag`.

## Debugging

Use `.agents/skills/toastty-debug/SKILL.md` for debugging, log discovery, runtime target selection, and focused repro planning.

- First identify the target being debugged. Production/installed Toastty logs differ from worktree/Xcode/dev/smoke runtime-isolated logs.
- For worktree, Xcode, dev, or smoke runs, resolve `instance.json` and read its `logFilePath`; do not default to production logs.
- If the target is ambiguous, default to the current worktree's runtime-isolated instance before inspecting broad process lists.

## Specialized References

- Before changing Ghostty artifacts, config loading, host-side terminal styling, or fallback builds, read `docs/ghostty-integration.md`.
- Before touching menu rebuilds, hidden system menu items, workspace shortcuts, terminal jank that may involve AppKit, or `Cmd+W`, read `docs/agents/menu-performance.md`.
- Manual GUI reproduction: prefer `.agents/skills/toastty-computer-use/SKILL.md`; `docs/agents/manual-interaction.md` covers local interaction pitfalls.
