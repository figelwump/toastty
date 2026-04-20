# Building and Releasing

This guide covers building Toastty from source, running validation, and producing signed release DMGs.

## Requirements

- macOS 14.0+
- [Tuist](https://tuist.io) (build system)
- Xcode 16+ with Swift 6.0
- [sv](https://github.com/figelwump/sv) (secret vault for development credentials)
- Ghostty XCFramework (optional — Toastty can build in fallback mode without it)

## Clone and generate

```bash
git clone https://github.com/figelwump/toastty.git
cd toastty
./scripts/dev/bootstrap-worktree.sh
```

`Project.swift` is the source of truth. `./scripts/dev/bootstrap-worktree.sh` runs `tuist install` and `tuist generate --no-open`, and in a fresh linked worktree it also reuses local Ghostty xcframeworks from another Toastty worktree when available. The generated `toastty.xcworkspace` is not committed, so rerun the bootstrap script or `tuist generate` after manifest or file-layout changes. Re-run `tuist install` whenever `Tuist/Package.swift` or `Tuist/Package.resolved` changes.

## Install sv

[sv](https://github.com/figelwump/sv) is a lightweight macOS secret vault that stores API keys and credentials in the native Keychain and injects them into processes at runtime. Automation scripts in this repo use `sv exec --` to run commands that need secrets without exposing values in shell history or environment dumps.

```bash
curl -fsSL https://raw.githubusercontent.com/figelwump/sv/main/install.sh | bash
```

After installing, store any required secrets with `sv set <KEY>`. To run a command with secrets injected:

```bash
sv exec -- <command>
```

## Install Ghostty XCFramework (optional)

```bash
GHOSTTY_BUILD_FLAGS="-Demit-macos-app=false -Demit-xcframework=true -Dxcframework-target=universal -Dsentry=false" \
GHOSTTY_XCFRAMEWORK_SOURCE=/path/to/GhosttyKit.xcframework \
  ./scripts/ghostty/install-local-xcframework.sh
```

Set `GHOSTTY_XCFRAMEWORK_VARIANT=release|debug` to control the destination artifact path. The installer also auto-detects a sibling `../ghostty/macos/GhosttyKit.xcframework` checkout when present.
When the source path lives inside a Ghostty git checkout, the installer also records the Ghostty commit and source cleanliness in an ignored sidecar metadata file next to the installed xcframework.

For the recommended upstream Ghostty build command, release note guidance, see [ghostty-integration.md](ghostty-integration.md).

After installing, regenerate:

```bash
./scripts/dev/bootstrap-worktree.sh
```

To build without Ghostty:

```bash
TUIST_DISABLE_GHOSTTY=1 ./scripts/dev/bootstrap-worktree.sh
```

## Build

```bash
ARCH="$(uname -m)"
xcodebuild -workspace toastty.xcworkspace -scheme ToasttyApp \
  -configuration Debug \
  -destination "platform=macOS,arch=${ARCH}" \
  -derivedDataPath Derived build
```

Or open `toastty.xcworkspace` in Xcode and hit Run.

## Validate

```bash
# Full gate: generate + build + workspace-tabs smoke + test
./scripts/automation/check.sh

# Smoke UI automation
./scripts/automation/smoke-ui.sh

# Shortcut hint screenshot smoke
./scripts/automation/shortcut-hints-smoke.sh

# Workspace tabs screenshot smoke
./scripts/automation/workspace-tabs-smoke.sh

# Keyboard shortcut tracing
./scripts/automation/shortcut-trace.sh

# Foreground-capable remote GUI validation
TOASTTY_REMOTE_GUI_HOST=mac-mini.local \
./scripts/remote/gui-validate.sh \
  --scope working-tree \
  --validation-command 'peekaboo menu list --pid "$TOASTTY_PID" --json | tee "$TOASTTY_ARTIFACTS_DIR/peekaboo-menu.json"'
```

## Dev and test runs

When developing or testing locally, Toastty can isolate all mutable state — config, workspace layouts, terminal profiles, logs, and `UserDefaults` — inside a per-worktree or per-run runtime home so parallel instances never collide.

Set `TOASTTY_DEV_WORKTREE_ROOT` to derive a stable sandbox from the current worktree, or set `TOASTTY_RUNTIME_HOME` for an explicit one-off sandbox. The Tuist-generated Xcode Run schemes already set `TOASTTY_DEV_WORKTREE_ROOT=$(SRCROOT)`.

For fresh linked worktrees, run `./scripts/dev/bootstrap-worktree.sh` once to symlink Ghostty artifacts from another Toastty checkout before building.

For the full runtime-home model, `instance.json` fields, and cleanup conventions, see [Runtime Sandboxing](runtime-sandboxing.md).

## Build a signed release DMG

The release script expects:
- a clean Toastty git working tree
- a release Ghostty artifact at `Dependencies/GhosttyKit.Release.xcframework`
- Ghostty provenance metadata at `Dependencies/GhosttyKit.Release.metadata.env`
- a local `Developer ID Application` certificate
- notarization credentials injected at runtime
- a Sparkle private key injected at runtime as `TOASTTY_SPARKLE_PRIVATE_KEY`

Before building a release artifact, run the full automated gate on the release candidate:

```bash
./scripts/automation/check.sh
```

Use an explicit marketing version plus a monotonically increasing build number:

```bash
sv exec -- env \
  TOASTTY_VERSION=0.1.0 \
  TOASTTY_BUILD_NUMBER=1 \
  TUIST_DEVELOPMENT_TEAM=<TEAM_ID> \
  ./scripts/release/release.sh
```

The script archives the app, exports a signed bundle, creates a plain drag-to-install DMG, notarizes it, staples it, and writes outputs under `artifacts/release/`.
It also snapshots release provenance into the release directory:
- `release-metadata.env` with the exact Toastty commit that was built
- `ghostty-metadata.env` with the embedded Ghostty commit and build flags
- `sparkle-metadata.env` with the feed URL, public key, DMG signature, and enclosure metadata needed for appcast publication

The script also records the canonical `artifacts/release/<version>-<build>/release-notes.md` path in `release-metadata.env`, but it does not generate the file for you. The repo-local `toastty-release` skill covers the build step and drafting `release-notes.md` from the recorded release diff so it can be reviewed before publish; the repo-local `toastty-publish` skill covers publishing those drafted notes later.

## Publish a draft GitHub Release

After the DMG exists locally, publish it to GitHub Releases with the helper script. The script defaults to a draft release; pass `--publish` only when you want the release to go live immediately and update the Sparkle appcast at `https://updates.toastty.dev/appcast.xml`.

Prerequisites:
- `gh` is installed and authenticated for the target repo
- the recorded release commit is available in the current checkout

Author `artifacts/release/<version>-<build>/release-notes.md` before publishing. Ground it in the recorded Toastty release diff and include the embedded Ghostty commit plus build flags.

```bash
sv exec -- env \
  TOASTTY_VERSION=0.1.0 \
  TOASTTY_BUILD_NUMBER=1 \
  ./scripts/release/publish-github-release.sh \
  --create-tag
```

Add `--dry-run` to print the exact `git tag`, `git push`, and `gh release create ...` commands without creating anything. If `origin` is not a parseable GitHub remote, pass `--repo <owner/repo>` explicitly. Pass `--notes-file` only when you want to override the default notes path.

## Related docs

- [Environment and Launch Flags](environment-and-build-flags.md)
- [Ghostty Integration](ghostty-integration.md)
- [Runtime Sandboxing](runtime-sandboxing.md)
