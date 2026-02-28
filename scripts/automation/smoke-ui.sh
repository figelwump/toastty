#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_ID="${RUN_ID:-smoke-$(date +%Y%m%d-%H%M%S)}"
FIXTURE="${FIXTURE:-split-workspace}"
DERIVED_PATH="${DERIVED_PATH:-$ROOT_DIR/Derived}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$ROOT_DIR/artifacts/automation}"
SOCKET_PATH="${SOCKET_PATH:-${TMPDIR:-/tmp}/toastty-$(id -u)/events-v1.sock}"
ARCH="${ARCH:-$(uname -m)}"
if [[ "$ARCH" != "arm64" && "$ARCH" != "x86_64" ]]; then
  ARCH="arm64"
fi

READY_FILE="$ARTIFACTS_DIR/automation-ready-${RUN_ID}.json"
APP_BINARY="$DERIVED_PATH/Build/Products/Debug/ToasttyApp.app/Contents/MacOS/ToasttyApp"
LOG_FILE="$ARTIFACTS_DIR/app-${RUN_ID}.log"
GHOSTTY_XCFRAMEWORK_PATH="$ROOT_DIR/Dependencies/GhosttyKit.xcframework"

mkdir -p "$ARTIFACTS_DIR"
rm -f "$SOCKET_PATH" "$READY_FILE" "$LOG_FILE"

if ! command -v nc >/dev/null 2>&1; then
  echo "error: nc is required for socket requests" >&2
  exit 1
fi

