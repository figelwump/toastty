#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: open-toastty-worktree-session.sh --workspace-name <name> --worktree-path <path> --handoff-file <path> [--window-id <uuid>] [--agent-command <name>] [--model <model>] [--reasoning-effort <effort>] [--initial-command <command>]... [--startup-command <command>] [--no-scope-parent] [--json]

Creates a new Toastty workspace for a worktree and starts a new terminal command in it.
By default the helper calls agent.launch with structured cwd, environment, and
initialPrompt values. The agent CLI preserves TOASTTY_AGENT=codex|claude,
falls back to codex, and allows --agent-command to override it.
Repeat --initial-command to run single-line shell commands after cwd setup and
before the agent command in the structured launch path.
--startup-command replaces the structured launch with a literal terminal command
and cannot be combined with --agent-command, --initial-command, --model, or
--reasoning-effort. Model and reasoning overrides require live agent.launch
capability metadata for the selected profile and never use a terminal fallback.
Structured launches scope the current parent session before creating the child
workspace unless --no-scope-parent is passed. They initialize git-branch
(when Git metadata is available) and task-status workspace annotations.
Explicit --startup-command launches do not manage task annotations.
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

# Keep syntax checks aligned with AgentLaunchArgumentOverrideAdapter.validatedValue.
validate_launch_selection() {
  python3 - "$1" "$2" <<'PYTHON'
import sys
import unicodedata

flag, value = sys.argv[1:]
trimmed = value.strip()
if not trimmed:
    message = "value must not be blank"
elif len(value.encode("utf-8")) > 256:
    message = "value exceeds 256 UTF-8 bytes"
elif trimmed.startswith("-"):
    message = "value must not start with '-'"
elif any(unicodedata.category(character) in ("Cc", "Cf") for character in value):
    message = "control characters are not supported"
else:
    raise SystemExit(0)
print(f"error: {flag}: {message}", file=sys.stderr)
raise SystemExit(64)
PYTHON
}

workspace_name=""
worktree_path=""
handoff_file=""
window_id=""
agent_command=""
agent_command_overridden=0
model=""
reasoning_effort=""
startup_command_overridden=0
startup_command=""
initial_commands=()
scope_parent="true"
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
    --model|--reasoning-effort)
      if [[ $# -lt 2 ]]; then
        echo "error: $1 requires a non-blank value" >&2
        exit 64
      fi
      validate_launch_selection "$1" "$2"
      if [[ "$1" == "--model" ]]; then
        model="$2"
      else
        reasoning_effort="$2"
      fi
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
      startup_command_overridden=1
      startup_command="${2:-}"
      shift 2
      ;;
    --no-scope-parent)
      scope_parent="false"
      shift
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

if [[ "$agent_command_overridden" != "1" ]]; then
  case "${TOASTTY_AGENT:-}" in
    codex|claude)
      agent_command="$TOASTTY_AGENT"
      ;;
    *)
      agent_command="codex"
      ;;
  esac
fi

if [[ -z "$workspace_name" || -z "$worktree_path" || -z "$handoff_file" ]]; then
  echo "error: --workspace-name, --worktree-path, and --handoff-file are required" >&2
  usage
  exit 64
fi
if [[ "$startup_command_overridden" == "1" && ( -n "$model" || -n "$reasoning_effort" ) ]]; then
  echo "error: --model and --reasoning-effort cannot be combined with --startup-command" >&2
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

branch_label=""
if [[ -z "$startup_command" ]]; then
  if ! branch_label="$(git -C "$worktree_path" symbolic-ref --quiet --short HEAD 2>/dev/null)"; then
    if revision="$(git -C "$worktree_path" rev-parse --short HEAD 2>/dev/null)"; then
      branch_label="Detached at $revision"
    else
      echo "warning: Git metadata unavailable at $worktree_path; only task status will be annotated" >&2
    fi
  fi
  branch_label="$(PYTHONUTF8=1 python3 -c 'import sys; s=sys.argv[1]; print(s if len(s)<=80 else s[:77]+"...")' "$branch_label")"
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
  local quoted_worktree quoted_prompt quoted_agent initial_prompt
  quoted_worktree="$(shell_quote "$worktree_path")"
  quoted_agent="$(shell_quote "$agent_command")"
  initial_prompt="$(build_initial_prompt)"
  quoted_prompt="$(shell_quote "$initial_prompt")"
  printf "cd %s && %s %s" \
    "$quoted_worktree" \
    "$quoted_agent" \
    "$quoted_prompt"
}

run_cli_json() {
  "$TOASTTY_CLI_PATH" --json "$@"
}

