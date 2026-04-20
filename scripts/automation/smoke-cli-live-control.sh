#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOOTSTRAP_WORKTREE_SCRIPT="$ROOT_DIR/scripts/dev/bootstrap-worktree.sh"
RUN_ID="${RUN_ID:-cli-live-control-$(date +%Y%m%d-%H%M%S)}"
RESTORE_FRONT_APP_AFTER_LAUNCH="${TOASTTY_CLI_LIVE_RESTORE_FRONT_APP:-1}"
DEV_RUN_ROOT="${DEV_RUN_ROOT:-$ROOT_DIR/artifacts/dev-runs/$RUN_ID}"
DERIVED_PATH="${DERIVED_PATH:-$DEV_RUN_ROOT/Derived}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$DEV_RUN_ROOT/artifacts}"
TOASTTY_RUNTIME_HOME="${TOASTTY_RUNTIME_HOME:-$DEV_RUN_ROOT/runtime-home}"
ARCH="${ARCH:-$(uname -m)}"
if [[ "$ARCH" != "arm64" && "$ARCH" != "x86_64" ]]; then
  ARCH="arm64"
fi

APP_BINARY="$DERIVED_PATH/Build/Products/Debug/Toastty.app/Contents/MacOS/Toastty"
CLI_BINARY="$DERIVED_PATH/Build/Products/Debug/toastty"
INSTANCE_JSON="$TOASTTY_RUNTIME_HOME/instance.json"
LOG_FILE="$ARTIFACTS_DIR/app-${RUN_ID}.log"
LOCAL_DOCUMENT_PATH="$ARTIFACTS_DIR/live-control-smoke.md"
BROWSER_URL='data:text/html,%3Chtml%3E%3Chead%3E%3Ctitle%3ECLI%20Smoke%20Browser%3C%2Ftitle%3E%3C%2Fhead%3E%3Cbody%20style%3D%22font-family%3A%20-ui-sans-serif%2C%20system-ui%3B%20padding%3A%2024px%3B%22%3E%3Ch1%3ECLI%20Smoke%20Browser%3C%2Fh1%3E%3Cp%3ELive%20control%20browser%20check.%3C%2Fp%3E%3C%2Fbody%3E%3C%2Fhtml%3E'
TERMINAL_SMOKE_MARKER="CLI_LIVE_CONTROL_MARKER"
PREVIOUS_FRONT_BUNDLE_ID=""
FRONT_APP_RESTORE_DONE=0
SOCKET_PATH=""

mkdir -p "$ARTIFACTS_DIR" "$TOASTTY_RUNTIME_HOME"
rm -f "$INSTANCE_JSON" "$LOG_FILE"

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required for live CLI smoke assertions" >&2
  exit 1
fi

frontmost_bundle_id() {
  local front_asn
  front_asn="$(lsappinfo front 2>/dev/null || true)"
  if [[ -z "$front_asn" ]]; then
    return 0
  fi

  local info
  info="$(lsappinfo info -only bundleID "$front_asn" 2>/dev/null || true)"
  if [[ -z "$info" ]]; then
    return 0
  fi

  printf '%s\n' "$info" | sed -n 's/^"CFBundleIdentifier"="\(.*\)"$/\1/p'
}

restore_previous_front_app() {
  local normalized_restore_flag
  normalized_restore_flag="$(printf '%s' "$RESTORE_FRONT_APP_AFTER_LAUNCH" | tr '[:upper:]' '[:lower:]')"
  case "$normalized_restore_flag" in
    1|true|yes|on)
      ;;
    *)
      return 0
      ;;
  esac
  if [[ "$FRONT_APP_RESTORE_DONE" == "1" ]]; then
    return 0
  fi
  if [[ -z "$PREVIOUS_FRONT_BUNDLE_ID" || "$PREVIOUS_FRONT_BUNDLE_ID" == "com.GiantThings.toastty" ]]; then
    return 0
  fi

  FRONT_APP_RESTORE_DONE=1
  open -b "$PREVIOUS_FRONT_BUNDLE_ID" >/dev/null 2>&1 || true
}

