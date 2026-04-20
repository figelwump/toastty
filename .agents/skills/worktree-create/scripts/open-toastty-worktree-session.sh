#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: open-toastty-worktree-session.sh --workspace-name <name> --worktree-path <path> --handoff-file <path> [--window-id <uuid>] [--startup-command <command>] [--json]

Creates a new Toastty workspace for a worktree and starts a new terminal command in it.
EOF
}

if [[ -z "${TOASTTY_CLI_PATH:-}" ]]; then
  echo "error: TOASTTY_CLI_PATH is required" >&2
  exit 1
fi
if [[ ! -x "${TOASTTY_CLI_PATH}" ]]; then
  echo "error: TOASTTY_CLI_PATH is not executable: ${TOASTTY_CLI_PATH}" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required" >&2
  exit 1
fi

workspace_name=""
worktree_path=""
handoff_file=""
window_id=""
startup_command=""
json_output=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace-name)
      workspace_name="${2:-}"
      shift 2
      ;;
    --worktree-path)
      worktree_path="${2:-}"
      shift 2
      ;;
    --handoff-file)
      handoff_file="${2:-}"
      shift 2
      ;;
    --window-id)
      window_id="${2:-}"
      shift 2
      ;;
    --startup-command)
      startup_command="${2:-}"
      shift 2
      ;;
    --json)
      json_output=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 64
      ;;
  esac
done

if [[ -z "$workspace_name" || -z "$worktree_path" || -z "$handoff_file" ]]; then
  echo "error: --workspace-name, --worktree-path, and --handoff-file are required" >&2
  usage
  exit 64
fi

worktree_path="$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$worktree_path")"
handoff_file="$(python3 -c 'import os, sys; print(os.path.abspath(sys.argv[1]))' "$handoff_file")"

if [[ ! -d "$worktree_path" ]]; then
  echo "error: worktree path not found: $worktree_path" >&2
  exit 1
fi
if [[ ! -f "$handoff_file" ]]; then
  echo "error: handoff file not found: $handoff_file" >&2
  exit 1
fi
if [[ ! -s "$handoff_file" ]]; then
  echo "error: handoff file is empty: $handoff_file" >&2
  exit 1
fi

shell_quote() {
  python3 - "$1" <<'PY'
import shlex
import sys
print(shlex.quote(sys.argv[1]))
PY
}

build_default_startup_command() {
  local quoted_worktree quoted_prompt quoted_derived relative_handoff
  quoted_worktree="$(shell_quote "$worktree_path")"
  quoted_derived="$(shell_quote "$worktree_path/artifacts/dev-runs/manual/Derived")"
  if [[ "$handoff_file" == "$worktree_path/"* ]]; then
    relative_handoff="${handoff_file#"$worktree_path"/}"
  else
    relative_handoff="$handoff_file"
  fi
  quoted_prompt="$(shell_quote "Read ${relative_handoff} in the repo, use it as the source of truth for this handoff, and continue the task in this worktree.")"
  printf "cd %s && export TOASTTY_DEV_WORKTREE_ROOT=%s TOASTTY_DERIVED_PATH=%s && cdx %s" \
    "$quoted_worktree" \
    "$quoted_worktree" \
    "$quoted_derived" \
    "$quoted_prompt"
}

run_cli_json() {
  "$TOASTTY_CLI_PATH" --json "$@"
}

extract_json_result_field() {
  local field_name="$1"
  python3 -c '
import json
import sys

field_name = sys.argv[1]
data = json.load(sys.stdin)
value = data.get("result", {}).get(field_name)
if not isinstance(value, str) or value == "":
    raise SystemExit(f"missing {field_name}")
print(value)
' "$field_name"
}

