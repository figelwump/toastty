# Ghostty Integration

Toastty embeds Ghostty through a locally provided `GhosttyKit.xcframework`.

For the broader build, launch, and automation flag reference, see [Environment and Launch Flags](environment-and-build-flags.md).

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

For local Toastty development, `-Dxcframework-target=native` is also acceptable if you only need the macOS slice. `universal` additionally builds the iOS slices.

Why `-Dsentry=false`:

- it prevents the embedded runtime from initializing Ghostty crash reporting inside Toastty
- it keeps Toastty releases local-only by default
- it avoids creating Ghostty Sentry cache data for end users

If you distribute signed Toastty binaries, publish the Ghostty commit and build flags you used for the embedded artifact in your release notes.

The local xcframeworks under `Dependencies/` are intentionally ignored by Git, so the checked-out repo may contain older or differently built local artifacts until they are rebuilt and reinstalled.

The generated artifact is typically:

```text
macos/GhosttyKit.xcframework
```

## Installing a local Ghostty artifact

Install a built artifact into Toastty's local `Dependencies/` directory:

```bash
GHOSTTY_BUILD_FLAGS="-Demit-macos-app=false -Demit-xcframework=true -Dxcframework-target=universal -Dsentry=false" \
GHOSTTY_XCFRAMEWORK_SOURCE=/path/to/GhosttyKit.xcframework \
  ./scripts/ghostty/install-local-xcframework.sh
```

Variant options:

- `GHOSTTY_XCFRAMEWORK_VARIANT=debug`
- `GHOSTTY_XCFRAMEWORK_VARIANT=release`

The installer also auto-detects a sibling checkout at `../ghostty/macos/GhosttyKit.xcframework` when present. If your Ghostty checkout lives elsewhere, set `GHOSTTY_XCFRAMEWORK_SOURCE` explicitly.

When the source path lives inside a Ghostty git checkout, the installer records:

- `GHOSTTY_COMMIT`
- `GHOSTTY_COMMIT_SHORT`
- `GHOSTTY_SOURCE_DIRTY`
- `GHOSTTY_BUILD_FLAGS`

in an ignored sidecar metadata file next to the installed xcframework:

- `Dependencies/GhosttyKit.Debug.metadata.env`
- `Dependencies/GhosttyKit.Release.metadata.env`

Release DMG builds require a complete release sidecar with a clean Ghostty source snapshot (`GHOSTTY_SOURCE_DIRTY=0`) plus non-empty commit and build-flags metadata.

After installing an artifact, regenerate the workspace:

```bash
./scripts/dev/bootstrap-worktree.sh
```

Keeping `Dependencies/` gitignored is intentional. The source repository documents how to build Ghostty, but does not vendor the built binaries.

For a fresh linked Toastty worktree that should reuse an already-installed Ghostty artifact from another Toastty checkout, run:

```bash
./scripts/dev/bootstrap-worktree.sh
```

The helper links ignored `Dependencies/GhosttyKit*` entries into the current worktree when needed, then runs `tuist install` and `tuist generate --no-open`.
Those links are symlinks back to the source Toastty worktree, not copied xcframeworks.

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

On macOS, when Ghostty's `copy-on-select` behavior is enabled by its config or
platform defaults, Toastty routes the Ghostty selection clipboard through a
Toastty-private pasteboard instead of the shared system clipboard. That preserves
Ghostty's selection-paste behavior without overwriting the normal macOS clipboard;
explicit copy actions still target the system clipboard.

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

## Toastty-owned config and settings

- Ghostty `font-size` is the fallback baseline when `~/.toastty/config` does not set `terminal-font-size`
- `~/.toastty/config` is user-authored and can set:
  - `terminal-font-size` as Toastty's preferred baseline
  - `default-terminal-profile` for newly created terminals and ordinary splits only
- `terminal-profiles.toml` defines named launch profiles, optional profile-specific split shortcuts, and startup commands; see [Terminal Profiles](terminal-profiles.md) for the schema and examples
- UI-driven terminal font changes are window-local, persisted in Toastty's workspace layout snapshots, and do not rewrite `~/.toastty/config`
- When runtime isolation is enabled for an isolated dev/test run, Toastty uses the active runtime home's `config`, `terminal-profiles.toml`, and isolated defaults suite instead of the shared user locations
- New windows inherit the source window's current effective terminal font size
- `Reset Terminal Font` clears that window's UI override and returns it to the configured baseline

## Action parity

Ghostty actions currently routed into Toastty app state:

- `new_split:{right,down,left,up}`
- `goto_split:{previous,next,left,right,up,down}`
- `resize_split:{up,down,left,right}`
- `equalize_splits`
- `toggle_split_zoom`
- `start_search`
- `end_search`
- `search_total`
- `search_selected`

Still outside Toastty's current Ghostty action bridge:

- Ghostty font action bindings
- broader tabs, windows, and clipboard parity beyond existing Toastty primitives

## Validation

Recommended validation commands:

```bash
./scripts/automation/check.sh
TUIST_DISABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh
./scripts/automation/smoke-ui.sh
./scripts/automation/shortcut-hints-smoke.sh
```