PREVIOUS_FRONT_BUNDLE_ID="$(frontmost_bundle_id)"

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

  local attempt output status
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

  return 1
}

cli_json() {
  "$CLI_BINARY" --socket-path "$SOCKET_PATH" --json "$@"
}

launch_toastty_app() {
  local -a launch_command=(env)
  local key
  while IFS= read -r key; do
    case "$key" in
      TOASTTY_RUNTIME_HOME|TOASTTY_DERIVED_PATH|TOASTTY_SKIP_QUIT_CONFIRMATION)
        ;;
      TOASTTY_*)
        launch_command+=("-u" "$key")
        ;;
    esac
  done < <(compgen -e | grep '^TOASTTY_' || true)

  # Start from a clean Toastty launch context so a caller's managed-agent env
  # does not force this smoke to reuse some other live socket or session.
  launch_command+=(
    "TOASTTY_SKIP_QUIT_CONFIRMATION=1"
    "TOASTTY_RUNTIME_HOME=$TOASTTY_RUNTIME_HOME"
    "TOASTTY_DERIVED_PATH=$DERIVED_PATH"
    "$APP_BINARY"
  )
  "${launch_command[@]}"
}

assert_catalog_contains() {
  local catalog_json="$1"
  local command_id="$2"
  if ! jq -e --arg id "$command_id" 'any(.result.commands[]?; .id == $id or (.aliases // [] | index($id) != null))' <<<"$catalog_json" >/dev/null; then
    echo "error: expected catalog to contain command id: $command_id" >&2
    echo "$catalog_json" >&2
    exit 1
  fi
}

assert_json_equals() {
  local json="$1"
  local filter="$2"
  local expected="$3"
  local actual
  actual="$(jq -r "$filter" <<<"$json")"
  if [[ "$actual" != "$expected" ]]; then
    echo "error: expected $filter to equal '$expected', got '$actual'" >&2
    echo "$json" >&2
    exit 1
  fi
}

assert_json_nonempty() {
  local json="$1"
  local filter="$2"
  local actual
  actual="$(jq -r "$filter" <<<"$json")"
  if [[ -z "$actual" || "$actual" == "null" ]]; then
    echo "error: expected non-empty value for filter: $filter" >&2
    echo "$json" >&2
    exit 1
  fi
}

cd "$ROOT_DIR"

cat > "$LOCAL_DOCUMENT_PATH" <<'EOF'
# CLI Live Control Smoke

This file was opened by `scripts/automation/smoke-cli-live-control.sh`.
EOF

if ! "$BOOTSTRAP_WORKTREE_SCRIPT" >/dev/null; then
  exit 1
fi

xcodebuild \
  -workspace toastty.xcworkspace \
  -scheme ToasttyApp \
  -configuration Debug \
  -destination "platform=macOS,arch=${ARCH}" \
  -derivedDataPath "$DERIVED_PATH" \
  build >/dev/null

if [[ ! -x "$APP_BINARY" ]]; then
  echo "error: expected app binary at $APP_BINARY" >&2
  exit 1
fi
if [[ ! -x "$CLI_BINARY" ]]; then
  echo "error: expected CLI binary at $CLI_BINARY" >&2
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
  echo "error: launched Toastty instance exited before live CLI became ready" >&2
  tail -n 80 "$LOG_FILE" >&2 || true
  exit 1
fi
if [[ ! -f "$INSTANCE_JSON" ]]; then
  echo "error: instance manifest not found: $INSTANCE_JSON" >&2
  tail -n 80 "$LOG_FILE" >&2 || true
  exit 1
fi
if [[ -z "$SOCKET_PATH" || ! -S "$SOCKET_PATH" ]]; then
  echo "error: socket not available for launched instance" >&2
  jq . "$INSTANCE_JSON" >&2 || true
  tail -n 80 "$LOG_FILE" >&2 || true
  exit 1
