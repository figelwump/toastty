# Toastty

## Build & Generate
- **Source of truth:** `Project.swift` — never hand-edit generated Xcode project/workspace files.
- **Install packages:** `tuist install` after cloning and whenever `Tuist/Package.swift` or `Tuist/Package.resolved` changes. Repo scripts do this automatically where needed.
- **Fresh worktree bootstrap:** `./scripts/dev/bootstrap-worktree.sh` links local Ghostty artifacts from another Toastty worktree when needed, then runs `tuist install` and `tuist generate --no-open`.
- **Regenerate:** `tuist generate` after any project/dependency/build-setting change, or after source file adds/renames/deletes or branch switches. The generated `.xcodeproj`/`.xcworkspace` are gitignored and never updated by Git, leaving Xcode with stale references (symptom: `Build input file cannot be found`).
- **Build:** `ARCH="$(uname -m)"; xcodebuild -workspace toastty.xcworkspace -scheme ToasttyApp -configuration Debug -destination "platform=macOS,arch=${ARCH}" -derivedDataPath Derived build`
- **Full gate:** `./scripts/automation/check.sh` (generate + build + test)
- If Rosetta is active, set `ARCH` explicitly. Prefer invocation-scoped overrides (`ARCHS`, `ONLY_ACTIVE_ARCH=YES`) over mutating project settings.

## Release Workflow
- **Ghostty release provenance:** install release artifacts with `GHOSTTY_BUILD_FLAGS=... ./scripts/ghostty/install-local-xcframework.sh`; the installer writes ignored sidecar metadata under `Dependencies/GhosttyKit.Release.metadata.env`.
- **Build release DMG and draft notes:** use `.agents/skills/toastty-release/SKILL.md`. `scripts/release/release.sh` requires a clean Toastty git tree and a clean Ghostty metadata snapshot, then writes `release-metadata.env`, `ghostty-metadata.env`, and `sparkle-metadata.env` into `artifacts/release/<version>-<build>/`; the release skill drafts `release-notes.md` in that same directory for review before publish.
- **Publish later:** use `.agents/skills/toastty-publish/SKILL.md`. It verifies the existing drafted notes and release metadata, then runs `scripts/release/publish-github-release.sh --create-tag` to tag the recorded release commit, create the GitHub release, and update the Sparkle appcast when `--publish` is used.

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
- `scripts/automation/smoke-ui.sh` is the default local runtime-validation path when the change is covered by socket automation. It restores the previously frontmost app after Toastty reaches automation readiness, so prefer it before any foreground-only tooling.
- `scripts/automation/shortcut-hints-smoke.sh` is the preferred local path for visual-only verification of workspace and panel shortcut badges or other always-visible shortcut hints. Use it before any `peekaboo` flow when a static screenshot artifact is enough.
- For live UI validation of a running app instance, use `.agents/skills/toastty-dev-run/SKILL.md` together with the global `peekaboo` skill. Do not invent an ad-hoc launch flow when the skill applies.
- Use `peekaboo` for menus, shortcuts, focus, window state, and visual inspection of a running Toastty instance. Do not use it for build verification, log inspection, or checks that automation/unit tests already cover.
- Before any required local `peekaboo` flow, run `peekaboo permissions --json` and inspect Accessibility. If Accessibility is missing, stop and ask the user to grant it before continuing locally. Do not keep trying local `peekaboo` or invent ad-hoc screenshot/menu workarounds after that failure. If the user does not want to grant local Accessibility, switch to `scripts/remote/gui-validate.sh`.
- If visual validation is taking several minutes or several turns and keeps failing due to flakiness in `peekaboo`, Accessibility, focus, or app targeting, pause instead of grinding indefinitely. Summarize to the user what you already validated, what is flaky or blocked, and the exact remaining manual checks they could perform quickly. Also review why validation took so long and suggest concrete workflow improvements for next time.
- If a validation flow would steal focus locally, prefer `TOASTTY_REMOTE_GUI_HOST=... ./scripts/remote/gui-validate.sh ...` so Peekaboo and shortcut-style checks run on the dedicated remote GUI machine instead of the current desktop.
- For menu validation, target the exact built app instance by PID or full app bundle path. Multiple local `Toastty` builds may be running at once, and generic `osascript` checks can attach to the wrong process.
- Prefer `peekaboo menu list --pid <pid> --json` for menu verification. It is more reliable than generic AppleScript enumeration for nested SwiftUI/AppKit menus.
- For stubborn terminal scroll jitter, cursor jitter, or TUI animation stutter, profile a settled `Release` process with Time Profiler before assuming the hot path is in Ghostty or terminal view code. In March 2026 the real culprit was AppKit menu churn on the main thread, not terminal rendering.
- When reading Time Profiler for terminal jank, inspect menu/AppKit stacks too. Hot frames in `HiddenSystemMenuItemsBridge`, dynamic menu bridges, `NSMenu`, `NSMenuItem`, `ICUCatalog`, or other menu validation/rendering paths can starve terminal redraws and input handling.

