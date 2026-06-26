#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT_DIR/scripts/automation/runtime-ownership.sh"

RUN_ID="${RUN_ID:-workspace-scope-smoke-$(date +%Y%m%d-%H%M%S)}"
RUNTIME_LABEL="$(toastty_sanitize_runtime_label "$RUN_ID")"
RESTORE_FRONT_APP_AFTER_LAUNCH="${TOASTTY_WORKSPACE_SCOPE_RESTORE_FRONT_APP:-1}"
DEV_RUN_ROOT="${DEV_RUN_ROOT:-$ROOT_DIR/artifacts/dev-runs/$RUN_ID}"
DERIVED_PATH="${DERIVED_PATH:-$DEV_RUN_ROOT/Derived}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$DEV_RUN_ROOT/artifacts}"
TOASTTY_RUNTIME_HOME="${TOASTTY_RUNTIME_HOME:-$DEV_RUN_ROOT/runtime-home}"
ARCH="${ARCH:-arm64}"

BOOTSTRAP_WORKTREE_SCRIPT="$ROOT_DIR/scripts/dev/bootstrap-worktree.sh"
APP_BINARY="$DERIVED_PATH/Build/Products/Debug/Toastty.app/Contents/MacOS/Toastty"
CLI_BINARY="$DERIVED_PATH/Build/Products/Debug/toastty"
INSTANCE_JSON="$TOASTTY_RUNTIME_HOME/instance.json"
LOG_FILE="$ARTIFACTS_DIR/app-${RUN_ID}.log"
SESSION_ID="workspace-scope-smoke-${RUN_ID}"
PREVIOUS_FRONT_BUNDLE_ID=""
FRONT_APP_RESTORE_DONE=0
SOCKET_PATH=""

mkdir -p "$ARTIFACTS_DIR" "$TOASTTY_RUNTIME_HOME"
rm -f "$INSTANCE_JSON" "$LOG_FILE"

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required for workspace scope smoke assertions" >&2
  exit 1
fi

frontmost_bundle_id() {
  local front_asn info
  front_asn="$(lsappinfo front 2>/dev/null || true)"
  [[ -n "$front_asn" ]] || return 0
  info="$(lsappinfo info -only bundleID "$front_asn" 2>/dev/null || true)"
  [[ -n "$info" ]] || return 0
  printf '%s\n' "$info" | sed -n 's/^"CFBundleIdentifier"="\(.*\)"$/\1/p'
}

restore_previous_front_app() {
  local normalized_restore_flag
  normalized_restore_flag="$(printf '%s' "$RESTORE_FRONT_APP_AFTER_LAUNCH" | tr '[:upper:]' '[:lower:]')"
  case "$normalized_restore_flag" in
    1|true|yes|on) ;;
    *) return 0 ;;
  esac
  [[ "$FRONT_APP_RESTORE_DONE" == "0" ]] || return 0
  [[ -n "$PREVIOUS_FRONT_BUNDLE_ID" && "$PREVIOUS_FRONT_BUNDLE_ID" != "com.GiantThings.toastty" ]] || return 0
  FRONT_APP_RESTORE_DONE=1
  open -b "$PREVIOUS_FRONT_BUNDLE_ID" >/dev/null 2>&1 || true
}

cleanup() {
  local exit_code=$?
  restore_previous_front_app
  if [[ -n "${APP_PID:-}" ]]; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi
  return "$exit_code"
}
trap cleanup EXIT

retry_command() {
  local attempts="$1"
  local delay_seconds="$2"
  shift 2

  local attempt status output
  for attempt in $(seq 1 "$attempts"); do
    if output="$("$@" 2>/dev/null)"; then
      printf '%s' "$output"
      return 0
    fi
    status=$?
    if [[ "$attempt" -lt "$attempts" ]]; then
      sleep "$delay_seconds"
      continue
    fi
    return "$status"
  done
}

cli_json() {
  "$CLI_BINARY" --socket-path "$SOCKET_PATH" --json "$@"
}

