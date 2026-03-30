#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOOTSTRAP_WORKTREE_SCRIPT="$ROOT_DIR/scripts/dev/bootstrap-worktree.sh"
RUN_ID="${RUN_ID:-workspace-tabs-smoke-$(date +%Y%m%d-%H%M%S)}"
FIXTURE="${FIXTURE:-workspace-tabs-wide}"
RESTORE_FRONT_APP_AFTER_LAUNCH="${TOASTTY_WORKSPACE_TABS_RESTORE_FRONT_APP:-1}"
DEV_RUN_ROOT="${DEV_RUN_ROOT:-$ROOT_DIR/artifacts/dev-runs/$RUN_ID}"
DERIVED_PATH="${DERIVED_PATH:-$DEV_RUN_ROOT/Derived}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$DEV_RUN_ROOT/artifacts}"
TOASTTY_RUNTIME_HOME="${TOASTTY_RUNTIME_HOME:-$DEV_RUN_ROOT/runtime-home}"
SOCKET_PATH="${SOCKET_PATH:-/tmp/tt-${RUN_ID##workspace-tabs-smoke-}.sock}"
ARCH="${ARCH:-$(uname -m)}"
if [[ "$ARCH" != "arm64" && "$ARCH" != "x86_64" ]]; then
  ARCH="arm64"
fi

READY_FILE="$ARTIFACTS_DIR/automation-ready-${RUN_ID}.json"
APP_BINARY="$DERIVED_PATH/Build/Products/Debug/Toastty.app/Contents/MacOS/Toastty"
LOG_FILE="$ARTIFACTS_DIR/app-${RUN_ID}.log"
GHOSTTY_DEBUG_XCFRAMEWORK_PATH="$ROOT_DIR/Dependencies/GhosttyKit.Debug.xcframework"
GHOSTTY_RELEASE_XCFRAMEWORK_PATH="$ROOT_DIR/Dependencies/GhosttyKit.Release.xcframework"
GHOSTTY_XCFRAMEWORK_PATH=""
GHOSTTY_INTEGRATION_DISABLED="${TUIST_DISABLE_GHOSTTY:-${TOASTTY_DISABLE_GHOSTTY:-0}}"
RESTORE_GHOSTTY_ENABLED_WORKSPACE=0
PREVIOUS_FRONT_BUNDLE_ID=""
FRONT_APP_RESTORE_DONE=0

mkdir -p "$ARTIFACTS_DIR" "$TOASTTY_RUNTIME_HOME" "$(dirname "$SOCKET_PATH")"
rm -f "$SOCKET_PATH" "$READY_FILE" "$LOG_FILE"

if ! command -v nc >/dev/null 2>&1; then
  echo "error: nc is required for socket requests" >&2
  exit 1
fi

if ! command -v uuidgen >/dev/null 2>&1; then
  echo "error: uuidgen is required for request ids" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required for workspace-tabs smoke assertions" >&2
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "error: swift is required for screenshot assertions" >&2
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

  if [[ "$RESTORE_GHOSTTY_ENABLED_WORKSPACE" == "1" ]]; then
    if ! (
      unset TUIST_DISABLE_GHOSTTY TOASTTY_DISABLE_GHOSTTY
      "$BOOTSTRAP_WORKTREE_SCRIPT" >/dev/null
    ); then
      echo "warning: failed to restore Ghostty-enabled workspace after workspace-tabs smoke run" >&2
    fi
  fi
  return "$exit_code"
}
trap cleanup EXIT

cd "$ROOT_DIR"

if ! "$BOOTSTRAP_WORKTREE_SCRIPT" >/dev/null; then
  exit 1
fi

if [[ -f "$GHOSTTY_DEBUG_XCFRAMEWORK_PATH/Info.plist" ]]; then
  GHOSTTY_XCFRAMEWORK_PATH="$GHOSTTY_DEBUG_XCFRAMEWORK_PATH"
elif [[ -f "$GHOSTTY_RELEASE_XCFRAMEWORK_PATH/Info.plist" ]]; then
  GHOSTTY_XCFRAMEWORK_PATH="$GHOSTTY_RELEASE_XCFRAMEWORK_PATH"
