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
send_request "automation.perform_action" '{"action":"workspace.split.vertical"}'
send_request "automation.perform_action" '{"action":"topbar.toggle.diff"}'
send_request "automation.perform_action" '{"action":"topbar.toggle.markdown"}'

SCREENSHOT_RESPONSE="$(send_request "automation.capture_screenshot" '{"step":"aux-column-smoke"}')"
STATE_RESPONSE="$(send_request "automation.dump_state" '{}')"

SCREENSHOT_PATH="$(extract_string_field "$SCREENSHOT_RESPONSE" "path")"
STATE_PATH="$(extract_string_field "$STATE_RESPONSE" "path")"
STATE_HASH="$(extract_string_field "$STATE_RESPONSE" "hash")"

echo "ready file: $READY_FILE"
echo "socket path: $SOCKET_PATH"
echo "screenshot: ${SCREENSHOT_PATH:-unknown}"
echo "state dump: ${STATE_PATH:-unknown}"
echo "state hash: ${STATE_HASH:-unknown}"
echo "app log: $LOG_FILE"
