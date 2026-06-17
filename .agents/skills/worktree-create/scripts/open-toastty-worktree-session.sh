#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: open-toastty-worktree-session.sh --workspace-name <name> --worktree-path <path> --handoff-file <path> [--window-id <uuid>] [--agent-command <name>] [--initial-command <command>]... [--startup-command <command>] [--json]

Creates a new Toastty workspace for a worktree and starts a new terminal command in it.
By default the helper calls agent.launch with structured cwd, environment, and
initialPrompt values. The agent CLI is codex unless --agent-command overrides it.
Repeat --initial-command to run single-line shell commands after cwd setup and
before the agent command in the structured launch path.
--startup-command replaces the structured launch with a literal terminal command
and cannot be combined with --agent-command or --initial-command.
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
agent_command="codex"
agent_command_overridden=0
startup_command=""
initial_commands=()
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
    --agent-command)
      agent_command="${2:-}"
      agent_command_overridden=1
      shift 2
      ;;
    --initial-command)
      if [[ -z "${2:-}" ]]; then
        echo "error: --initial-command requires a non-empty command" >&2
        exit 64
      fi
      if [[ "${2//[[:space:]]/}" == "" ]]; then
        echo "error: --initial-command requires a non-blank command" >&2
        exit 64
      fi
      if [[ "$2" == *$'\n'* || "$2" == *$'\r'* ]]; then
        echo "error: --initial-command must be a single-line command" >&2
        exit 64
      fi
      initial_commands+=("$2")
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
if [[ "$agent_command_overridden" == "1" && -n "$startup_command" ]]; then
  echo "error: --agent-command cannot be combined with --startup-command" >&2
  usage
  exit 64
fi
if [[ "${#initial_commands[@]}" -gt 0 && -n "$startup_command" ]]; then
  echo "error: --initial-command cannot be combined with --startup-command" >&2
  usage
  exit 64
fi
if [[ -z "$agent_command" || "$agent_command" =~ [[:space:]] ]]; then
  echo "error: --agent-command must be a single executable name without whitespace" >&2
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

relative_handoff_path() {
  if [[ "$handoff_file" == "$worktree_path/"* ]]; then
    printf '%s\n' "${handoff_file#"$worktree_path"/}"
  else
    printf '%s\n' "$handoff_file"
  fi
}

build_initial_prompt() {
  local relative_handoff
  relative_handoff="$(relative_handoff_path)"
  printf 'Read %s in the repo, use it as the source of truth for this handoff, and continue the task in this worktree.' "$relative_handoff"
}

build_default_startup_command() {
  local quoted_worktree quoted_prompt quoted_derived quoted_agent initial_prompt
  quoted_worktree="$(shell_quote "$worktree_path")"
  quoted_derived="$(shell_quote "$worktree_path/artifacts/dev-runs/manual/Derived")"
  quoted_agent="$(shell_quote "$agent_command")"
  initial_prompt="$(build_initial_prompt)"
  quoted_prompt="$(shell_quote "$initial_prompt")"
  printf "cd %s && export TOASTTY_DEV_WORKTREE_ROOT=%s TOASTTY_DERIVED_PATH=%s && %s %s" \
    "$quoted_worktree" \
    "$quoted_worktree" \
    "$quoted_derived" \
    "$quoted_agent" \
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
  initial_prompt="$(build_initial_prompt)"
else
  initial_prompt=""
fi

if [[ -z "$window_id" ]]; then
  window_id="$(resolve_current_window_id)"
fi

create_output=""
if ! create_output="$(run_cli_json action run workspace.create --window "$window_id" "title=$workspace_name" activate=false 2>&1)"; then
  echo "error: failed to create workspace: $create_output" >&2
  exit 1
fi
if ! workspace_id="$(extract_json_result_field "workspaceID" <<<"$create_output" 2>/dev/null)"; then
  echo "error: failed to parse workspaceID from workspace.create response" >&2
  printf '%s\n' "$create_output" >&2
  exit 1
fi

if [[ -z "$workspace_id" ]]; then
  echo "error: failed to resolve created workspace after workspace creation" >&2
  exit 1
fi

if [[ -f "$handoff_file" ]]; then
  local_document_output=""
  if ! local_document_output="$(
    "$TOASTTY_CLI_PATH" action run panel.create.local-document \
      --workspace "$workspace_id" \
      "filePath=$handoff_file" 2>&1
  )"; then
    echo "error: failed to open handoff document for workspace $workspace_id" >&2
    printf '%s\n' "$local_document_output" >&2
    exit 1
  fi
fi

terminal_available="false"
panel_id=""
launch_command=""

if [[ -z "$startup_command" ]]; then
  launch_output=""
  launch_succeeded="false"
  launch_args=(
    action run agent.launch
    --workspace "$workspace_id"
    "profileID=$agent_command"
    "cwd=$worktree_path"
    "env.TOASTTY_DEV_WORKTREE_ROOT=$worktree_path"
    "env.TOASTTY_DERIVED_PATH=$worktree_path/artifacts/dev-runs/manual/Derived"
  )
  if [[ "${#initial_commands[@]}" -gt 0 ]]; then
    for initial_command in "${initial_commands[@]}"; do
      launch_args+=("initialCommands=$initial_command")
    done
  fi
  launch_args+=("initialPrompt=$initial_prompt")

  for attempt in $(seq 1 40); do
    if launch_output="$(
      run_cli_json "${launch_args[@]}" 2>&1
    )"; then
      launch_succeeded="true"
      break
    fi
    sleep 0.25
  done

  if [[ "$launch_succeeded" == "true" ]]; then
    panel_id="$(extract_json_result_field "panelID" <<<"$launch_output")"
    launch_command="$(extract_json_result_field "command" <<<"$launch_output")"
    startup_command="$launch_command"
    terminal_available="true"
  elif [[ "$agent_command" == "codex" || "$agent_command" == "claude" ]]; then
    echo "error: failed to launch managed agent with agent.launch: $launch_output" >&2
    exit 1
  else
    echo "warning: agent.launch failed for '$agent_command'; falling back to terminal.send-text" >&2
    startup_command="$(build_default_startup_command)"
  fi
fi

if [[ "$terminal_available" != "true" ]]; then
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