cleanup() {
  if [[ -n "${APP_PID:-}" ]]; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

cd "$ROOT_DIR"

tuist generate >/dev/null
xcodebuild \
  -workspace toastty.xcworkspace \
  -scheme ToasttyApp \
  -configuration Debug \
  -destination "platform=macOS,arch=${ARCH}" \
  -derivedDataPath "$DERIVED_PATH" \
  build >/dev/null

TOASTTY_AUTOMATION=1 \
TOASTTY_SOCKET_PATH="$SOCKET_PATH" \
"$APP_BINARY" \
  --automation \
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

send_request() {
  local command="$1"
  local payload="$2"
  local request_id
  request_id="$(uuidgen)"

  local request
  request="{\"protocolVersion\":\"1.0\",\"kind\":\"request\",\"requestID\":\"${request_id}\",\"command\":\"${command}\",\"payload\":${payload}}"

  local response
  response="$(printf '%s\n' "$request" | nc -U "$SOCKET_PATH")"
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
  echo "$json" | sed -nE "s/.*\"${field}\":[[:space:]]*\"([^\"]+)\".*/\\1/p" | sed 's#\\/#/#g'
}

extract_bool_field() {
  local json="$1"
  local field="$2"
  echo "$json" | sed -nE "s/.*\"${field}\":[[:space:]]*(true|false).*/\\1/p"
}

extract_int_field() {
  local json="$1"
  local field="$2"
  echo "$json" | sed -nE "s/.*\"${field}\":[[:space:]]*(-?[0-9]+).*/\\1/p"
}

send_request "automation.ping" '{}'
send_request "automation.load_fixture" "{\"name\":\"${FIXTURE}\"}"

WORKSPACE_BASELINE_RESPONSE="$(send_request "automation.workspace_snapshot" '{}')"
BASELINE_PANE_COUNT="$(extract_int_field "$WORKSPACE_BASELINE_RESPONSE" "paneCount")"
BASELINE_FOCUSED_PANEL_ID="$(extract_string_field "$WORKSPACE_BASELINE_RESPONSE" "focusedPanelID")"
if [[ -z "$BASELINE_PANE_COUNT" || -z "$BASELINE_FOCUSED_PANEL_ID" ]]; then
  echo "error: failed to read baseline workspace snapshot" >&2
  echo "snapshot response: ${WORKSPACE_BASELINE_RESPONSE}" >&2
  exit 1
fi

if (( BASELINE_PANE_COUNT > 1 )); then
  send_request "automation.perform_action" '{"action":"workspace.focus-pane.next"}'
  FOCUS_NEXT_RESPONSE="$(send_request "automation.workspace_snapshot" '{}')"
  NEXT_FOCUSED_PANEL_ID="$(extract_string_field "$FOCUS_NEXT_RESPONSE" "focusedPanelID")"
  if [[ -z "$NEXT_FOCUSED_PANEL_ID" ]]; then
    echo "error: focused panel missing after workspace.focus-pane.next" >&2
    echo "snapshot response: ${FOCUS_NEXT_RESPONSE}" >&2
    exit 1
  fi
  if [[ "$NEXT_FOCUSED_PANEL_ID" == "$BASELINE_FOCUSED_PANEL_ID" ]]; then
    echo "error: workspace.focus-pane.next did not change focused panel" >&2
    echo "baseline focused panel: ${BASELINE_FOCUSED_PANEL_ID}" >&2
    echo "snapshot response: ${FOCUS_NEXT_RESPONSE}" >&2
    exit 1
  fi

  send_request "automation.perform_action" '{"action":"workspace.focus-pane.previous"}'
  FOCUS_PREVIOUS_RESPONSE="$(send_request "automation.workspace_snapshot" '{}')"
  PREVIOUS_FOCUSED_PANEL_ID="$(extract_string_field "$FOCUS_PREVIOUS_RESPONSE" "focusedPanelID")"
  if [[ "$PREVIOUS_FOCUSED_PANEL_ID" != "$BASELINE_FOCUSED_PANEL_ID" ]]; then
    echo "error: workspace.focus-pane.previous did not return focus to baseline panel" >&2
    echo "baseline focused panel: ${BASELINE_FOCUSED_PANEL_ID}" >&2
    echo "snapshot response: ${FOCUS_PREVIOUS_RESPONSE}" >&2
    exit 1
  fi
else
  echo "note: skipping focus-next/previous assertions for single-pane fixture"
fi

send_request "automation.perform_action" '{"action":"workspace.split.right"}'
SPLIT_RIGHT_RESPONSE="$(send_request "automation.workspace_snapshot" '{}')"
SPLIT_RIGHT_PANE_COUNT="$(extract_int_field "$SPLIT_RIGHT_RESPONSE" "paneCount")"
if [[ -z "$SPLIT_RIGHT_PANE_COUNT" ]]; then
  echo "error: pane count missing after workspace.split.right" >&2
  echo "snapshot response: ${SPLIT_RIGHT_RESPONSE}" >&2
  exit 1
fi
if (( SPLIT_RIGHT_PANE_COUNT <= BASELINE_PANE_COUNT )); then
  echo "error: workspace.split.right did not increase pane count" >&2
  echo "baseline pane count: ${BASELINE_PANE_COUNT}" >&2
  echo "post-split pane count: ${SPLIT_RIGHT_PANE_COUNT}" >&2
  echo "snapshot response: ${SPLIT_RIGHT_RESPONSE}" >&2
  exit 1
fi

TERMINAL_VIEWPORT_SCREENSHOT_PATH=""
GHOSTTY_INTEGRATION_DISABLED="${TUIST_DISABLE_GHOSTTY:-${TOASTTY_DISABLE_GHOSTTY:-0}}"
if [[ "$GHOSTTY_INTEGRATION_DISABLED" != "1" && -d "$GHOSTTY_XCFRAMEWORK_PATH" ]]; then

  TERMINAL_MARKER="TOASTTY_VIEWPORT_END_${RUN_ID//[^A-Za-z0-9_]/_}"
  TERMINAL_COMMAND="find /usr/bin -maxdepth 1 | head -n 120; echo ${TERMINAL_MARKER}"
  TERMINAL_SEND_RESPONSE=""
  TERMINAL_SEND_READY=0
  TERMINAL_READY_ATTEMPTS="${TERMINAL_READY_ATTEMPTS:-40}"
  TERMINAL_READY_INTERVAL_SEC="${TERMINAL_READY_INTERVAL_SEC:-0.1}"
  for _ in $(seq 1 "$TERMINAL_READY_ATTEMPTS"); do
    TERMINAL_SEND_RESPONSE="$(send_request "automation.terminal_send_text" "{\"text\":\"${TERMINAL_COMMAND}\",\"submit\":true,\"allowUnavailable\":true}")"
    if [[ "$(extract_bool_field "$TERMINAL_SEND_RESPONSE" "available")" == "true" ]]; then
      TERMINAL_SEND_READY=1
      break
    fi
    sleep "$TERMINAL_READY_INTERVAL_SEC"
  done
  if [[ "$TERMINAL_SEND_READY" -ne 1 ]]; then
    echo "error: terminal surface did not become available for send_text" >&2
    echo "last terminal send response: ${TERMINAL_SEND_RESPONSE}" >&2
    exit 1
  fi

  TERMINAL_FOUND=0
  TERMINAL_VISIBLE_RESPONSE=""
  for _ in $(seq 1 40); do
    TERMINAL_VISIBLE_RESPONSE="$(send_request "automation.terminal_visible_text" "{\"contains\":\"${TERMINAL_MARKER}\"}")"
    if echo "$TERMINAL_VISIBLE_RESPONSE" | grep -qE '"contains"[[:space:]]*:[[:space:]]*true'; then
      TERMINAL_FOUND=1
      break
    fi
    sleep 0.1
  done

  if [[ "$TERMINAL_FOUND" -ne 1 ]]; then
    echo "error: terminal viewport did not contain marker: ${TERMINAL_MARKER}" >&2
    echo "last terminal response: ${TERMINAL_VISIBLE_RESPONSE}" >&2
    exit 1
  fi

  TERMINAL_VIEWPORT_RESPONSE="$(send_request "automation.capture_screenshot" '{"step":"terminal-viewport-smoke"}')"
  TERMINAL_VIEWPORT_SCREENSHOT_PATH="$(extract_string_field "$TERMINAL_VIEWPORT_RESPONSE" "path")"
fi

send_request "automation.perform_action" '{"action":"app.font.increase"}'
FONT_SCREENSHOT_RESPONSE="$(send_request "automation.capture_screenshot" '{"step":"font-hud-smoke"}')"
send_request "automation.perform_action" '{"action":"app.font.reset"}'
send_request "automation.perform_action" '{"action":"workspace.split.vertical"}'
send_request "automation.perform_action" '{"action":"topbar.toggle.diff"}'
send_request "automation.perform_action" '{"action":"topbar.toggle.markdown"}'
send_request "automation.perform_action" '{"action":"topbar.toggle.focused-panel"}'

FOCUSED_SCREENSHOT_RESPONSE="$(send_request "automation.capture_screenshot" '{"step":"focused-panel-smoke"}')"
send_request "automation.perform_action" '{"action":"topbar.toggle.focused-panel"}'

SCREENSHOT_RESPONSE="$(send_request "automation.capture_screenshot" '{"step":"aux-column-smoke"}')"
STATE_RESPONSE="$(send_request "automation.dump_state" '{}')"

FONT_SCREENSHOT_PATH="$(extract_string_field "$FONT_SCREENSHOT_RESPONSE" "path")"
FOCUSED_SCREENSHOT_PATH="$(extract_string_field "$FOCUSED_SCREENSHOT_RESPONSE" "path")"
SCREENSHOT_PATH="$(extract_string_field "$SCREENSHOT_RESPONSE" "path")"
STATE_PATH="$(extract_string_field "$STATE_RESPONSE" "path")"
STATE_HASH="$(extract_string_field "$STATE_RESPONSE" "hash")"

echo "ready file: $READY_FILE"
echo "socket path: $SOCKET_PATH"
echo "font hud screenshot: ${FONT_SCREENSHOT_PATH:-unknown}"
echo "terminal viewport screenshot: ${TERMINAL_VIEWPORT_SCREENSHOT_PATH:-skipped}"
echo "focused screenshot: ${FOCUSED_SCREENSHOT_PATH:-unknown}"
echo "screenshot: ${SCREENSHOT_PATH:-unknown}"
echo "state dump: ${STATE_PATH:-unknown}"
echo "state hash: ${STATE_HASH:-unknown}"
echo "app log: $LOG_FILE"
