# Sidebar session hover diagnostics

Use this temporary trace when entering a session row produces neither its highlight nor its hover card. It records existing hover decisions without changing them. It does not diagnose tooltip-only dismissal.

## Enable for a reproduction

Build the branch containing this patch. From its already-bootstrapped worktree, this local command compiles the Debug app into `Derived` without launching or replacing the installed app:

```bash
xcodebuild -workspace toastty.xcworkspace -scheme ToasttyApp \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath Derived build
```

The diagnostic flag is read once per process; changing it requires relaunching.

For an already-built local Debug app, this command launches a separate worktree-isolated instance and writes its runtime data under this worktree's `artifacts/dev-runs/` (it does not replace the installed app):

```bash
TOASTTY_SIDEBAR_HOVER_DIAGNOSTICS=1 \
TOASTTY_LOG_LEVEL=info \
TOASTTY_DEV_WORKTREE_ROOT="$PWD" \
TOASTTY_DERIVED_PATH="$PWD/Derived" \
"$PWD/Derived/Build/Products/Debug/Toastty.app/Contents/MacOS/Toastty"
```

Use the actual build path if DerivedData is elsewhere. Leave `TOASTTY_LOG_DISABLE` unset and do not set `TOASTTY_LOG_FILE=none`. The trace uses the normal info-level log; enabling debug verbosity is unnecessary.

Resolve `artifacts/dev-runs/worktree-*/runtime-home/instance.json` for the running instance and read its `logFilePath`. That file is authoritative, including when the log path was overridden. Filter that log for the exact message `sidebar hover diagnostic`; include its `.previous.log` sibling if rotation occurred. For example, this read-only command prints matching entries from an explicitly resolved path:

```bash
rg '"message":"sidebar hover diagnostic"' /absolute/path/from/instance.json/toastty.log
```

When it fails, note the approximate time and row, pause briefly with the pointer still inside, then leave and re-enter. Keep both the failed entry and successful recovery in the capture. Avoid clearing logs before collecting them.

## Interpret the trace

- `row-configured`, `view-did-move-to-window`, and `tracking-area-updated` identify native view lifetimes and tracking rebuilds. `viewID` identifies one native view, while workspace/session/panel IDs identify its row. `trackingGeneration` increments on each rebuild. Tracking-area options/registration and row bounds in window coordinates help inspect stale geometry; the area uses `inVisibleRect`, so its zero rect is expected.
- `mouse-entered` / `mouse-exited` record the incoming event, its location and timestamp, the current pointer position, and whether its tracking area matches the currently installed area. Stored `pointerInside` is the value before handling the event. The tracking-area comparison is omitted for synthetic non-tracking events used by host tests.
- `callback-forwarded` records the new native state. `callback-suppressed-unchanged` means the native view already stored that state. Check `callbackInstalled` before assuming a callback was delivered.
- `sidebar-hover-accepted` / `sidebar-hover-ignored` record the incoming state and the sidebar's previous/resulting hovered panel. A late exit from a different panel can be accepted without clearing the current panel. `changed` distinguishes a state change from a no-op. Drag flags are recorded as context, not a presumed cause.
- `sidebar-hover-cleared` records explicit clearing during drag activation. `invalidate`, `teardown-hover-check`, and `teardown-callback-forwarded` identify removal-driven clears.

Correlate entries by window, row, native view, and order. A native entry with no forwarded callback differs from a forwarded callback ignored by the sidebar, or a successful entry immediately followed by teardown/exit. A rebuild with the pointer inside but `pointerInside=false` is evidence to investigate; it does not alone prove a lost AppKit event. Without a native entry or nearby lifecycle event, this trace cannot independently prove that the pointer crossed the row.

The trace logs identifiers, geometry, and state, not session names, prompts, or terminal content. It does not log every mouse movement. Rebuild-heavy sessions can still produce substantial output and logging may affect timing; enable it only for a focused reproduction. Disable it by removing the flag and relaunching. Once the failure is understood, remove this temporary instrumentation and document the confirmed fix.
