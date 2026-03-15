---
name: toastty-release
description: Use this skill when preparing or publishing a Toastty app release, including Ghostty artifact installation, signed DMG creation, release-notes drafting, and GitHub release publication.
---

# Toastty Release

Use this workflow when the user asks to cut, prepare, or publish a Toastty release.

## Core flow

1. Ensure the Toastty checkout is clean before running `scripts/release/release.sh`.
2. Ensure the Ghostty release artifact is installed with provenance metadata:
   - `Dependencies/GhosttyKit.Release.xcframework`
   - `Dependencies/GhosttyKit.Release.metadata.env`
3. Run `scripts/release/release.sh` with the requested `TOASTTY_VERSION`, `TOASTTY_BUILD_NUMBER`, and signing/notary secrets.
4. Edit `artifacts/release/<version>-<build>/release-notes.md` if the user wants changes before publication.
5. Run `scripts/release/publish-github-release.sh --create-tag` to tag the recorded release commit and publish the GitHub release.

## Important invariants

- `scripts/release/release.sh` is the source of truth for build-time provenance.
- Publish must use `artifacts/release/<version>-<build>/release-metadata.env`, not the current `HEAD`, to decide what commit gets tagged.
- Release DMG builds require:
  - a clean Toastty git working tree
  - a clean Ghostty source snapshot recorded in `Dependencies/GhosttyKit.Release.metadata.env`
  - non-empty Ghostty commit and build-flags metadata
- The generated release directory contains the handoff artifacts for publish:
  - `release-metadata.env`
  - `ghostty-metadata.env`
  - `release-notes.md`
  - `Toastty-<version>.dmg`

## Ghostty artifact install

Preferred install pattern:

```bash
GHOSTTY_XCFRAMEWORK_VARIANT=release \
GHOSTTY_BUILD_FLAGS="-Demit-macos-app=false -Demit-xcframework=true -Dxcframework-target=universal -Dsentry=false" \
GHOSTTY_XCFRAMEWORK_SOURCE=/path/to/GhosttyKit.xcframework \
./scripts/ghostty/install-local-xcframework.sh
```

When the source path is inside a Ghostty git checkout, the installer auto-detects the Ghostty commit and source cleanliness. If not, provide `GHOSTTY_COMMIT` and, if necessary, `GHOSTTY_SOURCE_DIRTY=0`.

## Release notes

- `scripts/release/release.sh` drafts `release-notes.md`.
- If `OPENAI_API_KEY` is available, the draft includes an LLM-generated `Changes` section from commits since the previous tagged release.
- The draft still needs a human pass before publishing.

## Validation

- Run at least targeted script validation after release-workflow changes.
- Run `./scripts/automation/check.sh` after non-trivial repo changes unless the user explicitly scopes the task more narrowly.
