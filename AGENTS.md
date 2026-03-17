# Toastty

## Build & Generate
- **Source of truth:** `Project.swift` — never hand-edit generated Xcode project/workspace files.
- **Regenerate:** `tuist generate` after any project/dependency/build-setting change, or after source file adds/renames/deletes or branch switches. The generated `.xcodeproj`/`.xcworkspace` are gitignored and never updated by Git, leaving Xcode with stale references (symptom: `Build input file cannot be found`).
- **Build:** `ARCH="$(uname -m)"; xcodebuild -workspace toastty.xcworkspace -scheme ToasttyApp -configuration Debug -destination "platform=macOS,arch=${ARCH}" -derivedDataPath Derived build`
- **Full gate:** `./scripts/automation/check.sh` (generate + build + test)
- If Rosetta is active, set `ARCH` explicitly. Prefer invocation-scoped overrides (`ARCHS`, `ONLY_ACTIVE_ARCH=YES`) over mutating project settings.

## Release Workflow
- **Ghostty release provenance:** install release artifacts with `GHOSTTY_BUILD_FLAGS=... ./scripts/ghostty/install-local-xcframework.sh`; the installer writes ignored sidecar metadata under `Dependencies/GhosttyKit.Release.metadata.env`.
- **Build release DMG and draft notes:** use `.agents/skills/toastty-release/SKILL.md`. `scripts/release/release.sh` requires a clean Toastty git tree and a clean Ghostty metadata snapshot, then writes `release-metadata.env` and `ghostty-metadata.env` into `artifacts/release/<version>-<build>/`; the release skill drafts `release-notes.md` in that same directory for review before publish.
- **Publish later:** use `.agents/skills/toastty-publish/SKILL.md`. It verifies the existing drafted notes and runs `scripts/release/publish-github-release.sh --create-tag` to tag the recorded release commit and create the GitHub release.

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

**Artifacts:** stored in `artifacts/` (gitignored). Manual captures go in `artifacts/manual/`.
- Committed planning docs belong in `docs/plans/`, not under `artifacts/`.
- For menu validation, target the exact built app instance by PID or full app bundle path. Multiple local `Toastty` builds may be running at once, and generic `osascript` checks can attach to the wrong process.
- Prefer `peekaboo menu list --pid <pid> --json` for menu verification. It is more reliable than generic AppleScript enumeration for nested SwiftUI/AppKit menus.

## Ghostty Integration
- **Default-on** when a local xcframework exists in `Dependencies/` and disable env is not set.
- **Opt out:** `TUIST_DISABLE_GHOSTTY=1` (or alias `TOASTTY_DISABLE_GHOSTTY=1`)
- **Install/update artifact:** `./scripts/ghostty/install-local-xcframework.sh`
  - `GHOSTTY_XCFRAMEWORK_VARIANT=release|debug` to pick variant
  - `GHOSTTY_XCFRAMEWORK_SOURCE=/path/to/GhosttyKit.xcframework` to override source
- **Config loading order:** `TOASTTY_GHOSTTY_CONFIG_PATH` > `$XDG_CONFIG_HOME/ghostty/config` > `~/.config/ghostty/config` > Ghostty defaults.
- **Toastty config:** `~/.toastty/config` stores user-authored defaults such as `terminal-font-size` and `default-terminal-profile`.
- **UI font override:** Toastty remembers menu-driven terminal font changes in `UserDefaults`; `Reset Terminal Font` clears that override and falls back to config or Ghostty baseline.
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
- Default log: `~/Library/Logs/Toastty/toastty.log` (rotates at 5 MB to `toastty.previous.log`)
- Tail: `tail -f ~/Library/Logs/Toastty/toastty.log` (or pipe to `jq` for pretty JSON)
- Env vars: `TOASTTY_LOG_LEVEL`, `TOASTTY_LOG_FILE` (`none` to disable), `TOASTTY_LOG_STDERR=1`, `TOASTTY_LOG_DISABLE=1`
- Key instrumentation points: `TerminalHostView` (key events), `GhosttyRuntimeManager` (action routing), `TerminalRuntimeRegistry` (dispatch), `AppReducer` (split resize/equalize)

## Manual Interaction Scripting
Click into the target terminal panel before typing — activation alone is insufficient.

```bash
osascript <<'OSA'
tell application "Toastty" to activate
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
