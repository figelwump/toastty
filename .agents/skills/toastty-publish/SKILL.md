---
name: toastty-publish
description: Use this skill when publishing an existing Toastty release artifact to GitHub Releases, using already-authored release notes and tagging the recorded release commit.
---

# Toastty Publish

Use this workflow when the user already has a built Toastty release artifact and drafted release notes and wants to publish it.

## Release order

Publishing is step 5 of the release order in `docs/building-and-releasing.md`
(section "Release order"): record the version, prepare the release commit on
`main`, deploy the production push relay, make the iPhone build available,
release the Mac app, then publish the website change.

- Before `--publish`, confirm that the production relay is deployed and the
  iPhone build is available when the release changes either one. Read the
  release checklist; ask the user only when it does not say. This is a state
  check, not a second release approval. The iPhone build is required before
  `--publish`: an older phone shows a task alert's text, but a tap only opens
  the app, and while the app is open no banner shows. The repository owner deploys the relay by hand; do not deploy it. An
  older relay refuses task alerts, and an older phone cannot route them.
  A draft release does not reach users and can come earlier.
- After `--publish` and its feed check pass, the website change is next: its
  pull request merges into `main`, and toastty.dev updates from `main`. Say so
  in the handoff, with the website pull request if there is one.

## Core flow

1. Verify that `artifacts/release/<version>-<build>/release-metadata.env`, `ghostty-metadata.env`, `sparkle-metadata.env`, `release-notes.md`, and `Toastty-<version>.dmg` all exist and are non-empty, then read the metadata files.
2. Confirm `RELEASE_SOURCE_COMMIT` is available in the local clone before publishing.
3. Confirm the drafted notes at `RELEASE_NOTES_PATH` do not contain leftover
   `{{placeholder}}` tokens, satisfy the user, have a `## Highlights` section
   with content, and include these exact canonical lines using values from
   release metadata:

   ```text
   - Commit: `<RELEASE_GHOSTTY_COMMIT_SHORT>`
   - Build flags: `<RELEASE_GHOSTTY_BUILD_FLAGS>`
   ```
4. Run `scripts/release/publish-github-release.sh --create-tag` to publish a draft by default. Keep the draft default when the user asked only for a draft or did not say. Add `--publish` only when the user wants the release to go live immediately and update the Sparkle appcast. A release approval that covers making the release live is that request; do not ask again.

## Important invariants

- Publish must use `artifacts/release/<version>-<build>/release-metadata.env`, not the current `HEAD`, to decide what commit gets tagged.
- Publish must use `artifacts/release/<version>-<build>/sparkle-metadata.env`, not ad-hoc shell values, to decide what gets written to the Sparkle appcast.
- `release-metadata.env` is the source of truth for:
  - `RELEASE_SOURCE_COMMIT`
  - `RELEASE_NOTES_PATH`
  - `RELEASE_GHOSTTY_COMMIT_SHORT`
  - `RELEASE_GHOSTTY_BUILD_FLAGS`
- `scripts/release/publish-github-release.sh` expects the notes file to exist, be non-empty, have exactly one `## Highlights` section with content, have no `{{placeholder}}` tokens, and include exact canonical Ghostty commit and build-flags lines before publication.
- The release directory under `artifacts/release/<version>-<build>/` must remain intact from the earlier build phase.

## Validation

- Before publishing, confirm all three metadata files and the DMG exist and are non-empty.
- Before publishing, confirm `RELEASE_SOURCE_COMMIT` is reachable in the local clone.
- Before publishing, confirm the notes file exists at `RELEASE_NOTES_PATH`, is non-empty, has a `## Highlights` section with content, and includes the exact canonical Ghostty commit and build-flags lines from release metadata.
- Before `--publish`, confirm the earlier release order steps that the release needs.
- Use `--dry-run` when you want to inspect the derived `git` and `gh` commands before creating the tag or release.
