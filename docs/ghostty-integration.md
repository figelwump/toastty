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

Observed warning (non-fatal):
- `libtool: warning duplicate member name 'ext.o' ...` while producing `libghostty-fat.a`
  - status: unresolved; build succeeded, but warning impact on downstream link behavior has not yet been validated.

Artifact details observed:
- built slices:
  - `macos-arm64_x86_64`
  - `ios-arm64`
  - `ios-arm64-simulator`
- files present:
  - `Info.plist`
  - per-slice `Headers/ghostty.h`
  - per-slice `Headers/module.modulemap`
  - per-slice `libghostty-fat.a` or `libghostty.a`

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