fi
if [[ "$GHOSTTY_INTEGRATION_DISABLED" == "1" && -n "$GHOSTTY_XCFRAMEWORK_PATH" ]]; then
  RESTORE_GHOSTTY_ENABLED_WORKSPACE=1
fi

xcodebuild \
  -workspace toastty.xcworkspace \
  -scheme ToasttyApp \
  -configuration Debug \
  -destination "platform=macOS,arch=${ARCH}" \
  -derivedDataPath "$DERIVED_PATH" \
  build >/dev/null

TOASTTY_AUTOMATION=1 \
TOASTTY_SKIP_QUIT_CONFIRMATION=1 \
TOASTTY_RUNTIME_HOME="$TOASTTY_RUNTIME_HOME" \
TOASTTY_SOCKET_PATH="$SOCKET_PATH" \
TOASTTY_DERIVED_PATH="$DERIVED_PATH" \
"$APP_BINARY" \
  --automation \
  --skip-quit-confirmation \
  --run-id "$RUN_ID" \
  --fixture "$FIXTURE" \
  --artifacts-dir "$ARTIFACTS_DIR" \
  --disable-animations >"$LOG_FILE" 2>&1 &
APP_PID=$!

for _ in $(seq 1 200); do
  if [[ -S "$SOCKET_PATH" && -f "$READY_FILE" ]]; then
    break
  fi
  sleep 0.1
done

if [[ ! -f "$READY_FILE" ]]; then
  echo "error: readiness file not found: $READY_FILE" >&2
  exit 1
fi
if [[ ! -S "$SOCKET_PATH" ]]; then
  echo "error: socket not available: $SOCKET_PATH" >&2
  exit 1
fi

restore_previous_front_app

send_request() {
  local command="$1"
  local payload="$2"
  local request_id
  request_id="$(uuidgen)"

  local request
  request="{\"protocolVersion\":\"1.0\",\"kind\":\"request\",\"requestID\":\"${request_id}\",\"command\":\"${command}\",\"payload\":${payload}}"

  local response
  response="$(printf '%s\n' "$request" | nc -U -w 2 "$SOCKET_PATH")"
  if [[ -z "$response" ]]; then
    echo "error: no response for command ${command}" >&2
    exit 1
  fi
  if ! echo "$response" | grep -qE '"ok"[[:space:]]*:[[:space:]]*true'; then
    echo "error: command failed (${command}): $response" >&2
    exit 1
  fi
  printf '%s' "$response"
}

extract_string_field() {
  local json="$1"
  local field="$2"
  echo "$json" | jq -r --arg field "$field" '(.result[$field] // .[$field] // empty) | select(type == "string")'
}

extract_int_field() {
  local json="$1"
  local field="$2"
  echo "$json" | jq -r --arg field "$field" '(.result[$field] // .[$field] // empty) | select(type == "number") | floor'
}

assert_tab_snapshot() {
  local expected_count="$1"
  local expected_selected_index="$2"
  local response
  response="$(send_request "automation.workspace_snapshot" '{}')"

  local actual_count
  actual_count="$(extract_int_field "$response" "tabCount")"
  if [[ "$actual_count" != "$expected_count" ]]; then
    echo "error: expected tab count ${expected_count}, got ${actual_count:-missing}" >&2
    echo "snapshot response: $response" >&2
    exit 1
  fi

  if [[ -n "$expected_selected_index" ]]; then
    local actual_selected_index
    actual_selected_index="$(extract_int_field "$response" "selectedTabIndex")"
    if [[ "$actual_selected_index" != "$expected_selected_index" ]]; then
      echo "error: expected selected tab index ${expected_selected_index}, got ${actual_selected_index:-missing}" >&2
      echo "snapshot response: $response" >&2
      exit 1
    fi
  fi
}

perform_action() {
  local action="$1"
  local args_json="${2:-}"
  if [[ -z "$args_json" ]]; then
    args_json='{}'
  fi
  local payload
  payload="$(jq -cn --arg action "$action" --argjson args "$args_json" '{action: $action, args: $args}')"
  send_request "automation.perform_action" "$payload" >/dev/null
}

