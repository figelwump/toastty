---
name: toastty-publish
description: Use this skill when publishing an existing Toastty release artifact to GitHub Releases, using already-authored release notes and tagging the recorded release commit.
---

# Toastty Publish

Use this workflow when the user already has a built Toastty release artifact and drafted release notes and wants to publish it.

## Core flow

1. Verify that `artifacts/release/<version>-<build>/release-metadata.env`, `ghostty-metadata.env`, `sparkle-metadata.env`, `release-notes.md`, and `Toastty-<version>.dmg` all exist and are non-empty, then read the metadata files.
2. Confirm `RELEASE_SOURCE_COMMIT` is available in the local clone before publishing.
3. Confirm the drafted notes at `RELEASE_NOTES_PATH` do not contain leftover `{{placeholder}}` tokens and that the user is satisfied with the existing notes.
4. Run `scripts/release/publish-github-release.sh --create-tag` to publish a draft by default. Add `--publish` only when the user wants the release to go live immediately and update the Sparkle appcast.

## Important invariants

- Publish must use `artifacts/release/<version>-<build>/release-metadata.env`, not the current `HEAD`, to decide what commit gets tagged.
- Publish must use `artifacts/release/<version>-<build>/sparkle-metadata.env`, not ad-hoc shell values, to decide what gets written to the Sparkle appcast.
- `release-metadata.env` is the source of truth for:
  - `RELEASE_SOURCE_COMMIT`
  - `RELEASE_NOTES_PATH`
- `scripts/release/publish-github-release.sh` expects the notes file to exist and be non-empty before publication.
- The release directory under `artifacts/release/<version>-<build>/` must remain intact from the earlier build phase.

## Validation

- Before publishing, confirm all three metadata files and the DMG exist and are non-empty.
- Before publishing, confirm `RELEASE_SOURCE_COMMIT` is reachable in the local clone.
- Before publishing, confirm the notes file exists at `RELEASE_NOTES_PATH` and is non-empty.
- Use `--dry-run` when you want to inspect the derived `git` and `gh` commands before creating the tag or release.
