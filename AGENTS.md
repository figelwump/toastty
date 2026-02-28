# Repo Workflow Notes

## Live-App Validation Expectations
- For any UI/runtime change, validate in the running `ToasttyApp`, not only reducer/unit tests.
- Use both paths whenever possible: automation (`./scripts/automation/smoke-ui.sh`) and manual live interaction (launch app, interact, inspect screenshots).
- Primary baseline smoke run: `./scripts/automation/smoke-ui.sh`
- Ghostty-path smoke run: `./scripts/automation/smoke-ui.sh` (Ghostty checks run automatically when `Dependencies/GhosttyKit.xcframework` exists and Ghostty is not disabled via env).
- Explicit fallback smoke run: `TUIST_DISABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh`
- Required ordering when running both paths:
  - run fallback first: `TUIST_DISABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh`
  - run Ghostty-enabled second: `./scripts/automation/smoke-ui.sh`
  - leave workspace generated in Ghostty-enabled mode before handoff: `TUIST_DISABLE_GHOSTTY=0 TOASTTY_DISABLE_GHOSTTY=0 tuist generate`
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
- Ghostty integration is default-on at `tuist generate` time when `Dependencies/GhosttyKit.xcframework` exists.
- Opt out with either `TUIST_DISABLE_GHOSTTY=1` (preferred for Tuist flows) or compatibility alias `TOASTTY_DISABLE_GHOSTTY=1`.
- Ghostty is linked only when both conditions are true: `Dependencies/GhosttyKit.xcframework` exists and disable env var is not set.
- For deterministic fallback builds in CI, set `TUIST_DISABLE_GHOSTTY=1` explicitly.
- When linked, app target adds `TOASTTY_HAS_GHOSTTY_KIT` and Ghostty transitive linker flags from `Project.swift` (`-lc++`, `-framework Carbon`).
- Default generate path falls back automatically when the xcframework is absent or integration is explicitly disabled.
- Install/update local Ghostty artifact: `./scripts/ghostty/install-local-xcframework.sh`
- Optional source override for installer: `GHOSTTY_XCFRAMEWORK_SOURCE=/path/to/GhosttyKit.xcframework ./scripts/ghostty/install-local-xcframework.sh`
- After changing Ghostty artifacts or Ghostty settings, regenerate and rebuild before validating runtime behavior.

## Automation Nuts and Bolts
- `scripts/automation/smoke-ui.sh` builds/runs the app in automation mode, drives socket actions, and emits screenshots/state dumps.
- `scripts/automation/shortcut-trace.sh` drives real keyboard shortcuts through AppKit (`cmd+ctrl+right`, `cmd+ctrl+=`) and verifies:
  - split/focus workflow via real key chords (`cmd+d`, `cmd+shift+d`, `cmd+[`, `cmd+]`) and pane/focus snapshots.
  - split ratio change/equalization via real key chords (`cmd+ctrl+right`, `cmd+ctrl+=`) and `automation.workspace_snapshot`.
  - Ghostty/runtime intent logs in `/tmp/toastty.log`
  - key event forwarding logs (`category=input`).
  - default focus targeting uses coordinates (`CLICK_X=760`, `CLICK_Y=420`); override for different display/window layouts.
- Key smoke env overrides: `RUN_ID`, `FIXTURE`, `DERIVED_PATH`, `ARTIFACTS_DIR`, `SOCKET_PATH`, `ARCH`.
- Shortcut-trace env overrides: `CLICK_X`, `CLICK_Y`, `SPLIT_KEY_CODE`, `FOCUS_NEXT_KEY_CODE`, `FOCUS_PREVIOUS_KEY_CODE`, `RESIZE_KEY_CODE`, `EQUALIZE_KEY_CODE`, `TRACE_LOG_PATH`.
- Readiness file shape: `artifacts/automation/automation-ready-<run-id>.json`
- App log shape: `artifacts/automation/app-<run-id>.log`
- `scripts/automation/check.sh` runs `tuist generate`, `tuist build`, and `xcodebuild test` for scheme `toastty-Workspace` (update the script if scheme naming changes).
- `check.sh` follows manifest defaults: Ghostty links automatically when xcframework is present unless disabled by env.
- split/focus workflow assertions in smoke:
  - `automation.workspace_snapshot` now reports focused panel and pane counts for deterministic assertions.
  - smoke script validates:
    - `workspace.focus-pane.next` changes focus
    - `workspace.focus-pane.previous` restores baseline focus
    - `workspace.split.right` increases pane count
    - `workspace.resize-split.right` increases root split ratio
    - `workspace.equalize-splits` normalizes root split ratio to `0.5`
  - Ghostty terminal viewport I/O assertion is currently best-effort in smoke:
    - if terminal surface remains unavailable in automation mode, smoke logs a note and continues.