resolve_current_window_id() {
  if [[ -z "${TOASTTY_PANEL_ID:-}" ]]; then
    echo "error: TOASTTY_PANEL_ID is required when --window-id is omitted" >&2
    exit 1
  fi

  local output resolved_window_id
  if ! output="$(run_cli_json query run terminal.state --panel "$TOASTTY_PANEL_ID" 2>&1)"; then
    echo "error: failed to resolve current window from panel ${TOASTTY_PANEL_ID}" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  if ! resolved_window_id="$(extract_json_result_field "windowID" <<<"$output" 2>/dev/null)"; then
    echo "error: Toastty returned an invalid terminal.state payload for panel ${TOASTTY_PANEL_ID}" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi

  printf '%s\n' "$resolved_window_id"
}

retry_json_result_field() {
  local attempts="$1"
  local delay_seconds="$2"
  local field_name="$3"
  shift 3

  local attempt output extracted
  for attempt in $(seq 1 "$attempts"); do
    if output="$("$@" 2>/dev/null)"; then
      if extracted="$(extract_json_result_field "$field_name" <<<"$output" 2>/dev/null)"; then
        printf '%s\n' "$extracted"
        return 0
      fi
    fi
    if [[ "$attempt" -lt "$attempts" ]]; then
      sleep "$delay_seconds"
      continue
    fi
    return 1
  done

  return 1
}

if [[ -z "$startup_command" ]]; then
  startup_command="$(build_default_startup_command)"
fi

if [[ -z "$window_id" ]]; then
  window_id="$(resolve_current_window_id)"
fi

create_output=""
if ! create_output="$("$TOASTTY_CLI_PATH" action run workspace.create --window "$window_id" "title=$workspace_name" 2>&1)"; then
  echo "error: failed to create workspace: $create_output" >&2
  exit 1
fi

snapshot_args=(query run workspace.snapshot)
snapshot_args+=(--window "$window_id")

workspace_id="$(
  retry_json_result_field \
    30 \
    0.2 \
    workspaceID \
    run_cli_json "${snapshot_args[@]}"
)"

if [[ -z "$workspace_id" ]]; then
  echo "error: failed to resolve selected workspace after workspace creation" >&2
  exit 1
fi

panel_id="$(
  retry_json_result_field \
    40 \
    0.25 \
    panelID \
    run_cli_json query run terminal.state --workspace "$workspace_id"
)"

if [[ -z "$panel_id" ]]; then
  echo "error: failed to resolve terminal panel in workspace $workspace_id" >&2
  exit 1
fi

terminal_available="false"
send_text_output=""
for attempt in $(seq 1 20); do
  send_text_output="$(
    run_cli_json action run terminal.send-text \
      --panel "$panel_id" \
      "text=$startup_command" \
      submit=true \
      allowUnavailable=true
  )"
  terminal_available="$(python3 -c 'import json, sys; print(str(json.load(sys.stdin)["result"]["available"]).lower())' <<<"$send_text_output")"
  if [[ "$terminal_available" == "true" ]]; then
    break
  fi
  sleep 0.2
done

if [[ "$terminal_available" != "true" ]]; then
  echo "error: terminal surface stayed unavailable for panel $panel_id" >&2
  exit 1
fi

if [[ "$json_output" == "1" ]]; then
  python3 - "$workspace_name" "$worktree_path" "$handoff_file" "$window_id" "$workspace_id" "$panel_id" "$startup_command" "$terminal_available" <<'PY'
import json
import sys

workspace_name, worktree_path, handoff_file, window_id, workspace_id, panel_id, startup_command, terminal_available = sys.argv[1:]
payload = {
    "workspace_name": workspace_name,
    "worktree_path": worktree_path,
    "handoff_file": handoff_file,
    "window_id": window_id or None,
    "workspace_id": workspace_id,
    "panel_id": panel_id,
    "startup_command": startup_command,
    "terminal_available": terminal_available == "true",
}
print(json.dumps(payload, indent=2, sort_keys=True))
PY
else
  cat <<EOF
workspace_name=$workspace_name
worktree_path=$worktree_path
handoff_file=$handoff_file
window_id=$window_id
workspace_id=$workspace_id
panel_id=$panel_id
terminal_available=$terminal_available
EOF
fi
