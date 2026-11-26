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
- Right before `--publish`, ask the user "publish now?" and wait for a plain
  yes; see [Publish now?](#publish-now). Ask it after the state checks above,
  not instead of them.
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
4. Run `scripts/release/publish-github-release.sh --create-tag` to publish a draft by default. Keep the draft default when the user asked only for a draft or did not say. Use `--publish` when the user wants the release to go live and update the Sparkle appcast; a release approval that covers making the release live is that request. Before it, run `--publish --dry-run` and read `artifacts/release/<version>-<build>/appcast-dry-run.xml`. Then ask "publish now?" as [Publish now?](#publish-now) describes, and run `--create-tag --publish --confirm-publish` only after the user's plain yes.

## Publish now?

The user has a standing reservation on every Toastty release approval: the
release goes live only after a plain yes to "publish now?", asked right
before the first step that makes it visible to users. A general rule to
continue a release without another routine approval, such as one in your
global instructions, does not skip this question: it is the user's explicit
reservation, not a routine approval. Ask it also when the release approval
already covers publication, and also when the coordinator started the
release.

- **When.** After every check that comes before going live has passed: the
  candidate receipt, the final release notes, the `--publish --dry-run` feed
  item, and the relay and iPhone state checks. The next command is
  `publish-github-release.sh --create-tag --publish --confirm-publish`. A
  draft release, a dry run and a pushed tag do not reach users and need no
  yes.
- **How.** In a Toastty task, run
  `toastty task needs-reply --approval --question "<question>"` and end the
  turn. The user answers with the question's Approve or Decline card in the
  Mac Coordinator chat, by typing in the task, or by answering the
  coordinator, which passes the answer on. Outside a task, ask in the
  conversation and wait.
- **What the question says.** Start with "Publish now?". Name the version
  and build, the source commit, and what goes live: the GitHub release, the
  Sparkle update feed (existing users get the update), and the website's
  Download link, which follows the latest GitHub release. Name the website
  pull request if the release merges one in the next step. Say that yes
  makes the release live and that no keeps it unpublished.
- **What counts as yes.** Only the user's answer to this question, and
  only when its one meaning is yes, such as "yes" or "publish": an Approve
  card answer whose checked record matches this question (see
  `toastty-task-start`, "Who speaks to you"); the user's own words typed in
  the task after the question; or a message from the coordinator that says
  the user answered yes to this question. None of these is a yes: an
  answer to another question, such as one about a hold or a test; "looks
  fine", "testing passed" or "go ahead" said about something else; an
  approval given before you asked; a rule in the coordinator's policy; or a
  decision of the coordinator. When an answer is not clearly a yes to this
  question, ask it again.
- **One yes, one publish.** The yes covers the build, commit and steps that
  the question named. If any of them changes after the yes, such as a new
  build, a failed step that you retry with other inputs, or another
  version, ask again. A no, or no answer, leaves the release unpublished:
  report its state and wait.
- **No other route.** Before the yes, do not make the release visible any
  other way, such as `gh release edit --draft=false`, a hand edit of the
  appcast, or a merge of the release's website pull request.

## Important invariants

- Publish must use `artifacts/release/<version>-<build>/release-metadata.env`, not the current `HEAD`, to decide what commit gets tagged.
- Publish must use `artifacts/release/<version>-<build>/sparkle-metadata.env`, not ad-hoc shell values, to decide what gets written to the Sparkle appcast.
- `release-metadata.env` is the source of truth for:
  - `RELEASE_SOURCE_COMMIT`
  - `RELEASE_NOTES_PATH`
  - `RELEASE_GHOSTTY_COMMIT_SHORT`
  - `RELEASE_GHOSTTY_BUILD_FLAGS`
- `scripts/release/publish-github-release.sh` expects the notes file to exist, be non-empty, have exactly one `## Highlights` section with content in the supported Markdown subset, have no `{{placeholder}}` tokens, and include exact canonical Ghostty commit and build-flags lines before publication.
- With `--publish`, the update feed item's `description` is the Highlights as HTML, and the Sparkle update prompt shows it. To see the item before going live, run with `--publish --dry-run` and read `artifacts/release/<version>-<build>/appcast-dry-run.xml`.
- The release directory under `artifacts/release/<version>-<build>/` must remain intact from the earlier build phase.

## Validation

- Before publishing, confirm all three metadata files and the DMG exist and are non-empty.
- Before publishing, confirm `RELEASE_SOURCE_COMMIT` is reachable in the local clone.
- Before publishing, confirm the notes file exists at `RELEASE_NOTES_PATH`, is non-empty, has a `## Highlights` section with content, and includes the exact canonical Ghostty commit and build-flags lines from release metadata.
- Before `--publish`, confirm the earlier release order steps that the release needs.
- Before `--publish`, get the user's plain yes to "publish now?". The script refuses `--publish` without `--dry-run` unless `--confirm-publish` is also given; pass that flag only after the yes.
- Use `--dry-run` when you want to inspect the derived `git` and `gh` commands before creating the tag or release.
