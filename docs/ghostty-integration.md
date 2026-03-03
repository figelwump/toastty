# Ghostty integration notes

Date: 2026-02-27

## Spike status

Status: partially validated (xcframework build succeeds for both native and universal targets; runtime integration in toastty still pending).

## Environment + prerequisites

- `zig` installed via Homebrew: `0.15.2`
- Ghostty source clone used for spike: `/tmp/toastty-ghostty-spike/ghostty`
- Ghostty commit used for spike: `32a9d35c8110a5f528e8c86eaa8128b92ae4d976`

## Build commands exercised

1. `zig build --help` (to confirm relevant build options)
2. `zig build -Demit-macos-app=false -Demit-xcframework=true -Dxcframework-target=native`
3. `zig build -Demit-macos-app=false -Demit-xcframework=true -Dxcframework-target=universal`

Result:
- command completed successfully (exit code `0`)
- generated artifact:
  - `/tmp/toastty-ghostty-spike/ghostty/macos/GhosttyKit.xcframework`
  - note: native and universal builds write to the same output path; the later universal build output is the artifact currently present.

Observed warning (non-fatal):
- `libtool: warning duplicate member name 'ext.o' ...` while producing `libghostty-fat.a`
  - warning reproduced in both native and universal builds.
  - status: unresolved; build succeeded, but warning impact on downstream link behavior has not yet been validated.

Artifact details observed:
- built slices:
  - `macos-arm64_x86_64`
  - `ios-arm64`
  - `ios-arm64-simulator`
  - iOS slices appear as part of Ghostty's universal xcframework output; toastty's macOS integration path currently only needs the macOS slice.
- files present:
  - `Info.plist`
  - `macos-arm64_x86_64/libghostty.a`
  - `ios-arm64/libghostty-fat.a`
  - `ios-arm64-simulator/libghostty-fat.a`
  - per-slice headers:
    - `Headers/ghostty.h`
    - `Headers/module.modulemap`

Impact:
- Ghostty build pipeline is now executable on this machine for the native xcframework target.
- prior hard blocker (`zig` missing) is resolved.
- phase 0 step 1 remains partially incomplete until framework wiring is proven in-toastty (surface lifecycle integration and runtime movement).
- app integration is still pending: current toastty app continues using placeholder terminal representation.
- built artifact is currently in `/tmp` and is ephemeral; it must be copied to a managed cache/path to persist across reboot/cleanup.

Next actions:
1. copy/cache `GhosttyKit.xcframework` into toastty-managed dependency path (artifact is currently under `/tmp`).
2. wire a minimal `GhosttySurfaceController` spike in toastty and validate:
   - create + destroy
   - attach + detach from host view
   - focus handoff
   - resize behavior
   - reparent behavior across pane moves

## Toastty manifest wiring notes

- Ghostty linking in `Project.swift` is default-on when at least one local Ghostty xcframework artifact exists:
  - `Dependencies/GhosttyKit.Debug.xcframework`
  - `Dependencies/GhosttyKit.Release.xcframework`
  - `Dependencies/GhosttyKit.xcframework` (legacy fallback)
- Disable linking explicitly with `TUIST_DISABLE_GHOSTTY=1` (preferred for Tuist flows) or compatibility alias `TOASTTY_DISABLE_GHOSTTY=1`.
  - after generate, verify `TOASTTY_HAS_GHOSTTY_KIT` appears in `SWIFT_ACTIVE_COMPILATION_CONDITIONS` for `ToasttyApp` when Ghostty is enabled.
- Current local integration status:
  - when available, `Debug` builds prefer `GhosttyKit.Debug.xcframework` and `Release` builds prefer `GhosttyKit.Release.xcframework`.
  - per-config fallback order is:
    - `Debug`: `GhosttyKit.Debug` -> `GhosttyKit` (legacy) -> `GhosttyKit.Release`
    - `Release`: `GhosttyKit.Release` -> `GhosttyKit` (legacy) -> `GhosttyKit.Debug`
  - manifest resolves the first matching macOS slice from:
    - `macos-arm64_x86_64`
    - `macos-arm64`
    - `macos-x86_64`
  - app target must add Ghostty transitive linker flags:
    - `-lc++`
    - `-framework Carbon`
  - with those flags in `Project.swift`, Ghostty-enabled app builds now succeed via:
    - `tuist generate` (with xcframework present and Ghostty not disabled)
    - `xcodebuild -workspace toastty.xcworkspace -scheme ToasttyApp -configuration Debug -destination "platform=macOS,arch=arm64" -derivedDataPath Derived build`
  - automation smoke currently exercises the Ghostty viewport path by default when the xcframework is present.
    - run: `./scripts/automation/smoke-ui.sh`
    - fallback verification: `TUIST_DISABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh`
  - generate path falls back automatically (no Ghostty compile condition) when the xcframework is absent or integration is disabled.