fi

if ! retry_command 50 0.2 cli_json action list >/dev/null; then
  echo "error: launched Toastty instance did not respond to live CLI requests" >&2
  exit 1
fi

restore_previous_front_app

action_catalog="$(cli_json action list)"
assert_catalog_contains "$action_catalog" "window.sidebar.toggle"
assert_catalog_contains "$action_catalog" "workspace.create"
assert_catalog_contains "$action_catalog" "panel.create.local-document"
assert_catalog_contains "$action_catalog" "terminal.send-text"

query_catalog="$(cli_json query list)"
assert_catalog_contains "$query_catalog" "workspace.snapshot"
assert_catalog_contains "$query_catalog" "terminal.visible-text"
assert_catalog_contains "$query_catalog" "panel.local-document.state"
assert_catalog_contains "$query_catalog" "panel.browser.state"

initial_snapshot="$(cli_json query run workspace.snapshot)"
initial_workspace_id="$(jq -r '.result.workspaceID' <<<"$initial_snapshot")"
assert_json_nonempty "$initial_snapshot" '.result.workspaceID'

initial_terminal_state="$(retry_command 40 0.25 cli_json query run terminal.state)"
initial_terminal_panel_id="$(jq -r '.result.panelID // empty' <<<"$initial_terminal_state")"
assert_json_nonempty "$initial_terminal_state" '.result.panelID'
assert_json_nonempty "$initial_terminal_state" '.result.shell'

cli_json action run workspace.create title=CLI-Smoke >/dev/null
cli_json action run workspace.select index=2 >/dev/null

selected_snapshot="$(retry_command 30 0.1 cli_json query run workspace.snapshot)"
selected_workspace_id="$(jq -r '.result.workspaceID' <<<"$selected_snapshot")"
if [[ "$selected_workspace_id" == "$initial_workspace_id" ]]; then
  echo "error: workspace selection did not move to the created workspace" >&2
  echo "$selected_snapshot" >&2
  exit 1
fi

cli_json action run workspace.rename title=CLI-Smoke-Renamed >/dev/null
cli_json action run window.sidebar.toggle >/dev/null
cli_json action run window.sidebar.toggle >/dev/null

cli_json action run panel.create.local-document "filePath=$LOCAL_DOCUMENT_PATH" placement=newTab >/dev/null
local_document_state="$(retry_command 40 0.25 cli_json query run panel.local-document.state)"
assert_json_equals "$local_document_state" '.result.stateFilePath' "$LOCAL_DOCUMENT_PATH"

cli_json action run panel.create.browser "url=$BROWSER_URL" placement=newTab >/dev/null
browser_state="$(retry_command 40 0.25 cli_json query run panel.browser.state)"
assert_json_equals "$browser_state" '.result.stateRestorableURL' "$BROWSER_URL"

terminal_state="$(retry_command 40 0.25 cli_json query run terminal.state --panel "$initial_terminal_panel_id")"
assert_json_nonempty "$terminal_state" '.result.panelID'
assert_json_nonempty "$terminal_state" '.result.shell'

retry_command 40 0.25 cli_json action run terminal.send-text --panel "$initial_terminal_panel_id" "text=echo $TERMINAL_SMOKE_MARKER" submit=true >/dev/null
visible_text_state="$(retry_command 40 0.25 cli_json query run terminal.visible-text --panel "$initial_terminal_panel_id" "contains=$TERMINAL_SMOKE_MARKER")"
if [[ "$(jq -r '.result.contains' <<<"$visible_text_state")" != "true" ]]; then
  echo "error: terminal visible text did not contain smoke marker" >&2
  echo "$visible_text_state" >&2
  exit 1
fi

cli_json action run config.reload >/dev/null

echo "ok: live CLI smoke passed"
echo "  instance: $INSTANCE_JSON"
echo "  socket:   $SOCKET_PATH"
echo "  log:      $LOG_FILE"