## Dev/Test Runs
- For any local dev/debug/test Toastty run, use an isolated runtime home and per-run filesystem paths. Treat PID, bundle path, and per-run directories as required targeting data, not optional bookkeeping.
- For terminal or agent-driven dev runs, either set `TOASTTY_RUNTIME_HOME` explicitly or set `TOASTTY_DEV_WORKTREE_ROOT` to the repo/worktree root and let Toastty derive a stable runtime home under `artifacts/dev-runs/`.
- Tuist-generated Xcode Run schemes already set `TOASTTY_DEV_WORKTREE_ROOT=$(SRCROOT)` for `ToasttyApp` and `ToasttyApp-Release`. Keep that behavior when editing `Project.swift`.
- Before a Ghostty-backed build from a fresh worktree, run `./scripts/dev/bootstrap-worktree.sh`. The smoke, shortcut-trace, and check helpers already do this for you.
- The automation helpers now default to `artifacts/dev-runs/<RUN_ID>/...` and set unique `TOASTTY_RUNTIME_HOME`, `DERIVED_PATH`, `ARTIFACTS_DIR`, and `SOCKET_PATH` for each run. Follow the same pattern for any custom launch flow.
- For `shortcut-trace.sh` or other trace-style runs, also use a unique `TRACE_LOG_PATH` per instance instead of a shared log path.
- For remote GUI validation, use `scripts/remote/gui-validate.sh` with `TOASTTY_REMOTE_GUI_HOST`. It creates a disposable remote worktree, syncs the requested change scope into it, launches an isolated instance there, runs the remote validation command, and copies the artifacts back into `artifacts/remote-gui/<run-label>/`.
- Capture the launched app PID and use PID-targeted tooling for validation whenever possible. Prefer `peekaboo ... --pid <pid>` and avoid generic `osascript` or app-name-only targeting when more than one Toastty instance may be running.
- When runtime isolation is enabled, Toastty writes `instance.json` inside that runtime home. Use it to find the exact sandbox, log path, socket path, derived path, and worktree root for the running instance you launched.
- For Xcode-launched Toastty runs, assume runtime isolation is active unless you have evidence otherwise. Start debugging from `artifacts/dev-runs/worktree-*/runtime-home/instance.json`, and use its `logFilePath`, `runtimeHomePath`, `bundlePath`, and `pid` as the source of truth before checking global defaults under `~/Library/Logs/Toastty/`.
- Before any `peekaboo` call, get the PID from `instance.json` and confirm it is still alive. If the PID is stale, relaunch instead of guessing.
- Shell integration installation is intentionally disabled when runtime isolation is enabled. Sandboxed dev/test runs must not rewrite the user's login shell files.
- When a run is finished, clean up only its own per-run directories. Use `./scripts/automation/cleanup-dev-runs.sh` for stale run cleanup, and never delete paths for a still-running PID.