### Installing local Ghostty artifacts

- Default installer behavior now targets the Debug variant:
  - `./scripts/ghostty/install-local-xcframework.sh`
- Install a Release variant:
  - `GHOSTTY_XCFRAMEWORK_VARIANT=release ./scripts/ghostty/install-local-xcframework.sh`
- Install legacy single-path artifact (fallback mode):
  - `GHOSTTY_XCFRAMEWORK_VARIANT=legacy ./scripts/ghostty/install-local-xcframework.sh`
- Optional source override for all modes:
  - `GHOSTTY_XCFRAMEWORK_SOURCE=/path/to/GhosttyKit.xcframework ./scripts/ghostty/install-local-xcframework.sh`

## Current action parity (MVP snapshot)

- supported Ghostty actions routed into app state:
  - `new_split:{right,down,left,up}` -> directional pane split
  - `goto_split:{previous,next,left,right,up,down}` -> pane focus movement
  - `resize_split:{up,down,left,right}` -> focused split ratio adjustment
  - `equalize_splits` -> normalize split ratios
  - `toggle_split_zoom` -> focused-panel mode toggle
- currently deferred / not yet mapped:
  - Ghostty font action bindings (`increase_font_size`, `decrease_font_size`, `reset_font_size`)
  - broader tabs/windows/clipboard parity beyond existing Toastty primitives

## Embedded config loading behavior

- Toastty now resolves Ghostty config in this order:
  - `TOASTTY_GHOSTTY_CONFIG_PATH` (if set and path exists)
  - `$XDG_CONFIG_HOME/ghostty/config` (if present)
  - `~/.config/ghostty/config` (if present)
  - Ghostty default search paths via `ghostty_config_load_default_files`
- Recursive Ghostty config includes are loaded via `ghostty_config_load_recursive_files`.
- Startup logs now include:
  - which source was used (`env_path`, `user_path`, `default_files`)
  - diagnostic count and each diagnostic message (when present)
- Embedded runtime skips `ghostty_config_load_cli_args` by default, preventing false Ghostty diagnostics for app-specific args (for example automation flags).
- Optional override: set `TOASTTY_GHOSTTY_PARSE_CLI_ARGS=1` to restore Ghostty CLI arg parsing behavior.

## Host-side config keys currently applied

- `unfocused-split-opacity`
  - read via `ghostty_config_get`
  - applied in Toastty pane rendering as overlay alpha `1 - config_value` on unfocused terminal panes
- `unfocused-split-fill`
  - read via `ghostty_config_get`
  - when unset, falls back to Ghostty `background` color
  - used as the overlay color for unfocused terminal panes
- `font-size`
  - read via `ghostty_config_get`
  - used as Toastty’s baseline terminal font size when no Toastty-specific override is present

## Terminal font preference behavior

- Baseline source: Ghostty `font-size` from loaded Ghostty config.
- Toastty user override source: `~/.toastty/config` key `terminal-font-size`.
- Legacy Toastty path `~/.config/toastty/config` is auto-migrated to `~/.toastty/config` on launch.
- Runtime behavior:
  - `Increase/Decrease Terminal Font` adjusts current font size and persists `terminal-font-size`.
  - Toastty keeps the persisted override until `Reset Terminal Font` is used (it does not auto-clear when value matches baseline).
  - `Reset Terminal Font` clears Toastty override and returns to Ghostty `font-size` baseline.
  - `Reload Configuration` updates Ghostty baseline; if Toastty override is not set, current terminal font follows the new baseline.

## Manual reload entrypoint

- App menu entry: `Toastty -> Reload Configuration`
- Behavior:
  - re-loads Ghostty config using Toastty’s embedded config resolution order
  - applies config via `ghostty_app_update_config`
  - re-applies host-side unfocused split style keys
