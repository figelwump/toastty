---
name: toastty-release
description: Use this skill when preparing a Toastty app release build, including Ghostty artifact installation, signed DMG creation, and drafting release notes from the recorded release diff.
---

# Toastty Release

Use this workflow when the user asks to cut or prepare a Toastty release build artifact.

## Release order

A release has four parts that reach users separately: the push relay, the
iPhone app, the Mac app, and the website. Follow the order in
`docs/building-and-releasing.md` (section "Release order"), and keep its
checklist in the release pull request or handoff:

1. Record the version: the marketing version and a build number greater than
   the highest `sparkle:version` in `https://updates.toastty.dev/appcast.xml`.
   The release of the task system is `0.10.0`, build `40` or higher. A recorded
   version is not approval to release.
2. Prepare the release commit on `main`, with the Ghostty artifact at the
   documented pin. Keep the website change out of `main` until step 6: the
   Render site most likely deploys on each push to `main`. The doc section
   "When the website goes live" lists the options.
3. Deploy the production push relay. The repository owner does this by hand
   (`workers/push/README.md`, section "Production relay release step"). Do not
   deploy it yourself: ask the owner and wait. An older relay refuses task
   alerts, and the Mac then sends nothing for a task alert that replaced no
   session alert.
4. Make the iPhone build available through TestFlight
   (`docs/ios-release-ci.md`). Required before the Mac release goes live: an
   older phone shows a task alert's text, but a tap only opens the app, and
   while the app is open no banner shows.
