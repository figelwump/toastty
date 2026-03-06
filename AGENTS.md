# Toastty — Agent Workflow Guide

## Reference Architecture
- When solving tricky problems, improving architecture, or looking for good patterns/best practices, consult the Ghostty source at `~/GiantThings/playground/ghostty`. It's a well-architected Swift/macOS codebase and a good source of inspiration for terminal, split-pane, keyboard bridging, and config patterns.

## Build & Generate
- **Source of truth:** `Project.swift` — never hand-edit generated Xcode project/workspace files.
- **Regenerate:** `tuist generate` after any project/dependency/build-setting change, or after source file adds/renames/deletes or branch switches. The generated `.xcodeproj`/`.xcworkspace` are gitignored and never updated by Git, leaving Xcode with stale references (symptom: `Build input file cannot be found`).
- **Build:** `ARCH="$(uname -m)"; xcodebuild -workspace toastty.xcworkspace -scheme ToasttyApp -configuration Debug -destination "platform=macOS,arch=${ARCH}" -derivedDataPath Derived build`
- **Full gate:** `./scripts/automation/check.sh` (generate + build + test)
- If Rosetta is active, set `ARCH` explicitly. Prefer invocation-scoped overrides (`ARCHS`, `ONLY_ACTIVE_ARCH=YES`) over mutating project settings.

## Validation
For any UI/runtime change, validate beyond unit tests — run automation and inspect visually.

**Smoke automation:**
```bash
# Fallback (no Ghostty) first, then Ghostty-enabled
TUIST_DISABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh
./scripts/automation/smoke-ui.sh

# Leave workspace in Ghostty-enabled mode when done
TUIST_DISABLE_GHOSTTY=0 TOASTTY_DISABLE_GHOSTTY=0 tuist generate
```

**Manual QA** (launch app and verify):
- `cmd+d` / `cmd+shift+d` / `cmd+[` / `cmd+]` on real panes
- Focused panel toggle (`cmd+shift+f`) round-trip
- Terminal viewport follows output growth (no stuck scroll)
- Inspect screenshot artifacts: top bar, sidebar, pane separators, focused panel border

**Artifacts:** stored in `artifacts/` (gitignored). Manual captures go in `artifacts/manual/`.

## Ghostty Integration
- **Default-on** when a local xcframework exists in `Dependencies/` and disable env is not set.
- **Opt out:** `TUIST_DISABLE_GHOSTTY=1` (or alias `TOASTTY_DISABLE_GHOSTTY=1`)
- **Install/update artifact:** `./scripts/ghostty/install-local-xcframework.sh`
  - `GHOSTTY_XCFRAMEWORK_VARIANT=release|debug|legacy` to pick variant
  - `GHOSTTY_XCFRAMEWORK_SOURCE=/path/to/GhosttyKit.xcframework` to override source
- **Config loading order:** `TOASTTY_GHOSTTY_CONFIG_PATH` > `$XDG_CONFIG_HOME/ghostty/config` > `~/.config/ghostty/config` > Ghostty defaults.
- **Font override:** `~/.toastty/config` key `terminal-font-size` (cleared by `Reset Terminal Font`).
- **Host-side split styling:** `unfocused-split-opacity`, `unfocused-split-fill` (falls back to Ghostty `background`).
- **Reload config at runtime:** `Toastty -> Reload Configuration` menu item.
- When linked, `Project.swift` adds `TOASTTY_HAS_GHOSTTY_KIT` and linker flags (`-lc++`, `-framework Carbon`).
- After changing artifacts or settings, always regenerate and rebuild before validating.

## Automation Details
- **`smoke-ui.sh`** — builds/runs app in automation mode, drives socket actions, emits screenshots/state dumps.
- **`shortcut-trace.sh`** — drives real keyboard shortcuts via AppKit and verifies split/focus/resize workflows.
  - Requires: Accessibility + Automation permissions, Ghostty-enabled build, `nc`, `osascript`, `uuidgen`.
  - Default focus coordinates: `CLICK_X=760`, `CLICK_Y=420` (override for your display layout).
- **Smoke env:** `RUN_ID`, `FIXTURE`, `DERIVED_PATH`, `ARTIFACTS_DIR`, `SOCKET_PATH`, `ARCH`
- **Shortcut-trace env:** `CLICK_X`, `CLICK_Y`, `SPLIT_KEY_CODE`, `FOCUS_NEXT_KEY_CODE`, `FOCUS_PREVIOUS_KEY_CODE`, `RESIZE_KEY_CODE`, `EQUALIZE_KEY_CODE`, `TRACE_LOG_PATH`

## Logging
- Default log: `/tmp/toastty.log` (rotates at 5 MB to `/tmp/toastty.previous.log`)
- Tail: `tail -f /tmp/toastty.log` (or pipe to `jq` for pretty JSON)
- Env vars: `TOASTTY_LOG_LEVEL`, `TOASTTY_LOG_FILE` (`none` to disable), `TOASTTY_LOG_STDERR=1`, `TOASTTY_LOG_DISABLE=1`
- Key instrumentation points: `TerminalHostView` (key events), `GhosttyRuntimeManager` (action routing), `TerminalRuntimeRegistry` (dispatch), `AppReducer` (split resize/equalize)

## Manual Interaction Scripting
Click into the target terminal panel before typing — activation alone is insufficient.

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
- Coordinates are absolute screen coordinates; adjust per display layout.
- `key code 36` = Return (layout-independent). Clipboard paste is more reliable than `keystroke` for non-US layouts.
- Tune delay values upward if focus races occur.

## Ghostty Shortcut Parity
Currently mapped via `action_cb`: `new_split`, `goto_split`, `resize_split`, `equalize_splits`, `toggle_split_zoom`.

Known gaps (deferred): font-size actions (`increase/decrease/reset_font_size`), tabs/windows/clipboard beyond current Toastty primitives.