# Verify overrides before changing parent scope or creating a workspace.
if [[ -n "$model" || -n "$reasoning_effort" ]]; then
  if ! capabilities="$(run_cli_json action list)"; then
    echo "error: could not inspect agent.launch capabilities; no child was launched" >&2
    exit 1
  fi
  if ! python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    if data.get("ok") is not True:
        raise ValueError("action list returned an error")
    commands = data["result"]["commands"]
    launch = next(c for c in commands if c.get("id") == "agent.launch")
    for name, value in (("model", sys.argv[2]), ("reasoningEffort", sys.argv[3])):
        if not value:
            continue
        parameter = next((p for p in launch["parameters"] if p.get("name") == name), None)
        profiles = parameter.get("supportedProfileIDs") if parameter else None
        if not isinstance(profiles, list) or sys.argv[1] not in profiles:
            raise ValueError(f"agent.launch does not advertise {name} support for profile {sys.argv[1]}")
except (ValueError, TypeError, KeyError, AttributeError, StopIteration) as error:
    print(f"error: cannot apply requested launch selections: {error}", file=sys.stderr)
    raise SystemExit(1)
' "$agent_command" "$model" "$reasoning_effort" <<<"$capabilities"; then
    exit 1
  fi
fi

# Annotation actions are checked even if a CLI returns an error envelope with exit 0.
run_annotation_cli() {
  local response
  if ! response="$(run_cli_json "$@")"; then
    printf '%s\n' "$response" >&2
    return 1
  fi
  if ! python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    valid = isinstance(data, dict) and data.get("ok") is True
except (ValueError, TypeError):
    valid = False
raise SystemExit(0 if valid else 1)
' <<<"$response"; then
    printf '%s\n' "$response" >&2
    return 1
  fi
}

workspace_id=""
task_status_initialized="false"
child_launched="false"
parent_session_id=""
parent_scope_set="false"
parent_scope_rollback_on_error="false"

rollback_parent_scope_if_needed() {
  local exit_code="$?"
  if [[ "$exit_code" -ne 0 && "$task_status_initialized" == "true" && "$child_launched" != "true" ]]; then
    if ! run_annotation_cli action run workspace.set-annotation --workspace "$workspace_id" key=task-status "text=Needs attention"; then
      echo "warning: could not mark workspace $workspace_id as needing attention after launch failure" >&2
    fi
  fi
  if [[ "$exit_code" -ne 0 && "$parent_scope_rollback_on_error" == "true" && "$parent_scope_set" == "true" && -n "$parent_session_id" ]]; then
    local rollback_output
    if ! rollback_output="$(run_cli_json session scope clear --session "$parent_session_id" 2>&1)"; then
      echo "warning: failed to restore parent session unrestricted scope after launch failure" >&2
      printf '%s\n' "$rollback_output" >&2
    fi
  fi
}

trap rollback_parent_scope_if_needed EXIT

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

