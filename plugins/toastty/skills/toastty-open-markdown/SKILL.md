---
name: toastty-open-markdown
description: Use this skill when you want to show the user a markdown file in Toastty for review, such as a plan, design doc, or architecture note, by opening it as a local-document panel in the current workspace through the Toastty CLI.
---

# Toastty Open Markdown

Use this when you have already written a markdown file and want the user to review it inside Toastty instead of reading it in chat.

## Core flow

1. Require the managed Toastty skill root. Do not guess a repository, global
   skill directory, or Codex cache location:

```bash
if [[ -z "${TOASTTY_SKILLS_ROOT:-}" || ! -d "$TOASTTY_SKILLS_ROOT/toastty-open-markdown" ]]; then
  echo "error: toastty-open-markdown must run inside a Toastty-managed agent session" >&2
  exit 1
fi
```

2. Confirm the target file exists and is a markdown file.
3. Require a Toastty-managed agent launch context:
   - `TOASTTY_CLI_PATH`
   - `TOASTTY_PANEL_ID`
4. Resolve the current workspace from the current terminal panel.
5. Open the file as a local-document panel in that workspace with the bundled helper:

```bash
"$TOASTTY_SKILLS_ROOT/toastty-open-markdown/scripts/open-markdown-file.sh" path/to/file.md
```

6. Tell the user which file you opened.

## Important invariants

- Use the canonical app-control action `panel.create.local-document`.
- Omit `placement` so Toastty uses the default placement for that workspace.
- Target the current workspace derived from `TOASTTY_PANEL_ID`; do not guess a workspace ID.
- Use this for markdown review artifacts such as plans, design notes, architecture docs, or implementation writeups.
- If `TOASTTY_SKILLS_ROOT` or another required Toastty launch value is missing,
  stop and explain that the skill must run inside a Toastty-managed agent
  session. Never fall back to `.agents/skills`, `~/.agents/skills`,
  `~/.codex/skills`, or a plugin cache path.

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
