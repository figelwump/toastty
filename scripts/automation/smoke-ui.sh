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

send_request "automation.ping" '{}'
send_request "automation.load_fixture" "{\"name\":\"${FIXTURE}\"}"

TERMINAL_VIEWPORT_SCREENSHOT_PATH=""
if [[ "${TUIST_ENABLE_GHOSTTY:-${TOASTTY_ENABLE_GHOSTTY:-0}}" == "1" ]]; then
  if [[ ! -d "$ROOT_DIR/Dependencies/GhosttyKit.xcframework" ]]; then
    echo "error: Ghostty smoke requested but Dependencies/GhosttyKit.xcframework is missing" >&2
    exit 1
  fi

  TERMINAL_MARKER="TOASTTY_VIEWPORT_END_${RUN_ID//[^A-Za-z0-9_]/_}"
  TERMINAL_COMMAND="find /usr/bin -maxdepth 1 | head -n 120; echo ${TERMINAL_MARKER}"
  TERMINAL_SEND_RESPONSE=""
  TERMINAL_SEND_READY=0
  for _ in $(seq 1 40); do
    TERMINAL_SEND_RESPONSE="$(send_request "automation.terminal_send_text" "{\"text\":\"${TERMINAL_COMMAND}\",\"submit\":true,\"allowUnavailable\":true}")"
    if echo "$TERMINAL_SEND_RESPONSE" | grep -qE '"available"[[:space:]]*:[[:space:]]*true'; then
      TERMINAL_SEND_READY=1
      break
    fi
    sleep 0.1
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