5. Release the Mac app: this skill, then `../toastty-publish/SKILL.md`.
6. Publish the website change: merge its pull request into `main` after the
   Mac release is live, then check toastty.dev. For `0.10.0` that is the
   website text change (#392) and the "Tasks and the Coordinator" section
   stacked on it; retarget #392 to `main` after step 2.

Before step 5 goes live, confirm that steps 3 and 4 are done for a release
that changes the relay or the phone. Read the release checklist; ask the user
only when it does not say. You can build the DMG and draft the notes before
then; the iPhone real-device check uses that build.

## Core flow

1. Ensure the Toastty checkout is clean before running `scripts/release/release.sh`.
2. Ensure the Ghostty release artifact is installed with provenance metadata:
   - `Dependencies/GhosttyKit.Release.xcframework`
   - `Dependencies/GhosttyKit.Release.metadata.env`
   Confirm the metadata's `GHOSTTY_SOURCE_REPO` still exists and contains the
   recorded `GHOSTTY_COMMIT`; release verification reads license material from
   that exact source snapshot. Run `scripts/release/check-ghostty-pin.sh`: the
   installed commit must equal the `git -C ../ghostty checkout <commit>` pin in
   `docs/ghostty-integration.md`. `release.sh` runs the same check and stops on
   a stale artifact; rebuild Ghostty at the pin instead of editing the pin.
3. Ensure `Sources/App/Resources/ThirdPartyNotices.txt` matches the pinned
   production web-panel dependencies, recorded Ghostty commit, Sparkle pin, and
   Toastty license. `scripts/release/release.sh` installs production web-panel
   packages and runs `scripts/release/generate-third-party-notices.mjs --check`.
   If the check is stale, regenerate and commit the notice file before retrying,
   because the release script requires a clean Toastty checkout. If a package
   ships no license file, the check stops. Add an entry for that exact
   `name@version` to `scripts/release/third-party-license-overrides.json` only
   when its author published the license text elsewhere, such as a license file
   added to its repository later. Store that text under
   `scripts/release/third-party-licenses/` and name its source. If the license
   text cannot be established, ask the user; do not write one.
4. Run automated validation before building the release artifact. Prefer the remote validation wrappers:
   - `sv exec -- scripts/remote/validate.sh --smoke-test smoke-ui`
   - `sv exec -- scripts/remote/test.sh --`
   Use `./scripts/automation/check.sh` only when the user explicitly asks for a local gate, the remote path is unavailable, or you are intentionally validating local-only release workflow changes.
5. Run `scripts/release/release.sh` with the recorded `TOASTTY_VERSION` and `TOASTTY_BUILD_NUMBER` (release order step 1) and the signing/notary secrets.
6. Verify that `artifacts/release/<version>-<build>/release-metadata.env`, `artifacts/release/<version>-<build>/ghostty-metadata.env`, `artifacts/release/<version>-<build>/sparkle-metadata.env`, and `artifacts/release/<version>-<build>/Toastty-<version>.dmg` all exist and are non-empty, then read the metadata files.
7. Confirm `RELEASE_SOURCE_COMMIT` is available in the local clone before inspecting history or writing notes.
8. Use `.agents/skills/toastty-release/assets/release-notes-template.md` as the starting structure for `RELEASE_NOTES_PATH`.
9. Read several prior `artifacts/release/**/release-notes.md` files, prioritizing the most recent releases, so the new notes follow Toastty's established house style.
10. Inspect the Toastty diff and commit history from `RELEASE_PREVIOUS_TAG` to `RELEASE_SOURCE_COMMIT`.
11. Write `artifacts/release/<version>-<build>/release-notes.md` at `RELEASE_NOTES_PATH`, grounded in the recorded metadata rather than the current `HEAD`.
12. Let the user review or edit `artifacts/release/<version>-<build>/release-notes.md` if they want changes before publication. Make any changes they ask for before step 14. Do not stop for a review that the user did not ask for.
13. Hand off the generated release directory and artifacts, always using repo-relative paths:
   - `artifacts/release/<version>-<build>/`
   - `artifacts/release/<version>-<build>/release-metadata.env`
   - `artifacts/release/<version>-<build>/ghostty-metadata.env`
   - `artifacts/release/<version>-<build>/sparkle-metadata.env`
   - `artifacts/release/<version>-<build>/release-notes.md`
   - `artifacts/release/<version>-<build>/Toastty-<version>.dmg`
14. If the user's release approval already covers publication, do not ask again: open `../toastty-publish/SKILL.md` and follow that workflow. If the approval did not cover publication, stop after the build-and-draft handoff, and continue into publication only when the user asks.

## Important invariants

- `scripts/release/release.sh` is the source of truth for build-time provenance.
- Release DMG builds require:
  - a clean Toastty git working tree
  - a clean Ghostty source snapshot recorded in `Dependencies/GhosttyKit.Release.metadata.env`
  - the recorded Ghostty source checkout to remain available with the recorded commit
  - non-empty Ghostty commit and build-flags metadata
  - a Ghostty commit equal to the pin in `docs/ghostty-integration.md`
  - checked-in third-party notices that match the recorded and pinned dependencies
- Run automated validation before `scripts/release/release.sh`; prefer the remote smoke and test wrappers unless the user explicitly scopes the gate to a local run or the remote path is unavailable.
- Draft release notes from the recorded metadata and git history, not from the current `HEAD`.
- The generated release directory contains the handoff artifacts for the publish step:
  - `artifacts/release/<version>-<build>/release-metadata.env`
  - `artifacts/release/<version>-<build>/ghostty-metadata.env`
  - `artifacts/release/<version>-<build>/sparkle-metadata.env`
  - `artifacts/release/<version>-<build>/release-notes.md`
  - `artifacts/release/<version>-<build>/Toastty-<version>.dmg`
- Keep `artifacts/release/<version>-<build>/` intact between the build and publish phases.
- In user-facing handoffs, always include the release directory path `artifacts/release/<version>-<build>/` and use repo-relative paths for every generated artifact. Do not refer to artifact files by bare filename only, such as `release-notes.md` or `Toastty-<version>.dmg`.
- If metadata provides an absolute path such as `RELEASE_NOTES_PATH`, convert it to the equivalent repo-relative path before presenting it to the user.

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
  - `## Highlights` (required)
  - `## Changes`
  - `## Upgrade Notes`
  - `## Embedded Ghostty`
- Prefer the recent house style over the older early-release notes:
  - concise, direct, product-facing prose
  - lightly enthusiastic only when a flagship feature genuinely warrants it
  - minimal filler, minimal implementation jargon, no commit-log dump
- Every release has a `## Highlights` section, and `scripts/release/publish-github-release.sh` stops without it. The publish step puts it in the update feed, and the Sparkle update prompt shows it in a box of about 640 × 235 points, so it is the first thing an updating user reads. Lead with what is new for them and what to try first, and keep it short enough to fit: a few bullets. A release with a broader product shift can use short `###` subsections.
- In `## Highlights`, use only `- ` bullets, `### ` subheadings, paragraphs, `` `code` ``, `**bold**`, and `[text](https://...)` links. The publish step stops on other Markdown, such as numbered or nested lists, code blocks, or images, because the prompt would show it as raw text.
- Represent changes since the last version as a curated summary of the actual diff, not a chronological list of commits:
  - group related commits into a single user-facing bullet
  - order bullets by user impact, not commit order
  - lead with new capabilities or behavior changes, then notable fixes and polish
  - explain the user-visible effect, not the implementation mechanics, unless the mechanics matter for operators
- Default to short `## Changes` bullets. Use short `###` subsections inside `Highlights` when a major release needs a little extra explanation, config context, or a short example.
- Mention concrete shortcuts, menu items, config files, CLI commands, or paths inline with backticks when they help the reader understand what changed.
- Use `## Upgrade Notes` for migration steps, changed shortcuts, config additions, shell-integration refreshes, or behavior caveats. If there is nothing actionable, explicitly say that no manual migration is required for the release.
- If there is no previous tag, summarize the shipped functionality from the reachable history for `RELEASE_SOURCE_COMMIT`.
- It is fine for the agent to draft the prose itself, but the content should stay anchored to the recorded metadata, release diff, and prior release-note style.
- Keep the notes focused on shipped behavior, upgrade-relevant fixes, and operator-relevant build provenance.

## Validation

- Before writing notes, confirm all three metadata files and the DMG exist and are non-empty.
- Before building, confirm the recorded Ghostty source checkout and commit are available and the third-party notices check passes.
- Before diffing, confirm `RELEASE_SOURCE_COMMIT` is reachable in the local clone.
- Before handing off to publish, confirm the notes file exists at `RELEASE_NOTES_PATH`, is non-empty, has a `## Highlights` section with content, and has no leftover `{{placeholder}}` tokens.
- Run at least targeted script validation after release-workflow changes.
- For non-trivial repo changes, prefer the remote smoke/test wrappers before release handoff. State clearly whether validation ran remotely, locally, or through a remote wrapper with local fallback.