scoped_cli_json() {
  TOASTTY_SESSION_ID="$SESSION_ID" \
  TOASTTY_PANEL_ID="$INITIAL_PANEL_ID" \
  "$CLI_BINARY" --socket-path "$SOCKET_PATH" --json "$@"
}

launch_toastty_app() {
  local -a launch_command=(env)
  local key
  while IFS= read -r key; do
    case "$key" in
      TOASTTY_RUNTIME_HOME|TOASTTY_RUNTIME_LABEL|TOASTTY_DERIVED_PATH|TOASTTY_SKIP_QUIT_CONFIRMATION)
        ;;
      TOASTTY_*)
        launch_command+=("-u" "$key")
        ;;
    esac
  done < <(compgen -e | grep '^TOASTTY_' || true)

  launch_command+=(
    "TOASTTY_SKIP_QUIT_CONFIRMATION=1"
    "TOASTTY_RUNTIME_HOME=$TOASTTY_RUNTIME_HOME"
    "TOASTTY_RUNTIME_LABEL=$RUNTIME_LABEL"
    "TOASTTY_DERIVED_PATH=$DERIVED_PATH"
    "$APP_BINARY"
  )
  "${launch_command[@]}"
}

json_string() {
  local json="$1"
  local filter="$2"
  jq -r "$filter" <<<"$json"
}

assert_json_nonempty() {
  local json="$1"
  local filter="$2"
  local actual
  actual="$(json_string "$json" "$filter")"
  if [[ -z "$actual" || "$actual" == "null" ]]; then
    echo "error: expected non-empty value for $filter" >&2
    echo "$json" >&2
    exit 1
  fi
}

assert_json_equals() {
  local json="$1"
  local filter="$2"
  local expected="$3"
  local actual
  actual="$(json_string "$json" "$filter")"
  if [[ "$actual" != "$expected" ]]; then
    echo "error: expected $filter to equal '$expected', got '$actual'" >&2
    echo "$json" >&2
    exit 1
  fi
}

assert_json_array_contains() {
  local json="$1"
  local filter="$2"
  local expected="$3"
  if ! jq -e --arg expected "$expected" "$filter | index(\$expected) != null" <<<"$json" >/dev/null; then
    echo "error: expected $filter to contain '$expected'" >&2
    echo "$json" >&2
    exit 1
  fi
}

expect_scope_denied() {
  local output_file="$1"
  shift
  if "$@" >"$output_file"; then
    echo "error: expected scope_denied, but command succeeded" >&2
    cat "$output_file" >&2
    exit 1
  fi
  assert_json_equals "$(cat "$output_file")" '.error.code' "scope_denied"
}

cd "$ROOT_DIR"
PREVIOUS_FRONT_BUNDLE_ID="$(frontmost_bundle_id)"

"$BOOTSTRAP_WORKTREE_SCRIPT" >/dev/null
xcodebuild \
  -workspace toastty.xcworkspace \
  -scheme ToasttyApp \
  -configuration Debug \
  -destination "platform=macOS,arch=${ARCH}" \
  -derivedDataPath "$DERIVED_PATH" \
  build >/dev/null

if [[ ! -x "$APP_BINARY" || ! -x "$CLI_BINARY" ]]; then
  echo "error: expected built Toastty app and CLI under $DERIVED_PATH" >&2
  exit 1
fi

launch_toastty_app >"$LOG_FILE" 2>&1 &
APP_PID=$!

for _ in $(seq 1 200); do
  if ! kill -0 "$APP_PID" >/dev/null 2>&1; then
    break
  fi
  if [[ -f "$INSTANCE_JSON" ]]; then
    SOCKET_PATH="$(jq -r '.socketPath // empty' "$INSTANCE_JSON")"
    if [[ -n "$SOCKET_PATH" && -S "$SOCKET_PATH" ]]; then
      break
    fi
  fi
  sleep 0.1
done

