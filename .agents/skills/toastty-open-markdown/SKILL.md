---
name: toastty-open-markdown
description: Use this skill when you want to show the user a markdown file in Toastty for review, such as a plan, design doc, or architecture note, by opening it as a local-document panel in the current workspace through the Toastty CLI.
---

# Toastty Open Markdown

Use this when you have already written a markdown file and want the user to review it inside Toastty instead of reading it in chat.

## Core flow

1. Confirm the target file exists and is a markdown file.
2. Require a Toastty-managed agent launch context:
   - `TOASTTY_CLI_PATH`
   - `TOASTTY_PANEL_ID`
3. Resolve the current workspace from the current terminal panel.
4. Open the file as a local-document panel in that workspace with the bundled helper:

```bash
.agents/skills/toastty-open-markdown/scripts/open-markdown-file.sh path/to/file.md
```

5. Tell the user which file you opened.

## Important invariants

- Use the canonical app-control action `panel.create.local-document`.
- Omit `placement` so Toastty uses the default placement for that workspace.
- Target the current workspace derived from `TOASTTY_PANEL_ID`; do not guess a workspace ID.
- Use this for markdown review artifacts such as plans, design notes, architecture docs, or implementation writeups.
- If the required Toastty launch context is missing, stop and explain that the skill requires a Toastty-managed agent session.

## Manual equivalent

If you need to run the flow inline instead of using the helper:

```bash
workspace_id="$(
  "$TOASTTY_CLI_PATH" --json query run terminal.state --panel "$TOASTTY_PANEL_ID" \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["result"]["workspaceID"])'
)"

"$TOASTTY_CLI_PATH" action run panel.create.local-document \
  --workspace "$workspace_id" \
  "filePath=/absolute/path/to/file.md"
```