## Ghostty Integration
- **Default-on** when a local xcframework exists in `Dependencies/` and disable env is not set.
- **Opt out:** `TUIST_DISABLE_GHOSTTY=1` (or alias `TOASTTY_DISABLE_GHOSTTY=1`)
- **Install/update artifact:** `./scripts/ghostty/install-local-xcframework.sh`
- **Bootstrap a fresh worktree:** `./scripts/dev/bootstrap-worktree.sh`
  - `GHOSTTY_XCFRAMEWORK_VARIANT=release|debug` to pick variant
  - `GHOSTTY_XCFRAMEWORK_SOURCE=/path/to/GhosttyKit.xcframework` to override source
- **Config loading order:** `TOASTTY_GHOSTTY_CONFIG_PATH` > `$XDG_CONFIG_HOME/ghostty/config` > `~/.config/ghostty/config` > Ghostty defaults.
- **Toastty config:** `~/.toastty/config` stores user-authored defaults such as `terminal-font-size` and `default-terminal-profile`.
- **UI font override:** Toastty remembers menu-driven terminal font changes per window in persisted layout state; `Reset Terminal Font` clears that window-local override and falls back to config or Ghostty baseline. Runtime-isolated dev/test runs persist that state inside the isolated runtime home.
- **Host-side split styling:** `unfocused-split-opacity`, `unfocused-split-fill` (falls back to Ghostty `background`).
- **Reload config at runtime:** `Toastty -> Reload Configuration` menu item.
- When linked, `Project.swift` adds `TOASTTY_HAS_GHOSTTY_KIT` and linker flags (`-lc++`, `-framework Carbon`).
- After changing artifacts or settings, always regenerate and rebuild before validating.

## Automation Details
- **`smoke-ui.sh`** — builds/runs app in automation mode, drives socket actions, emits screenshots/state dumps, and restores the previously frontmost app after Toastty is ready so local smoke runs minimize focus theft.
- **`shortcut-hints-smoke.sh`** — builds/runs app in automation mode, captures a single screenshot focused on visible shortcut hints, emits a matching state dump, and restores the previously frontmost app after Toastty is ready. Use this for badge/hint verification before considering `peekaboo`.
- **`shortcut-trace.sh`** — drives real keyboard shortcuts via AppKit and verifies split/focus/resize workflows.
  - Requires: Accessibility + Automation permissions, Ghostty-enabled build, `nc`, `osascript`, `uuidgen`.
  - Default focus coordinates: `CLICK_X=760`, `CLICK_Y=420` (override for your display layout).
- **`gui-validate.sh`** — runs foreground-capable GUI validation on a remote macOS host over SSH, then copies the remote artifacts back locally.
- **Smoke env:** `RUN_ID`, `DEV_RUN_ROOT`, `TOASTTY_RUNTIME_HOME`, `DERIVED_PATH`, `ARTIFACTS_DIR`, `SOCKET_PATH`, `ARCH`
- **Shortcut-hints env:** `RUN_ID`, `FIXTURE`, `DEV_RUN_ROOT`, `TOASTTY_RUNTIME_HOME`, `DERIVED_PATH`, `ARTIFACTS_DIR`, `SOCKET_PATH`, `ARCH`, `TOASTTY_SHORTCUT_HINTS_RESTORE_FRONT_APP`
- **Shortcut-trace env:** `RUN_ID`, `DEV_RUN_ROOT`, `TOASTTY_RUNTIME_HOME`, `DERIVED_PATH`, `ARTIFACTS_DIR`, `SOCKET_PATH`, `CLICK_X`, `CLICK_Y`, `SPLIT_KEY_CODE`, `FOCUS_NEXT_KEY_CODE`, `FOCUS_PREVIOUS_KEY_CODE`, `RESIZE_KEY_CODE`, `EQUALIZE_KEY_CODE`, `TRACE_LOG_PATH`
- **Remote GUI env:** `TOASTTY_REMOTE_GUI_HOST`, `TOASTTY_REMOTE_GUI_REPO_ROOT`, `TOASTTY_REMOTE_GUI_ROOT`
- **Manual/Xcode env:** `TOASTTY_RUNTIME_HOME` or `TOASTTY_DEV_WORKTREE_ROOT`, plus `TOASTTY_SOCKET_PATH` if you need a specific socket path

