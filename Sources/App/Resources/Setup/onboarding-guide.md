# Toastty Agent Setup Guide

This guide is meant to be read by an agent running in a Toastty pane. Narrate each step, dry-run every setup installer first, show the planned writes, and wait for an explicit OK before rerunning anything with `--apply`.

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
- Codex may need global status hooks; other supported managed agents get status integration at launch. Cursor receives a launch-scoped plugin, so Toastty does not change `~/.cursor/hooks.json`.
- Toastty makes six shipped skills available automatically to new supported managed agent launches. User-authored skills can be added under `~/.toastty/skills`.

## Available Setup Commands In This Build

- `toastty setup guide` prints this guide as readable text.
- `toastty setup guide --format md` prints this guide as Markdown.
- `toastty setup skills list` lists the shipped and user-authored skills available to new supported managed launches, including diagnostics for excluded user packages.
- `toastty setup install-shell-integration [--shell zsh|bash|fish] [--dry-run | --apply]` installs shell integration.
- `toastty setup install-hooks --agent codex [--dry-run | --apply]` installs Codex status hooks.

Prefer `"$TOASTTY_CLI_PATH"` over a shell-resolved `toastty`; it targets the running app that launched the pane. Add `--json` when structured output is more useful than text.

Install commands without `--apply` are already dry runs, but pass `--dry-run` explicitly anyway: it keeps the read-only intent visible in the command itself, to the user and to any command-approval tooling in your runtime. `--dry-run` and `--apply` are mutually exclusive.

## Phase 1: Make It Work

Dry-run shell integration first:

```bash
"$TOASTTY_CLI_PATH" setup install-shell-integration --dry-run
```

Show the planned writes and warnings. After explicit approval, rerun the same command with `--apply` in place of `--dry-run`. If the user needs a specific shell, add `--shell zsh`, `--shell bash`, or `--shell fish`.

If the agent is Codex, dry-run status hooks next and warn that Codex may ask the user to trust the hook once:

```bash
"$TOASTTY_CLI_PATH" setup install-hooks --agent codex --dry-run
```

After approval, apply with `--apply`. For Claude Code, Cursor, OpenCode, MiMo Code, and Pi, explain that Toastty injects status integration when those agents are launched through Toastty; no global hook install is needed. For Cursor, use the unique `cursor-agent` command rather than the generic `agent` alias.

Offer Terminal profiles as optional manual setup. Ask whether the user wants quick launchers for common terminal actions such as tmux, zellij, ssh, or REPLs with environment loaded. Do not block the setup flow if the user skips profiles.

Confirm that setup is live by launching an agent in a fresh Toastty pane. Supported agents can usually use their own resume option, such as `--resume`, to continue the conversation after the fresh launch. A tracked agent should appear in Toastty with live status.

## Phase 2: Review Automatic Skills

No skills installation is required. List what Toastty will make available to new supported managed Codex, Claude Code, Cursor, OpenCode, MiMo Code, and Pi launches:

```bash
"$TOASTTY_CLI_PATH" setup skills list
```

The shipped set is `toastty-capabilities`, `toastty-open-markdown`, `toastty-scratchpad`, `toastty-send-diagnostics`, `worktree-create`, and `worktree-done`. Toastty delivers these only for the new managed process and does not write them into `~/.codex/skills`, `~/.claude/skills`, `~/.cursor/skills`, or `~/.agents/skills`.

To add a user skill, create `~/.toastty/skills/<name>/SKILL.md` with `name` and `description` YAML frontmatter, then rerun `setup skills list`. Fix any exclusion diagnostic before launching a new agent. `Toastty > Manage Toastty Skills…` offers the same inventory plus folder and rescan controls.

Running sessions keep the skills they launched with; editing or adding a skill takes effect on the next supported managed launch. Unsupported launch shapes and provisioning failures deliberately proceed without Toastty skills. If old unnamespaced Toastty copies appear alongside the `toastty:` skills, remove those separately installed copies manually; Toastty never inspects or changes global skill folders.

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
- Pass `--dry-run` explicitly on setup installer commands when previewing, even though it is the default.
- Wait for an explicit OK before every `--apply`.
- Prefer `"$TOASTTY_CLI_PATH"` for all Toastty commands.
- Treat `scope_denied` as a cooperative workspace boundary, not an error to work around.
- Canceling keeps already completed progress intact.