extract_json_result_bool() {
  local field_name="$1"
  python3 -c '
import json
import sys

field_name = sys.argv[1]
data = json.load(sys.stdin)
value = data.get("result", {}).get(field_name)
if not isinstance(value, bool):
    raise SystemExit(f"missing {field_name}")
print("true" if value else "false")
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

parent_scope_status="startup_command"

if [[ -z "$startup_command" ]]; then
  if [[ "$scope_parent" == "true" ]]; then
    parent_session_id="${TOASTTY_SESSION_ID:-}"
    if [[ -z "$parent_session_id" ]]; then
      echo "error: TOASTTY_SESSION_ID is required to scope the parent session; pass --no-scope-parent to leave the parent unrestricted" >&2
      exit 1
    fi
    if [[ -z "${TOASTTY_PANEL_ID:-}" ]]; then
      echo "error: TOASTTY_PANEL_ID is required to scope the parent session; pass --no-scope-parent to leave the parent unrestricted" >&2
      exit 1
    fi

    parent_scope_output=""
    parent_scope_stderr_file="$(mktemp "${TMPDIR:-/tmp}/toastty-parent-scope-show.XXXXXX")"
    if ! parent_scope_output="$(run_cli_json session scope show --session "$parent_session_id" 2>"$parent_scope_stderr_file")"; then
      echo "error: failed to inspect parent session scope for $parent_session_id" >&2
      if [[ -s "$parent_scope_stderr_file" ]]; then
        cat "$parent_scope_stderr_file" >&2
      fi
      printf '%s\n' "$parent_scope_output" >&2
      rm -f "$parent_scope_stderr_file"
      exit 1
    fi
    if [[ -s "$parent_scope_stderr_file" ]]; then
      cat "$parent_scope_stderr_file" >&2
    fi
    rm -f "$parent_scope_stderr_file"

    if ! parent_is_scoped="$(extract_json_result_bool "isScoped" <<<"$parent_scope_output" 2>/dev/null)"; then
      echo "error: Toastty returned an invalid session scope payload for parent session $parent_session_id" >&2
      printf '%s\n' "$parent_scope_output" >&2
      exit 1
    fi

    if [[ "$parent_is_scoped" == "true" ]]; then
      parent_scope_status="already_scoped"
    else
      parent_scope_set_output=""
      if ! parent_scope_set_output="$(run_cli_json session scope set-current --session "$parent_session_id" 2>&1)"; then
        echo "error: failed to scope parent session $parent_session_id to its current workspace" >&2
        printf '%s\n' "$parent_scope_set_output" >&2
        exit 1
      fi
      parent_scope_status="set_current"
      parent_scope_set="true"
      parent_scope_rollback_on_error="true"
    fi
  else
    parent_scope_status="disabled"
  fi
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

if [[ -z "$startup_command" ]]; then
  # Stable keys share the runtime's existing color claims; never supply a new color.
  if ! run_annotation_cli query run annotation.keys \
    || ! run_annotation_cli query run workspace.snapshot --workspace "$workspace_id"; then
    echo "error: could not inspect annotations for created workspace $workspace_id; no child was launched" >&2
    exit 1
  fi
  if [[ -n "$branch_label" ]] && ! run_annotation_cli action run workspace.set-annotation --workspace "$workspace_id" key=git-branch "text=$branch_label"; then
    echo "error: could not initialize annotations for created workspace $workspace_id; no child was launched" >&2
    exit 1
  fi
  if ! run_annotation_cli action run workspace.set-annotation --workspace "$workspace_id" key=task-status text=Working; then
    echo "error: could not initialize annotations for created workspace $workspace_id; no child was launched" >&2
    exit 1
  fi
  # Set before launching: a fast child must not have its newer status overwritten.
  task_status_initialized="true"
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
session_id=""
launch_command=""
scope_set="false"

if [[ -z "$startup_command" ]]; then
  launch_output=""
  launch_succeeded="false"
  launch_args=(
    action run agent.launch
    --workspace "$workspace_id"
    "profileID=$agent_command"
    "cwd=$worktree_path"
  )
  if [[ "${#initial_commands[@]}" -gt 0 ]]; then
    for initial_command in "${initial_commands[@]}"; do
      launch_args+=("initialCommands=$initial_command")
    done
  fi
  if [[ -n "$model" ]]; then
    launch_args+=("model=$model")
  fi
  if [[ -n "$reasoning_effort" ]]; then
    launch_args+=("reasoningEffort=$reasoning_effort")
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
    child_launched="true"
    panel_id="$(extract_json_result_field "panelID" <<<"$launch_output")"
    if ! session_id="$(extract_json_result_field "sessionID" <<<"$launch_output" 2>/dev/null)"; then
      echo "error: agent.launch response did not include sessionID; cannot scope workspace handoff" >&2
      echo "warning: workspace $workspace_id and panel $panel_id were already created; the child may be running without the intended workspace-only scope" >&2
      printf '%s\n' "$launch_output" >&2
      exit 1
    fi
    launch_command="$(extract_json_result_field "command" <<<"$launch_output")"
    startup_command="$launch_command"
    terminal_available="true"

    scope_output=""
    if ! scope_output="$(
      run_cli_json session scope set \
        --session "$session_id" \
        --workspace "$workspace_id" 2>&1
    )"; then
      echo "error: failed to scope session $session_id to workspace $workspace_id" >&2
      echo "warning: workspace $workspace_id and session $session_id were already created; the child may be running without the intended workspace-only scope" >&2
      printf '%s\n' "$scope_output" >&2
      exit 1
    fi
    scope_set="true"
  elif [[ "$agent_command" == "codex" || "$agent_command" == "claude" || -n "$model" || -n "$reasoning_effort" ]]; then
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
  python3 - "$workspace_name" "$worktree_path" "$handoff_file" "$window_id" "$workspace_id" "$panel_id" "$session_id" "$scope_set" "$startup_command" "$terminal_available" "$parent_scope_status" "$parent_scope_set" "$model" "$reasoning_effort" <<'PY'
import json
import sys

workspace_name, worktree_path, handoff_file, window_id, workspace_id, panel_id, session_id, scope_set, startup_command, terminal_available, parent_scope_status, parent_scope_set, model, reasoning_effort = sys.argv[1:]
payload = {
    "workspace_name": workspace_name,
    "worktree_path": worktree_path,
    "handoff_file": handoff_file,
    "window_id": window_id or None,
    "workspace_id": workspace_id,
    "panel_id": panel_id,
    "session_id": session_id or None,
    "scope_set": scope_set == "true",
    "model": model or None,
    "reasoning_effort": reasoning_effort or None,
    "terminal_available": terminal_available == "true",
    "parent_scope_status": parent_scope_status,
    "parent_scope_set": parent_scope_set == "true",
}
if not model and not reasoning_effort:
    payload["startup_command"] = startup_command
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
session_id=$session_id
scope_set=$scope_set
parent_scope_status=$parent_scope_status
parent_scope_set=$parent_scope_set
terminal_available=$terminal_available
model=$model
reasoning_effort=$reasoning_effort
EOF
fi
