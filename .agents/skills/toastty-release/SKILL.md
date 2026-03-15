---
name: toastty-release
description: Use this skill when preparing a Toastty app release build, including Ghostty artifact installation, release provenance validation, and signed DMG creation.
---

# Toastty Release

Use this workflow when the user asks to cut or prepare a Toastty release build artifact.

## Core flow

1. Ensure the Toastty checkout is clean before running `scripts/release/release.sh`.
2. Ensure the Ghostty release artifact is installed with provenance metadata:
   - `Dependencies/GhosttyKit.Release.xcframework`
   - `Dependencies/GhosttyKit.Release.metadata.env`
3. Run `scripts/release/release.sh` with the requested `TOASTTY_VERSION`, `TOASTTY_BUILD_NUMBER`, and signing/notary secrets.
4. Hand off the generated release directory for later authoring and publication:
   - `release-metadata.env`
   - `ghostty-metadata.env`
   - `Toastty-<version>.dmg`
5. Stop after the build handoff unless the user explicitly asks to continue into release-note authoring or publication. If they do, open `../toastty-publish/SKILL.md` and follow that workflow.

## Important invariants

- `scripts/release/release.sh` is the source of truth for build-time provenance.
- Release DMG builds require:
  - a clean Toastty git working tree
  - a clean Ghostty source snapshot recorded in `Dependencies/GhosttyKit.Release.metadata.env`
  - non-empty Ghostty commit and build-flags metadata
- The generated release directory contains the handoff artifacts for the publish step:
  - `release-metadata.env`
  - `ghostty-metadata.env`
  - `Toastty-<version>.dmg`
- Keep `artifacts/release/<version>-<build>/` intact between the build and publish phases.

## Ghostty artifact install

Preferred install pattern:

```bash
GHOSTTY_XCFRAMEWORK_VARIANT=release \
GHOSTTY_BUILD_FLAGS="-Demit-macos-app=false -Demit-xcframework=true -Dxcframework-target=universal -Dsentry=false" \
GHOSTTY_XCFRAMEWORK_SOURCE=/path/to/GhosttyKit.xcframework \
./scripts/ghostty/install-local-xcframework.sh
```

When the source path is inside a Ghostty git checkout, the installer auto-detects the Ghostty commit and source cleanliness. If not, provide `GHOSTTY_COMMIT` and, if necessary, `GHOSTTY_SOURCE_DIRTY=0`.

## Validation

- Run at least targeted script validation after release-workflow changes.
- Run `./scripts/automation/check.sh` after non-trivial repo changes unless the user explicitly scopes the task more narrowly.