capture_screenshot() {
  local step="$1"
  local response
  response="$(send_request "automation.capture_screenshot" "{\"step\":\"${step}\",\"fixture\":\"${FIXTURE}\"}")"
  local path
  path="$(extract_string_field "$response" "path")"
  if [[ -z "$path" || ! -f "$path" ]]; then
    echo "error: screenshot path missing or file not found" >&2
    echo "screenshot response: $response" >&2
    exit 1
  fi
  printf '%s\n' "$path"
}

capture_state() {
  local response
  response="$(send_request "automation.dump_state" '{}')"
  local path
  path="$(extract_string_field "$response" "path")"
  if [[ -z "$path" || ! -f "$path" ]]; then
    echo "error: state dump path missing or file not found" >&2
    echo "state response: $response" >&2
    exit 1
  fi
  printf '%s\n' "$path"
}

send_request "automation.ping" '{}' >/dev/null
send_request "automation.load_fixture" "{\"name\":\"${FIXTURE}\"}" >/dev/null

assert_tab_snapshot 1 1
SINGLE_TAB_SCREENSHOT_PATH="$(capture_screenshot "workspace-tabs-1")"

perform_action "workspace.tab.new"
perform_action "workspace.tab.select" '{"index":1}'
assert_tab_snapshot 2 1
TWO_TABS_SCREENSHOT_PATH="$(capture_screenshot "workspace-tabs-2")"

perform_action "window.sidebar.toggle"
HIDDEN_SIDEBAR_STATE_PATH="$(capture_state)"
if ! jq -e '.windows[0].sidebarVisible == false' "$HIDDEN_SIDEBAR_STATE_PATH" >/dev/null; then
  echo "error: expected hidden sidebar state after toggle" >&2
  echo "state dump: $HIDDEN_SIDEBAR_STATE_PATH" >&2
  exit 1
fi
TWO_TABS_HIDDEN_SIDEBAR_SCREENSHOT_PATH="$(capture_screenshot "workspace-tabs-2-hidden-sidebar")"

perform_action "workspace.tab.select" '{"index":2}'
assert_tab_snapshot 2 2
perform_action "workspace.tab.close" '{"index":2}'
assert_tab_snapshot 1 1

send_request "automation.load_fixture" "{\"name\":\"${FIXTURE}\"}" >/dev/null
assert_tab_snapshot 1 1

for _ in $(seq 1 8); do
  perform_action "workspace.tab.new"
done
perform_action "workspace.tab.select" '{"index":1}'
assert_tab_snapshot 9 1
NINE_TABS_SCREENSHOT_PATH="$(capture_screenshot "workspace-tabs-9")"

perform_action "workspace.tab.select" '{"index":9}'
assert_tab_snapshot 9 9

perform_action "workspace.tab.new"
perform_action "workspace.tab.select" '{"index":1}'
assert_tab_snapshot 10 1
TEN_TABS_SCREENSHOT_PATH="$(capture_screenshot "workspace-tabs-10")"

perform_action "workspace.tab.select" '{"index":10}'
assert_tab_snapshot 10 10
perform_action "workspace.tab.close" '{"index":10}'
assert_tab_snapshot 9 ""

swift "$ROOT_DIR/scripts/automation/assert-workspace-tabs.swift" \
  "$SINGLE_TAB_SCREENSHOT_PATH" \
  "$TWO_TABS_SCREENSHOT_PATH" \
  "$TWO_TABS_HIDDEN_SIDEBAR_SCREENSHOT_PATH" \
  "$NINE_TABS_SCREENSHOT_PATH" \
  "$TEN_TABS_SCREENSHOT_PATH"

echo "ready file: $READY_FILE"
echo "socket path: $SOCKET_PATH"
echo "single-tab screenshot: $SINGLE_TAB_SCREENSHOT_PATH"
echo "two-tab screenshot: $TWO_TABS_SCREENSHOT_PATH"
echo "two-tab hidden-sidebar screenshot: $TWO_TABS_HIDDEN_SIDEBAR_SCREENSHOT_PATH"
echo "nine-tab screenshot: $NINE_TABS_SCREENSHOT_PATH"
echo "ten-tab screenshot: $TEN_TABS_SCREENSHOT_PATH"
echo "app log: $LOG_FILE"