if ! kill -0 "$APP_PID" >/dev/null 2>&1; then
  echo "error: launched Toastty instance exited before automation was ready" >&2
  tail -n 80 "$LOG_FILE" >&2 || true
  exit 1
fi
if [[ -z "$SOCKET_PATH" || ! -S "$SOCKET_PATH" ]]; then
  echo "error: socket not available for launched instance" >&2
  jq . "$INSTANCE_JSON" >&2 || true
  tail -n 80 "$LOG_FILE" >&2 || true
  exit 1
fi
toastty_assert_run_owned_instance "$INSTANCE_JSON" "$RUN_ID" "$TOASTTY_RUNTIME_HOME" "$SOCKET_PATH" 0

retry_command 50 0.2 cli_json action list >/dev/null
restore_previous_front_app

initial_snapshot="$(cli_json query run workspace.snapshot)"
INITIAL_WORKSPACE_ID="$(json_string "$initial_snapshot" '.result.workspaceID')"
assert_json_nonempty "$initial_snapshot" '.result.workspaceID'

initial_terminal_state="$(retry_command 40 0.25 cli_json query run terminal.state)"
INITIAL_PANEL_ID="$(json_string "$initial_terminal_state" '.result.panelID')"
assert_json_nonempty "$initial_terminal_state" '.result.panelID'

create_response="$(cli_json action run workspace.create title=Scope-Smoke-Out-Of-Scope)"
OTHER_WORKSPACE_ID="$(json_string "$create_response" '.result.workspaceID')"
assert_json_nonempty "$create_response" '.result.workspaceID'

other_terminal_state="$(retry_command 40 0.25 cli_json query run terminal.state)"
OTHER_PANEL_ID="$(json_string "$other_terminal_state" '.result.panelID')"
assert_json_nonempty "$other_terminal_state" '.result.panelID'

cli_json action run workspace.select "workspaceID=$INITIAL_WORKSPACE_ID" >/dev/null

cli_json session start --agent codex --panel "$INITIAL_PANEL_ID" --session "$SESSION_ID" >/dev/null

set_current_response="$(scoped_cli_json session scope set-current)"
assert_json_equals "$set_current_response" '.result.isScoped' "true"
if [[ "$(jq '.result.workspaceIDs | length' <<<"$set_current_response")" != "0" ]]; then
  echo "error: set-current should store an empty explicit scope" >&2
  echo "$set_current_response" >&2
  exit 1
fi
assert_json_array_contains "$set_current_response" '.result.effectiveWorkspaceIDs' "$INITIAL_WORKSPACE_ID"

denied_json="$ARTIFACTS_DIR/out-of-scope-denied.json"
expect_scope_denied "$denied_json" scoped_cli_json query run terminal.state --panel "$OTHER_PANEL_ID"

add_response="$(scoped_cli_json session scope add --workspace "$OTHER_WORKSPACE_ID")"
assert_json_equals "$add_response" '.result.isScoped' "true"
assert_json_array_contains "$add_response" '.result.workspaceIDs' "$OTHER_WORKSPACE_ID"

allowed_other_state="$(scoped_cli_json query run terminal.state --panel "$OTHER_PANEL_ID")"
assert_json_equals "$allowed_other_state" '.ok' "true"
assert_json_equals "$allowed_other_state" '.result.panelID' "$OTHER_PANEL_ID"

clear_response="$(scoped_cli_json session scope clear)"
assert_json_equals "$clear_response" '.result.isScoped' "false"

unrestricted_other_state="$(scoped_cli_json query run terminal.state --panel "$OTHER_PANEL_ID")"
assert_json_equals "$unrestricted_other_state" '.ok' "true"
assert_json_equals "$unrestricted_other_state" '.result.panelID' "$OTHER_PANEL_ID"

echo "ok: workspace scope smoke passed"
echo "  instance: $INSTANCE_JSON"
echo "  socket:   $SOCKET_PATH"
echo "  log:      $LOG_FILE"
echo "  denied:   $denied_json"