## Logging
- Default log: `~/Library/Logs/Toastty/toastty.log` for ordinary runs, or `<runtime-home>/logs/toastty.log` when runtime isolation is enabled (rotates at 5 MB to `toastty.previous.log`)
- For debugging a specific dev/Xcode instance, resolve `instance.json` first and read `logFilePath` from there instead of guessing between the global log and a per-run log. Treat `instance.json` as authoritative for the active run's log, runtime home, socket path, and bundle path.
- Tail: `tail -f ~/Library/Logs/Toastty/toastty.log` or `tail -f "<runtime-home>/logs/toastty.log"` (pipe to `jq` for pretty JSON)
- Env vars: `TOASTTY_LOG_LEVEL`, `TOASTTY_LOG_FILE` (`none` to disable), `TOASTTY_LOG_STDERR=1`, `TOASTTY_LOG_DISABLE=1`
- Key instrumentation points: `TerminalHostView` (key events), `GhosttyRuntimeManager` (action routing), `TerminalRuntimeRegistry` (dispatch), `AppReducer` (split resize/equalize)

## Menu Performance Gotchas
- A March 2026 regression came from `HiddenSystemMenuItemsBridge` observing `NSMenu.didAddItem`, `didChangeItem`, `didRemoveItem`, and `didBeginTracking`, then recursively refreshing the whole menu tree and reinstalling dynamic bridges. That main-thread AppKit work caused visible terminal scroll/cursor/TUI stutter. Do not recreate that pattern.
- Treat `NSMenu` mutation notifications as high-risk. Do not synchronously perform whole-tree refreshes plus dynamic bridge reinsertion from those observers. If a notification path is needed, keep it bounded, coalesced, and idempotent.
- Keep hidden-item refresh separate from dynamic menu bridge reinstall. Mutation notifications may refresh delegate/visibility state, but dynamic bridge reinsertion should stay on explicit user-driven boundaries such as top-level menu open, not every menu mutation.
- If a menu refresh path mutates menu items, assume it can trigger more menu notifications. Guard against recursive feedback loops and avoid wiring refresh callbacks that immediately re-mutate the same tree.
- If hidden system menu items regress after a programmatic menu rebuild, do not revive the global observer pattern from `04ee174`. Prefer a bounded fix scoped to the opened menu or another non-observer path, even if the narrower fix needs separate follow-up work.
- Preserve targeted tests for menu rebuild behavior when touching this area: hidden system items stay hidden after rebuild, and dynamic bridges still reattach where needed, without restoring a global recursive refresh loop.
- In Toastty, menu-advertised `⌥digit` workspace shortcuts are not sufficient by themselves. The embedded terminal's key handling can consume those events before the menu-based workspace switch path runs reliably, so keep app-level interception for workspace switching even if the menu also shows the shortcut.
- Do not retarget the native File > Close / Close All slots in place. AppKit can bypass or rebuild those standard menu items in ways that diverge from Toastty's panel/workspace close behavior. Prefer Toastty-owned File menu items wired directly to the same command paths as `Cmd+W` and workspace close.
- In Toastty, a retargeted File > Close Panel menu item is not sufficient by itself to own `Cmd+W`. AppKit can bypass that menu item and invoke native window close directly, so `Cmd+W` should stay app-owned in the local shortcut interceptor rather than depending on the menu item's key equivalent.
- The app-owned `Cmd+W` path must stay conservative: do not reclaim it from modal windows, sheet-backed windows, or active text-input responders. If those guards regress, AppKit starts stealing closes in some paths and Toastty starts stealing them in others.

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
