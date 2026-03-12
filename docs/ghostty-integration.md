# Ghostty Integration

Toastty embeds Ghostty through a locally provided `GhosttyKit.xcframework`.

The repository intentionally does not commit Ghostty binaries. Contributors can:

- build their own Ghostty xcframework from an upstream Ghostty checkout, or
- build Toastty in fallback mode without Ghostty by setting `TUIST_DISABLE_GHOSTTY=1`

## Recommended Ghostty build

From an upstream Ghostty checkout:

```bash
zig build \
  -Demit-macos-app=false \
  -Demit-xcframework=true \
  -Dxcframework-target=universal \
  -Dsentry=false
```

Why `-Dsentry=false`:

- it prevents the embedded runtime from initializing Ghostty crash reporting inside Toastty
- it keeps Toastty releases local-only by default
- it avoids creating Ghostty Sentry cache data for end users

If you distribute signed Toastty binaries, publish the Ghostty commit and build flags you used for the embedded artifact in your release notes.

The generated artifact is typically:

```text
macos/GhosttyKit.xcframework
```

## Installing a local Ghostty artifact

Install a built artifact into Toastty's local `Dependencies/` directory:

```bash
GHOSTTY_XCFRAMEWORK_SOURCE=/path/to/GhosttyKit.xcframework \
  ./scripts/ghostty/install-local-xcframework.sh
```

Variant options:

- `GHOSTTY_XCFRAMEWORK_VARIANT=debug`
- `GHOSTTY_XCFRAMEWORK_VARIANT=release`

The installer also auto-detects a sibling checkout at `../ghostty/macos/GhosttyKit.xcframework` when present.

After installing an artifact, regenerate the workspace:

```bash
tuist generate
```

Keeping `Dependencies/` gitignored is intentional. The source repository should document the Ghostty build, not vendor the built binaries.

## Toastty build behavior

Ghostty integration in `Project.swift` is default-on when at least one local artifact exists:

- `Dependencies/GhosttyKit.Debug.xcframework`
- `Dependencies/GhosttyKit.Release.xcframework`

Disable it explicitly with:

```bash
TUIST_DISABLE_GHOSTTY=1 tuist generate
```

Current selection behavior:

- `Debug` prefers `GhosttyKit.Debug`, then `GhosttyKit.Release`
- `Release` prefers `GhosttyKit.Release`, then `GhosttyKit.Debug`
- Toastty resolves the first matching macOS slice from:
  - `macos-arm64_x86_64`
  - `macos-arm64`
  - `macos-x86_64`

When Ghostty is enabled, Toastty adds:

- `TOASTTY_HAS_GHOSTTY_KIT`
- `-lc++`
- `-framework Carbon`

## Runtime config loading

Toastty resolves Ghostty config in this order:

1. `TOASTTY_GHOSTTY_CONFIG_PATH`
2. `$XDG_CONFIG_HOME/ghostty/config`
3. `~/.config/ghostty/config`
4. Ghostty default search paths

Recursive includes are loaded through Ghostty's normal recursive config loading.

By default Toastty does not ask Ghostty to parse Toastty's own CLI args. To re-enable that behavior:

```bash
TOASTTY_GHOSTTY_PARSE_CLI_ARGS=1
```

## Host-side config keys

Toastty reads these additional keys from Ghostty config:

- `unfocused-split-opacity`
  - applied as overlay alpha on unfocused terminal panes
- `unfocused-split-fill`
  - overlay color for unfocused terminal panes
  - falls back to Ghostty `background` when unset
- `font-size`
  - baseline terminal font size when no Toastty override is present

## Toastty-owned terminal font preference

- Ghostty `font-size` is the baseline
- Toastty persists user overrides in `~/.toastty/config` under `terminal-font-size`
- `Reset Terminal Font` clears the Toastty override and returns to the Ghostty baseline

## Action parity

Ghostty actions currently routed into Toastty app state:

- `new_split:{right,down,left,up}`
- `goto_split:{previous,next,left,right,up,down}`
- `resize_split:{up,down,left,right}`
- `equalize_splits`
- `toggle_split_zoom`

Still outside Toastty's current Ghostty action bridge:

- Ghostty font action bindings
- broader tabs, windows, and clipboard parity beyond existing Toastty primitives

## Validation

Recommended validation commands:

```bash
./scripts/automation/check.sh
TUIST_DISABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh
./scripts/automation/smoke-ui.sh
```
