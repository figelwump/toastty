# Repo Workflow Notes

## Live-App Validation Expectations
- For any UI/runtime change, validate in the running `ToasttyApp`, not only reducer/unit tests.
- Use both paths whenever possible: automation (`./scripts/automation/smoke-ui.sh`) and manual live interaction (launch app, interact, inspect screenshots).
- Primary baseline smoke run: `./scripts/automation/smoke-ui.sh`
- Ghostty-path smoke run: `TUIST_ENABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh` (effective only when `Dependencies/GhosttyKit.xcframework` exists).
- For Ghostty-related runtime changes, run both baseline smoke and Ghostty-path smoke before considering validation complete.
- Full build/test gate: `./scripts/automation/check.sh`
- Store manual validation captures in `artifacts/manual/`; `artifacts/` is gitignored and should stay uncommitted.
- After scripted interaction, inspect screenshot artifacts to confirm focus, prompt position, scrolling, and layout behavior.

## Tuist Day-to-Day (Generate, Build, Settings)
- `Project.swift` is the source of truth for targets, dependencies, and build settings.
- Do not hand-edit generated Xcode project/workspace files; regenerate from `Project.swift`.
- Regenerate after project/dependency/build-setting changes: `tuist generate`
- Generated workspace path: `toastty.xcworkspace`
- Deterministic app build command: `ARCH="$(uname -m)"; xcodebuild -workspace toastty.xcworkspace -scheme ToasttyApp -configuration Debug -destination "platform=macOS,arch=${ARCH}" -derivedDataPath Derived build`
- If the shell process runs under Rosetta, `uname -m` typically reports `x86_64`; set `ARCH` explicitly when needed.
- If scheme settings constrain architectures, prefer invocation-scoped overrides (for example `ARCHS="${ARCH}"` and `ONLY_ACTIVE_ARCH=YES`) instead of mutating project settings.

## Ghostty Configuration Nuts and Bolts
- Ghostty integration is opt-in at `tuist generate` time.
- Enable with: `TUIST_ENABLE_GHOSTTY=1 tuist generate`
- `Project.swift` checks both `TUIST_ENABLE_GHOSTTY` and `TOASTTY_ENABLE_GHOSTTY`, but for `tuist generate` flows rely on `TUIST_ENABLE_GHOSTTY=1`.
- Ghostty is linked only when both conditions are true: gate env var is set and `Dependencies/GhosttyKit.xcframework` exists.
- When linked, app target adds `TOASTTY_HAS_GHOSTTY_KIT` and Ghostty transitive linker flags from `Project.swift` (`-lc++`, `-framework Carbon`).
- Default generate path (without Ghostty gate) stays on fallback terminal runtime for stability.
- Install/update local Ghostty artifact: `./scripts/ghostty/install-local-xcframework.sh`
- Optional source override for installer: `GHOSTTY_XCFRAMEWORK_SOURCE=/path/to/GhosttyKit.xcframework ./scripts/ghostty/install-local-xcframework.sh`
- After changing Ghostty artifacts or Ghostty settings, regenerate and rebuild before validating runtime behavior.

## Automation Nuts and Bolts
- `scripts/automation/smoke-ui.sh` builds/runs the app in automation mode, drives socket actions, and emits screenshots/state dumps.
- Key smoke env overrides: `RUN_ID`, `FIXTURE`, `DERIVED_PATH`, `ARTIFACTS_DIR`, `SOCKET_PATH`, `ARCH`.
- Readiness file shape: `artifacts/automation/automation-ready-<run-id>.json`
- App log shape: `artifacts/automation/app-<run-id>.log`
- `scripts/automation/check.sh` runs `tuist generate`, `tuist build`, and `xcodebuild test` for scheme `toastty-Workspace` (update the script if scheme naming changes).
- `check.sh` does not force Ghostty; use `TUIST_ENABLE_GHOSTTY=1` and ensure `Dependencies/GhosttyKit.xcframework` exists when you need Ghostty-linked coverage.

## Manual Interaction Scripting Tips
- Activation alone is often insufficient; click into the target terminal panel before typing.
- Coordinate clicks are machine/layout specific; adjust coordinates per active display/window layout.
- Example robust sequence (single AppleScript block with explicit ordering/delay):
```bash
osascript <<'OSA'
tell application "ToasttyApp" to activate
delay 0.5
tell application "System Events"
  click at {720, 360}
  delay 0.2
  keystroke "ls -l"
  key code 36
end tell
OSA
```
- Delay values are machine/load dependent; tune upward if activation/focus races still occur.
- For non-US keyboard layouts, clipboard paste is usually more reliable than literal `keystroke`.
- Clipboard-based examples overwrite the system clipboard; account for that side effect.

## Current Project Snapshot (as of 2026-02-27; verify against current code when in doubt)
- Current local state supports Ghostty-enabled app builds/runs when opt-in gating and local xcframework dependency are present.
- Terminal focus + keyboard bridging is in place; regressions in cursor-follow/scrolling still need manual visual validation.
- Smoke automation currently validates layout actions (split, aux toggles, focused panel, font HUD) and captures artifacts.
- Current automated suite does not yet provide deterministic assertions for Ghostty terminal text I/O and viewport scrolling.
- Ghostty xcframework remains a local dependency (`Dependencies/GhosttyKit.xcframework`), not a fully managed/pinned remote artifact.