- shortcut-trace prerequisites:
  - Accessibility + Automation permissions for `osascript` / `System Events` (for synthetic key chords).
  - Ghostty-enabled build path (`TUIST_DISABLE_GHOSTTY` and `TOASTTY_DISABLE_GHOSTTY` unset).
  - CLI deps: `nc`, `osascript`, `uuidgen` (`jq` optional, used when available for robust JSON parsing).

## Logging and Diagnostics
- App/runtime logging now uses `ToasttyLog` (Core module) with category + level metadata.
- Default log file: `/tmp/toastty.log` (rotates to `/tmp/toastty.previous.log` after 5 MB).
- `/tmp` logging is for local development diagnostics; avoid sharing raw logs without review.
- Tail live logs while reproducing issues:
  - `tail -f /tmp/toastty.log`
  - JSON pretty view: `tail -f /tmp/toastty.log | jq`
- Key env vars:
  - `TOASTTY_LOG_LEVEL=debug|info|warning|error`
  - `TOASTTY_LOG_FILE=/custom/path.log` (set to `none` to disable file sink)
  - `TOASTTY_LOG_STDERR=1` (mirror logs to stderr)
  - `TOASTTY_LOG_DISABLE=1` (disable logging)
- Shortcut/terminal debugging is instrumented across:
  - key event forwarding (`TerminalHostView`)
  - Ghostty action callback routing (`GhosttyRuntimeManager`)
  - runtime action dispatch to reducer (`TerminalRuntimeRegistry`)
  - reducer outcomes for split resize/equalize (`AppReducer`)

## Manual Interaction Scripting Tips
- Activation alone is often insufficient; click into the target terminal panel before typing.
- `System Events` UI scripting requires both macOS Accessibility permission and Automation permission (caller controlling `System Events`).
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
- In the `System Events` process-level `click at {x, y}` pattern, coordinates are absolute screen coordinates.
- For non-US keyboard layouts, clipboard paste is usually more reliable than literal `keystroke`.
- `key code 36` is the hardware key code for Return and is layout-independent.
- Clipboard-based examples overwrite the system clipboard; account for that side effect.

## Daily-Driver QA Checklist
- Run baseline + Ghostty smoke:
  - `TUIST_DISABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh`
  - `./scripts/automation/smoke-ui.sh` (Ghostty path only if xcframework exists and Ghostty is not disabled)
  - finish with `TUIST_DISABLE_GHOSTTY=0 TOASTTY_DISABLE_GHOSTTY=0 tuist generate` so local Xcode builds default to Ghostty-enabled.
- Launch app manually and verify:
  - `cmd+d`, `cmd+shift+d`, `cmd+[`, `cmd+]` on real terminal panes.
  - focused panel toggle (`cmd+shift+f`) round-trip.
  - terminal viewport follows output growth (no stuck scroll position).
- Inspect latest screenshot artifacts before handoff:
  - top bar chrome state, sidebar selection state, pane separators, focused panel border.

## Ghostty Shortcut Parity Snapshot
- currently mapped via Ghostty `action_cb`:
  - `new_split:{right,down,left,up}`
  - `goto_split:{previous,next,left,right,up,down}`
  - `resize_split:{up,down,left,right}`
  - `equalize_splits`
  - `toggle_split_zoom`
- known gaps (deferred):
  - Ghostty font-size actions via callback (`increase_font_size`, `decrease_font_size`, `reset_font_size`)
  - tabs/windows/clipboard action parity beyond current Toastty primitives

## Current Project Snapshot (as of 2026-02-27; verify against current code when in doubt)
- Current local state supports Ghostty-enabled app builds/runs when local xcframework dependency is present (default-on, explicit opt-out available).
- Terminal focus + keyboard bridging is in place; regressions in cursor-follow/scrolling still need manual visual validation.
- Smoke automation currently validates layout actions (split, aux toggles, focused panel, font HUD) and captures artifacts.
- Current automated suite does not yet provide deterministic assertions for Ghostty terminal text I/O and viewport scrolling.
- Ghostty xcframework remains a local dependency (`Dependencies/GhosttyKit.xcframework`), not a fully managed/pinned remote artifact.
