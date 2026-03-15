---
name: toastty-publish
description: Use this skill when authoring release notes for an existing Toastty release artifact and publishing it to GitHub Releases, including tagging the recorded release commit.
---

# Toastty Publish

Use this workflow when the user already has a built Toastty release artifact and wants to write release notes or publish it.

## Core flow

1. Verify that `artifacts/release/<version>-<build>/release-metadata.env` and `ghostty-metadata.env` both exist and are non-empty, then read them.
2. Confirm `RELEASE_SOURCE_COMMIT` is available in the local clone before inspecting history or writing notes.
3. Use `.agents/skills/toastty-publish/assets/release-notes-template.md` as the starting structure for `RELEASE_NOTES_PATH`.
4. Inspect the Toastty diff and commit history from `RELEASE_PREVIOUS_TAG` to `RELEASE_SOURCE_COMMIT`.
5. Write `release-notes.md` at `RELEASE_NOTES_PATH`, grounded in the recorded metadata rather than the current `HEAD`.
6. Let the user edit the notes if they want changes before publication.
7. Run `scripts/release/publish-github-release.sh --create-tag` to publish a draft by default. Add `--publish` only when the user wants the release to go live immediately.

## Important invariants

- Publish must use `artifacts/release/<version>-<build>/release-metadata.env`, not the current `HEAD`, to decide what commit gets tagged.
- `release-metadata.env` is the source of truth for:
  - `RELEASE_SOURCE_COMMIT`
  - `RELEASE_PREVIOUS_TAG`
  - `RELEASE_PREVIOUS_COMMIT`
  - `RELEASE_NOTES_PATH`
- Use `ghostty-metadata.env` or the mirrored Ghostty fields in `release-metadata.env` so the notes include the shipped Ghostty commit and build flags.
- `scripts/release/publish-github-release.sh` expects the notes file to exist and be non-empty before publication.
- The release directory under `artifacts/release/<version>-<build>/` must remain intact from the earlier build phase.

## Release notes

- Use [.agents/skills/toastty-publish/assets/release-notes-template.md](assets/release-notes-template.md) as the initial outline. Fill in the placeholders rather than copying them literally.
- Ground the `Changes` section in the actual diff and commit history between the previous release and the recorded release commit.
- If there is no previous tag, summarize the shipped functionality from the reachable history for `RELEASE_SOURCE_COMMIT`.
- It is fine for the agent to draft the prose itself, but the content should stay anchored to the recorded metadata and git history.
- Keep the notes focused on shipped behavior, upgrade-relevant fixes, and operator-relevant build provenance.

## Validation

- Before writing notes, confirm both metadata files exist and are non-empty.
- Before diffing, confirm `RELEASE_SOURCE_COMMIT` is reachable in the local clone.
- Before publishing, confirm the notes file exists at `RELEASE_NOTES_PATH` and is non-empty.
- Before publishing, confirm no placeholder literals from the template remain in the final notes file.
- Use `--dry-run` when you want to inspect the derived `git` and `gh` commands before creating the tag or release.
