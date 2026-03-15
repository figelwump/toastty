---
name: toastty-release
description: Use this skill when preparing or publishing a Toastty app release, including Ghostty artifact installation, signed DMG creation, writing release notes from the recorded release diff, and GitHub release publication.
---

# Toastty Release

Use this workflow when the user asks to cut, prepare, or publish a Toastty release.

## Core flow

1. Ensure the Toastty checkout is clean before running `scripts/release/release.sh`.
2. Ensure the Ghostty release artifact is installed with provenance metadata:
   - `Dependencies/GhosttyKit.Release.xcframework`
   - `Dependencies/GhosttyKit.Release.metadata.env`
3. Run `scripts/release/release.sh` with the requested `TOASTTY_VERSION`, `TOASTTY_BUILD_NUMBER`, and signing/notary secrets.
4. Read `artifacts/release/<version>-<build>/release-metadata.env` and `ghostty-metadata.env`, inspect the Toastty diff from `RELEASE_PREVIOUS_TAG` to `RELEASE_SOURCE_COMMIT`, and write `artifacts/release/<version>-<build>/release-notes.md`.
5. Let the user edit `release-notes.md` if they want changes before publication.
6. Run `scripts/release/publish-github-release.sh --create-tag` to tag the recorded release commit and publish the GitHub release.

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
  - `release-notes.md` once the agent or user authors it
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

- The release script records the source commit, previous release tag, and canonical notes path; it does not author the notes file.
- Use `release-metadata.env` as the source of truth:
  - `RELEASE_SOURCE_COMMIT`
  - `RELEASE_PREVIOUS_TAG`
  - `RELEASE_PREVIOUS_COMMIT`
  - `RELEASE_NOTES_PATH`
- Ground the notes in the actual diff and commit history between the previous release and the recorded release commit. If there is no previous tag, summarize the shipped functionality from the reachable history for `RELEASE_SOURCE_COMMIT`.
- Use `ghostty-metadata.env` or the mirrored Ghostty fields in `release-metadata.env` so the notes include the shipped Ghostty commit and build flags.
- It is fine for the agent to draft the prose itself, but the content should stay anchored to the recorded metadata and git history rather than the current `HEAD`.

## Validation

- Run at least targeted script validation after release-workflow changes.
- Run `./scripts/automation/check.sh` after non-trivial repo changes unless the user explicitly scopes the task more narrowly.
