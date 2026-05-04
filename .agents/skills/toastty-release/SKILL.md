---
name: toastty-release
description: Use this skill when preparing a Toastty app release build, including Ghostty artifact installation, signed DMG creation, and drafting release notes from the recorded release diff.
---

# Toastty Release

Use this workflow when the user asks to cut or prepare a Toastty release build artifact.

## Core flow

1. Ensure the Toastty checkout is clean before running `scripts/release/release.sh`.
2. Ensure the Ghostty release artifact is installed with provenance metadata:
   - `Dependencies/GhosttyKit.Release.xcframework`
   - `Dependencies/GhosttyKit.Release.metadata.env`
3. Run automated validation before building the release artifact. Prefer the remote validation wrappers:
   - `sv exec -- scripts/remote/validate.sh --smoke-test smoke-ui`
   - `sv exec -- scripts/remote/test.sh --`
   Use `./scripts/automation/check.sh` only when the user explicitly asks for a local gate, the remote path is unavailable, or you are intentionally validating local-only release workflow changes.
4. Run `scripts/release/release.sh` with the requested `TOASTTY_VERSION`, `TOASTTY_BUILD_NUMBER`, and signing/notary secrets.
5. Verify that `artifacts/release/<version>-<build>/release-metadata.env`, `ghostty-metadata.env`, `sparkle-metadata.env`, and `Toastty-<version>.dmg` all exist and are non-empty, then read the metadata files.
6. Confirm `RELEASE_SOURCE_COMMIT` is available in the local clone before inspecting history or writing notes.
7. Use `.agents/skills/toastty-release/assets/release-notes-template.md` as the starting structure for `RELEASE_NOTES_PATH`.
8. Read several prior `artifacts/release/**/release-notes.md` files, prioritizing the most recent releases, so the new notes follow Toastty's established house style.
9. Inspect the Toastty diff and commit history from `RELEASE_PREVIOUS_TAG` to `RELEASE_SOURCE_COMMIT`.
10. Write `release-notes.md` at `RELEASE_NOTES_PATH`, grounded in the recorded metadata rather than the current `HEAD`.
11. Let the user review or edit `release-notes.md` if they want changes before publication.
12. Hand off the generated release directory for later publication:
   - `release-metadata.env`
   - `ghostty-metadata.env`
   - `sparkle-metadata.env`
   - `release-notes.md`
   - `Toastty-<version>.dmg`
13. Stop after the build-and-draft handoff unless the user explicitly asks to continue into publication. If they do, open `../toastty-publish/SKILL.md` and follow that workflow.

## Important invariants

- `scripts/release/release.sh` is the source of truth for build-time provenance.
- Release DMG builds require:
  - a clean Toastty git working tree
  - a clean Ghostty source snapshot recorded in `Dependencies/GhosttyKit.Release.metadata.env`
  - non-empty Ghostty commit and build-flags metadata
- Run automated validation before `scripts/release/release.sh`; prefer the remote smoke and test wrappers unless the user explicitly scopes the gate to a local run or the remote path is unavailable.
- Draft release notes from the recorded metadata and git history, not from the current `HEAD`.
- The generated release directory contains the handoff artifacts for the publish step:
  - `release-metadata.env`
  - `ghostty-metadata.env`
  - `sparkle-metadata.env`
  - `release-notes.md`
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

## Release notes

- Use [.agents/skills/toastty-release/assets/release-notes-template.md](assets/release-notes-template.md) as the initial outline. Fill in the `{{placeholder}}` tokens rather than copying them literally.
- Before drafting, read several existing `artifacts/release/**/release-notes.md` files, prioritizing the most recent releases, and mirror that structure and voice unless the user asks for a deliberate format change.
- `release-metadata.env` is the source of truth for:
  - `RELEASE_SOURCE_COMMIT`
  - `RELEASE_PREVIOUS_TAG`
  - `RELEASE_PREVIOUS_COMMIT`
  - `RELEASE_NOTES_PATH`
- Use `ghostty-metadata.env` or the mirrored Ghostty fields in `release-metadata.env` so the notes include the shipped Ghostty commit and build flags.
- Follow the established Toastty section order unless the release is a first-public-build special case:
  - `# v<version>`
  - `Release date: <Month D, YYYY>`
  - `Toastty commit: \`<short-sha>\``
  - `Previous release: \`<tag>\`` or `Previous release: First public release`
  - optional `## Highlights`
  - `## Changes`
  - `## Upgrade Notes`
  - `## Embedded Ghostty`
- Prefer the recent house style over the older early-release notes:
  - concise, direct, product-facing prose
  - lightly enthusiastic only when a flagship feature genuinely warrants it
  - minimal filler, minimal implementation jargon, no commit-log dump
- Use `## Highlights` only when the release has multiple headline features or a broader product shift. For narrower releases, skip `Highlights` and go straight to `Changes`.
- Represent changes since the last version as a curated summary of the actual diff, not a chronological list of commits:
  - group related commits into a single user-facing bullet
  - order bullets by user impact, not commit order
  - lead with new capabilities or behavior changes, then notable fixes and polish
  - explain the user-visible effect, not the implementation mechanics, unless the mechanics matter for operators
- Default to short `## Changes` bullets. Use short `###` subsections inside `Highlights` only when a major release needs a little extra explanation, config context, or a short example.
- Mention concrete shortcuts, menu items, config files, CLI commands, or paths inline with backticks when they help the reader understand what changed.
- Use `## Upgrade Notes` for migration steps, changed shortcuts, config additions, shell-integration refreshes, or behavior caveats. If there is nothing actionable, explicitly say that no manual migration is required for the release.
- If there is no previous tag, summarize the shipped functionality from the reachable history for `RELEASE_SOURCE_COMMIT`.
- It is fine for the agent to draft the prose itself, but the content should stay anchored to the recorded metadata, release diff, and prior release-note style.
- Keep the notes focused on shipped behavior, upgrade-relevant fixes, and operator-relevant build provenance.

## Validation

- Before writing notes, confirm all three metadata files and the DMG exist and are non-empty.
- Before diffing, confirm `RELEASE_SOURCE_COMMIT` is reachable in the local clone.
- Before handing off to publish, confirm the notes file exists at `RELEASE_NOTES_PATH`, is non-empty, and has no leftover `{{placeholder}}` tokens.
- Run at least targeted script validation after release-workflow changes.
- For non-trivial repo changes, prefer the remote smoke/test wrappers before release handoff. State clearly whether validation ran remotely, locally, or through a remote wrapper with local fallback.
