# Toastty Agent Setup Guide

This guide is meant to be read by an agent running in a Toastty pane. Narrate each step, dry-run every setup command first, show the planned writes, and wait for an explicit OK before rerunning anything with `--apply`.

If the user cancels, stop cleanly. Completed steps stay valid; do not undo work unless the user asks.

## Phase 0: Orient

Confirm the CLI and pane context:

```bash
test -x "$TOASTTY_CLI_PATH" && "$TOASTTY_CLI_PATH" doctor
```

`doctor` is a top-level diagnostic command. The setup commands available after that probe are listed below.

Use your detected agent identity for tone only. Check whether `TOASTTY_SESSION_ID` is present, but do not gate setup on it. Fresh users are often unmanaged because shell integration is not installed yet, and that is expected.

Tell the user what will happen:

- Shell integration comes first because it keeps Toastty's launcher shim ahead of later shell startup changes.
- You will dry-run, show the plan, then ask before writing files.
- Codex may need global status hooks; other supported managed agents get status integration at launch.
- Skills are installed as pristine starters. Tailoring can happen later, organically.

## Available Setup Commands In This Build

- `toastty setup guide` prints this guide as readable text.
- `toastty setup guide --format md` prints this guide as Markdown.
- `toastty setup skills list` lists starter skills bundled with Toastty.
- `toastty setup print-skill <name>` previews a bundled skill's `SKILL.md`.
- `toastty setup install-shell-integration [--shell zsh|bash|fish] [--apply]` installs shell integration.
- `toastty setup install-hooks --agent codex [--apply]` installs Codex status hooks.
- `toastty setup install-skill <name> [--runtime claude|codex|all] [--apply]` installs bundled starter skills.

Prefer `"$TOASTTY_CLI_PATH"` over a shell-resolved `toastty`; it targets the running app that launched the pane. Add `--json` when structured output is more useful than text.

## Phase 1: Make It Work

Dry-run shell integration first:

```bash
"$TOASTTY_CLI_PATH" setup install-shell-integration
```

Show the planned writes and warnings. After explicit approval, rerun the same command with `--apply`. If the user needs a specific shell, add `--shell zsh`, `--shell bash`, or `--shell fish`.

If the agent is Codex, dry-run status hooks next and warn that Codex may ask the user to trust the hook once:

```bash
"$TOASTTY_CLI_PATH" setup install-hooks --agent codex
```

After approval, apply with `--apply`. For Claude Code, OpenCode, MiMo Code, and Pi, explain that Toastty injects status integration when those agents are launched through Toastty; no global hook install is needed.

Offer Terminal profiles as optional manual setup. Ask whether the user wants quick launchers for common terminal actions such as tmux, zellij, ssh, or REPLs with environment loaded. Do not block the setup flow if the user skips profiles.

Confirm that setup is live by launching an agent in a fresh Toastty pane. Supported agents can usually use their own resume option, such as `--resume`, to continue the conversation after the fresh launch. A tracked agent should appear in Toastty with live status.

## Phase 2: Install Starter Skills

List the bundled skills and preview the centerpiece:

```bash
"$TOASTTY_CLI_PATH" setup skills list
"$TOASTTY_CLI_PATH" setup print-skill toastty-capabilities
```

Install `toastty-capabilities` first into the runtime or runtimes the user chooses. Dry-run the selected install, show files and conflicts, ask for approval, then apply:

```bash
"$TOASTTY_CLI_PATH" setup install-skill toastty-capabilities --runtime all
```

When you ask for the OK to apply, restate in one or two plain sentences what the skill does and why the user would want it — a new user will not remember the list from earlier. For `toastty-capabilities`, say something like: "This skill teaches agents like me how to drive Toastty itself — creating workspaces and panels, launching agents, showing visual output, and notifying you — so agents can automate your Toastty workflows for you."

After approval, rerun with `--apply`.

Offer these optional convenience skills after capabilities is handled:

- `toastty-scratchpad`: publish visual HTML artifacts into the current Toastty workspace.
- `toastty-open-markdown`: open local Markdown files as Toastty document panels.

Install each chosen skill the same way: one dry-run, one visible plan, a one-sentence reminder of what the skill does, one explicit OK before `--apply`. Do not build a custom skill matrix during setup; install the pristine starter and let the user tailor it later if a real workflow emerges.

## Phase 3: Optional Tour

Ask whether the user wants a short tour. Keep it cancel-friendly and stop after any step if the user says to stop.

- Scratchpad: managed sessions only. If `TOASTTY_SESSION_ID` is missing, defer this until the user launches a tracked agent. Otherwise publish a small status card with `panel.scratchpad.set-content`.
- Local document: open a "what we set up" summary with `panel.create.local-document`.
- Browser: open a useful page with `panel.create.browser`.
- Shortcuts: show the command palette, agent navigation, focus mode, and common pane navigation only if the user wants to try them.
- Workspace scope: panel, Scratchpad, terminal, browser, local-document, workspace, and agent-launch actions are workspace-scoped when the caller session is scoped. If Toastty returns `scope_denied`, stop and ask before expanding scope.

Discover live app-control details before composing tour commands:

```bash
"$TOASTTY_CLI_PATH" --json action list
"$TOASTTY_CLI_PATH" --json query list
```

Use action descriptors for current parameters. Do not copy a stale catalog into the tour.

## Operating Rules

- Narrate what you are about to do before doing it.
- Show planned file writes before applying setup changes.
- Wait for an explicit OK before every `--apply`.
- Prefer `"$TOASTTY_CLI_PATH"` for all Toastty commands.
- Treat `scope_denied` as a cooperative workspace boundary, not an error to work around.
- Canceling keeps already completed progress intact.
