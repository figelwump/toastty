# Ghostty integration notes

Date: 2026-02-27

## Spike status

Status: partially validated (native-target xcframework build succeeds, but current artifact is x86_64-only and not yet integrated into toastty).

## Environment + prerequisites

- `zig` installed via Homebrew: `0.15.2`
- Ghostty source clone used for spike: `/tmp/toastty-ghostty-spike/ghostty`
- Ghostty commit used for spike: `32a9d35c8110a5f528e8c86eaa8128b92ae4d976`

## Build commands exercised

1. `zig build --help` (to confirm relevant build options)
2. `zig build -Demit-macos-app=false -Demit-xcframework=true -Dxcframework-target=native`

Result:
- command completed successfully (exit code `0`)
- generated artifact:
  - `/tmp/toastty-ghostty-spike/ghostty/macos/GhosttyKit.xcframework`

Observed warning (non-fatal):
- `libtool: warning duplicate member name 'ext.o' ...` while producing `libghostty-fat.a`
  - status: unresolved; build succeeded, but warning impact on downstream link behavior has not yet been validated.

Artifact details observed:
- built slice: `macos-x86_64`
- files present:
  - `Info.plist`
  - `Headers/ghostty.h`
  - `Headers/module.modulemap`
  - `libghostty-fat.a`

Impact:
- Ghostty build pipeline is now executable on this machine for the native xcframework target.
- prior hard blocker (`zig` missing) is resolved.
- phase 0 step 1 remains partially incomplete until desired architecture output (`arm64` or universal) is validated and framework wiring is proven in-toastty.
- app integration is still pending: current toastty app continues using placeholder terminal representation.
- built artifact is currently in `/tmp` and is ephemeral; it must be copied to a managed cache/path to persist across reboot/cleanup.

Next actions:
1. verify desired architecture output (`arm64`/universal) and adjust `-Dxcframework-target` / toolchain settings accordingly.
2. copy/cache `GhosttyKit.xcframework` into toastty-managed dependency path.
3. wire a minimal `GhosttySurfaceController` spike in toastty and validate:
   - create + destroy
   - attach + detach from host view
   - focus handoff
   - resize behavior
   - reparent behavior across pane moves
