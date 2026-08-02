#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: open-markdown-file.sh <path-to-markdown-file>
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 64
fi

if [[ -z "${TOASTTY_CLI_PATH:-}" ]]; then
  echo "error: TOASTTY_CLI_PATH is required" >&2
  exit 1
fi
if [[ ! -x "${TOASTTY_CLI_PATH}" ]]; then
  echo "error: TOASTTY_CLI_PATH is not executable: ${TOASTTY_CLI_PATH}" >&2
  exit 1
fi
if [[ -z "${TOASTTY_PANEL_ID:-}" ]]; then
  echo "error: TOASTTY_PANEL_ID is required" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required" >&2
  exit 1
fi

target_path="$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$1")"
target_lower="$(printf '%s' "$target_path" | tr '[:upper:]' '[:lower:]')"

case "$target_lower" in
  *.md|*.markdown|*.mdown|*.mkd)
    ;;
  *)
    echo "error: expected a markdown file (.md, .markdown, .mdown, .mkd): $target_path" >&2
    exit 1
    ;;
esac

if [[ ! -f "$target_path" ]]; then
  echo "error: file not found: $target_path" >&2
  exit 1
fi

workspace_id="$(
  "$TOASTTY_CLI_PATH" --json query run terminal.state --panel "$TOASTTY_PANEL_ID" \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["result"]["workspaceID"])'
)"

if [[ -z "$workspace_id" ]]; then
  echo "error: failed to resolve current workspace from panel $TOASTTY_PANEL_ID" >&2
  exit 1
fi

"$TOASTTY_CLI_PATH" action run panel.create.local-document \
  --workspace "$workspace_id" \
  "filePath=$target_path" >/dev/null

printf 'opened %s in workspace %s\n' "$target_path" "$workspace_id"
