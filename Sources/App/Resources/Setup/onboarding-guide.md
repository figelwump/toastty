# Toastty Agent Setup Guide

This guide is meant to be read by an agent running in a Toastty pane. Narrate each step, show the user planned writes before applying changes, and wait for an explicit OK before running any future setup command with `--apply`.

## Start Here

Confirm the CLI and pane context:

```bash
test -x "$TOASTTY_CLI_PATH" && "$TOASTTY_CLI_PATH" doctor
```

If `TOASTTY_SESSION_ID` is present, this is a managed Toastty agent session. If it is missing, continue normally; many first-run users start from an unmanaged terminal pane.

## Available Setup Commands In This Build

- `toastty setup guide` prints this guide as readable text.
- `toastty setup guide --format md` prints this guide as Markdown.
- `toastty setup skills list` lists starter skills bundled with Toastty.
- `toastty setup print-skill <name>` previews a bundled skill's `SKILL.md`.

Installer commands are intentionally dry-run first when they are available. The agent should show the plan, ask for confirmation, then rerun the same command with `--apply`.

## Starter Skills

Install these first once `toastty setup install-skill` is available:

- `toastty-capabilities`: teaches future agents how to use Toastty's CLI, app-control catalog, workspace model, scoping, Scratchpad, local documents, browser panels, and notifications.
- `toastty-scratchpad`: helps agents publish visual HTML artifacts into the current Toastty workspace.
- `toastty-open-markdown`: helps agents open local Markdown files as Toastty document panels.

Preview them now:

```bash
"$TOASTTY_CLI_PATH" setup skills list
"$TOASTTY_CLI_PATH" setup print-skill toastty-capabilities
```

## Operating Rules

- Prefer `"$TOASTTY_CLI_PATH"` over a shell-resolved `toastty`; it targets the running app that launched the pane.
- Use `--json` when an agent needs structured output.
- Discover live app-control capabilities with `action list` and `query list`; do not rely on stale copied catalogs.
- Treat `scope_denied` as a cooperative workspace boundary. Stop and ask before expanding scope.
- Show planned file writes before applying setup changes. Canceling should keep already completed steps intact.

## Suggested Setup Flow

1. Orient the user: "I will dry-run each setup change, show the files, then ask before applying."
2. Check whether shell integration is already installed. If not, dry-run shell integration first, then apply after confirmation.
3. If the agent is Codex, dry-run Codex status hooks and mention that Codex may ask for trust once.
4. Offer starter skills. Install `toastty-capabilities` first, then ask whether the user wants Scratchpad and Markdown helpers.
5. Confirm the setup by launching a fresh agent pane and checking that Toastty tracks it.

## Optional Tour

After setup, ask whether the user wants a short tour:

- Open a Scratchpad and publish a small status artifact.
- Open a local Markdown file with `panel.create.local-document`.
- Open a browser panel with `panel.create.browser`.
- Show pane navigation and workspace shortcuts.

Keep the tour cancel-friendly. The user should be able to stop after any step without losing completed setup.
