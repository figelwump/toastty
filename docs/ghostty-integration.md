# Ghostty integration notes

Date: 2026-02-27

## Spike status

Status: partially validated (build pipeline proven for native xcframework target).

## Environment + prerequisites

- `zig` installed via Homebrew: `0.15.2`
- Ghostty source clone used for spike: `/tmp/toastty-ghostty-spike/ghostty`

## Build commands exercised

1. `zig build --help` (to confirm relevant build options)
2. `zig build -Demit-macos-app=false -Demit-xcframework=true -Dxcframework-target=native`

Result:
- command completed successfully (exit code `0`)
- generated artifact:
  - `/tmp/toastty-ghostty-spike/ghostty/macos/GhosttyKit.xcframework`

Observed warning (non-fatal):
- `libtool: warning duplicate member name 'ext.o' ...` while producing `libghostty-fat.a`

Artifact details observed:
- built slice: `macos-x86_64`
- files present:
  - `Info.plist`
  - `Headers/ghostty.h`
  - `Headers/module.modulemap`
  - `libghostty-fat.a`

Impact:
- Ghostty build pipeline is now executable on this machine for the native xcframework target.
- phase 0 step 1 is no longer blocked on missing `zig`.
- app integration is still pending: current toastty app continues using placeholder terminal representation.

Next actions:
1. verify desired architecture output (`arm64`/universal) and adjust `-Dxcframework-target` / toolchain settings accordingly.
2. copy/cache `GhosttyKit.xcframework` into toastty-managed dependency path.
3. wire a minimal `GhosttySurfaceController` spike in toastty and validate:
   - create + destroy
   - attach + detach from host view
   - focus handoff
   - resize behavior
   - reparent behavior across pane moves
