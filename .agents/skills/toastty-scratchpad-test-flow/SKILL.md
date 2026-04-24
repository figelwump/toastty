---
name: toastty-scratchpad-test-flow
description: Use this skill when testing the Toastty Scratchpad agent flow from a Toastty-managed agent session, especially when the user asks to verify Scratchpad creation/update behavior, exercise `panel.scratchpad.set-content`, or confirm that agent-authored HTML/JavaScript renders in a session-linked Scratchpad panel.
---

# Toastty Scratchpad Test Flow

Use this to prove the agent-facing Scratchpad path works from inside a managed Toastty session.

## Core Flow

1. Require a Toastty-managed agent launch context:
   - `TOASTTY_CLI_PATH`
   - `TOASTTY_SESSION_ID`
2. Run the helper from the repo root:

```bash
.agents/skills/toastty-scratchpad-test-flow/scripts/run-scratchpad-agent-flow.sh
```

3. Check the helper summary:
   - first write should report `created=true`
   - second write should report `created=false`
   - `panelID` and `documentID` should stay the same
   - revision should advance
4. Ask the user to visually confirm the Scratchpad panel if needed. Expected UI behavior: a Scratchpad panel appears beside the source terminal, the terminal keeps focus after agent auto-create, and the second write updates the same panel.

## Custom Fixture Text

Pass a title and message when the user wants the visible content to identify a specific run:

```bash
.agents/skills/toastty-scratchpad-test-flow/scripts/run-scratchpad-agent-flow.sh \
  "Scratchpad Agent Flow Test" \
  "Testing the managed-session Scratchpad path"
```

## Failure Handling

- If `TOASTTY_CLI_PATH` or `TOASTTY_SESSION_ID` is missing, stop and explain that this skill must run from a Toastty-managed agent terminal.
- If the first write succeeds and the second fails, report the helper output and do not hide the partial Scratchpad creation.
- If the helper succeeds but the user cannot see the panel, query the returned `panelID` with `panel.scratchpad.state` and inspect the active Toastty runtime before rerunning.

## Manual Equivalent

The helper uses the same path an agent should use:

```bash
printf '%s' '<h1>Scratchpad test</h1>' \
  | "$TOASTTY_CLI_PATH" --json action run panel.scratchpad.set-content \
      --stdin content \
      "sessionID=$TOASTTY_SESSION_ID" \
      "title=Scratchpad Agent Flow Test"
```
