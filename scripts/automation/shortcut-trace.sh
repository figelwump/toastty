#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_ID="${RUN_ID:-shortcut-trace-$(date +%Y%m%d-%H%M%S)}"
FIXTURE="${FIXTURE:-split-workspace}"
DERIVED_PATH="${DERIVED_PATH:-$ROOT_DIR/Derived}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$ROOT_DIR/artifacts/automation}"
SOCKET_PATH="${SOCKET_PATH:-${TMPDIR:-/tmp}/toastty-$(id -u)/events-v1.sock}"
ARCH="${ARCH:-$(uname -m)}"
CLICK_X="${CLICK_X:-}"
CLICK_Y="${CLICK_Y:-}"
TRACE_LOG_PATH="${TRACE_LOG_PATH:-/tmp/toastty.log}"
RESIZE_KEY_CODE="${RESIZE_KEY_CODE:-124}"
EQUALIZE_KEY_CODE="${EQUALIZE_KEY_CODE:-24}"

if [[ "$ARCH" != "arm64" && "$ARCH" != "x86_64" ]]; then
  ARCH="arm64"
fi

READY_FILE="$ARTIFACTS_DIR/automation-ready-${RUN_ID}.json"
APP_BINARY="$DERIVED_PATH/Build/Products/Debug/ToasttyApp.app/Contents/MacOS/ToasttyApp"
APP_LOG_FILE="$ARTIFACTS_DIR/app-${RUN_ID}.log"
GHOSTTY_XCFRAMEWORK_PATH="$ROOT_DIR/Dependencies/GhosttyKit.xcframework"

mkdir -p "$ARTIFACTS_DIR"
rm -f "$SOCKET_PATH" "$READY_FILE" "$APP_LOG_FILE"
rm -f "$TRACE_LOG_PATH"

if [[ "${TUIST_DISABLE_GHOSTTY:-0}" == "1" || "${TOASTTY_DISABLE_GHOSTTY:-0}" == "1" ]]; then
  echo "error: shortcut trace requires Ghostty-enabled build (disable flags are set)" >&2
  exit 1
fi

if [[ ! -f "$GHOSTTY_XCFRAMEWORK_PATH/Info.plist" ]]; then
  echo "error: Ghostty xcframework missing or invalid: $GHOSTTY_XCFRAMEWORK_PATH" >&2
  exit 1
fi

if ! command -v nc >/dev/null 2>&1; then
  echo "error: nc is required for socket requests" >&2
  exit 1
fi

if ! command -v uuidgen >/dev/null 2>&1; then
  echo "error: uuidgen is required for request ids" >&2
  exit 1
fi

if ! command -v osascript >/dev/null 2>&1; then
  echo "error: osascript is required for shortcut tracing" >&2
  exit 1
fi

cleanup() {
  if [[ -n "${APP_PID:-}" ]]; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

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

extract_double_field() {
  local json="$1"
  local field="$2"
  if command -v jq >/dev/null 2>&1; then
    echo "$json" | jq -r --arg field "$field" '(.result[$field] // .[$field] // empty) | select(type == "number")'
    return
  fi

  echo "$json" \
    | tr -d '\n' \
    | sed -nE "s/.*\"${field}\"[[:space:]]*:[[:space:]]*(-?[0-9]+(\\.[0-9]+)?)([},].*)?/\\1/p"
}

focus_app_terminal() {
  if [[ -n "$CLICK_X" && -n "$CLICK_Y" ]]; then
    osascript <<OSA
tell application "ToasttyApp" to activate
delay 0.5
tell application "System Events"
  click at {${CLICK_X}, ${CLICK_Y}}
  delay 0.2
end tell
OSA
    return
  fi

  osascript <<'OSA'
tell application "ToasttyApp" to activate
delay 0.5
tell application "System Events"
  tell process "ToasttyApp"
    set frontmost to true
    if not (exists window 1) then error "ToasttyApp window not found"
    set winPos to position of window 1
    set winSize to size of window 1
  end tell
end tell
-- Prefer a stable point inside the left terminal pane instead of window center,
-- which can land on split dividers in multi-pane fixtures.
set clickX to (item 1 of winPos) + ((item 1 of winSize) div 3)
set clickY to (item 2 of winPos) + ((item 2 of winSize) div 3)
tell application "System Events"
  click at {clickX, clickY}
  delay 0.2
end tell
OSA
}

send_resize_shortcut() {
  osascript -e "tell application \"System Events\" to key code ${RESIZE_KEY_CODE} using {command down, control down}"
}

send_equalize_shortcut() {
  osascript -e "tell application \"System Events\" to key code ${EQUALIZE_KEY_CODE} using {command down, control down}"
}

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
TOASTTY_LOG_LEVEL=debug \
TOASTTY_LOG_FILE="$TRACE_LOG_PATH" \
"$APP_BINARY" \
  --automation \
  --run-id "$RUN_ID" \
  --fixture "$FIXTURE" \
  --artifacts-dir "$ARTIFACTS_DIR" \
  --disable-animations >"$APP_LOG_FILE" 2>&1 &
APP_PID=$!

for _ in $(seq 1 200); do
  if ! kill -0 "$APP_PID" >/dev/null 2>&1; then
    sleep 0.05
    if ! kill -0 "$APP_PID" >/dev/null 2>&1; then
      echo "error: app process exited during startup (pid $APP_PID)" >&2
      exit 1
    fi
  fi
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

send_request "automation.ping" '{}'
send_request "automation.load_fixture" "{\"name\":\"${FIXTURE}\"}"

BASELINE_SNAPSHOT=""
BASELINE_RATIO=""
for _ in $(seq 1 20); do
  BASELINE_SNAPSHOT="$(send_request "automation.workspace_snapshot" '{}')"
  BASELINE_RATIO="$(extract_double_field "$BASELINE_SNAPSHOT" "rootSplitRatio")"
  if [[ -n "$BASELINE_RATIO" ]]; then
    break
  fi
  sleep 0.1
done
if [[ -z "$BASELINE_RATIO" ]]; then
  echo "error: missing baseline root split ratio. Ensure fixture has multiple panes." >&2
  echo "snapshot response: ${BASELINE_SNAPSHOT}" >&2
  exit 1
fi

focus_app_terminal
send_resize_shortcut
RESIZED_SNAPSHOT=""
RESIZED_RATIO=""
for _ in $(seq 1 20); do
  RESIZED_SNAPSHOT="$(send_request "automation.workspace_snapshot" '{}')"
  RESIZED_RATIO="$(extract_double_field "$RESIZED_SNAPSHOT" "rootSplitRatio")"
  if [[ -n "$RESIZED_RATIO" ]] && awk -v before="$BASELINE_RATIO" -v after="$RESIZED_RATIO" 'BEGIN { exit !(after > before) }'; then
    break
  fi
  sleep 0.1
done
if [[ -z "$RESIZED_RATIO" ]]; then
  echo "error: missing root split ratio after resize shortcut" >&2
  echo "snapshot response: ${RESIZED_SNAPSHOT}" >&2
  exit 1
fi

if ! awk -v before="$BASELINE_RATIO" -v after="$RESIZED_RATIO" 'BEGIN { exit !(after > before) }'; then
  echo "error: resize shortcut did not increase root split ratio" >&2
  echo "baseline ratio: ${BASELINE_RATIO}" >&2
  echo "resized ratio: ${RESIZED_RATIO}" >&2
  echo "snapshot response: ${RESIZED_SNAPSHOT}" >&2
  exit 1
fi

send_equalize_shortcut
EQUALIZED_SNAPSHOT=""
EQUALIZED_RATIO=""
for _ in $(seq 1 20); do
  EQUALIZED_SNAPSHOT="$(send_request "automation.workspace_snapshot" '{}')"
  EQUALIZED_RATIO="$(extract_double_field "$EQUALIZED_SNAPSHOT" "rootSplitRatio")"
  if [[ -n "$EQUALIZED_RATIO" ]] && awk -v ratio="$EQUALIZED_RATIO" 'BEGIN { d = ratio - 0.5; if (d < 0) d = -d; exit !(d < 0.0001) }'; then
    break
  fi
  sleep 0.1
done
if [[ -z "$EQUALIZED_RATIO" ]]; then
  echo "error: missing root split ratio after equalize shortcut" >&2
  echo "snapshot response: ${EQUALIZED_SNAPSHOT}" >&2
  exit 1
fi

if ! awk -v ratio="$EQUALIZED_RATIO" 'BEGIN { d = ratio - 0.5; if (d < 0) d = -d; exit !(d < 0.0001) }'; then
  echo "error: equalize shortcut did not normalize root split ratio to 0.5" >&2
  echo "equalized ratio: ${EQUALIZED_RATIO}" >&2
  echo "snapshot response: ${EQUALIZED_SNAPSHOT}" >&2
  exit 1
fi

if [[ ! -f "$TRACE_LOG_PATH" ]]; then
  echo "error: trace log file was not created: $TRACE_LOG_PATH" >&2
  exit 1
fi

RESIZE_LOG_COUNT="$(awk '/"intent":"resize_split.right"/ { c++ } END { print c + 0 }' "$TRACE_LOG_PATH")"
EQUALIZE_LOG_COUNT="$(awk '/"intent":"equalize_splits"/ { c++ } END { print c + 0 }' "$TRACE_LOG_PATH")"
INPUT_RIGHT_COUNT="$(awk '/"category":"input"/ && /"key_code":"124"/ { c++ } END { print c + 0 }' "$TRACE_LOG_PATH")"
INPUT_EQUAL_COUNT="$(awk '/"category":"input"/ && /"key_code":"24"/ { c++ } END { print c + 0 }' "$TRACE_LOG_PATH")"

if [[ "$RESIZE_LOG_COUNT" == "0" || "$EQUALIZE_LOG_COUNT" == "0" ]]; then
  echo "error: missing expected Ghostty intent logs in $TRACE_LOG_PATH" >&2
  echo "resize intent count: $RESIZE_LOG_COUNT" >&2
  echo "equalize intent count: $EQUALIZE_LOG_COUNT" >&2
  exit 1
fi

if [[ "$INPUT_RIGHT_COUNT" == "0" || "$INPUT_EQUAL_COUNT" == "0" ]]; then
  echo "error: missing expected key event logs in $TRACE_LOG_PATH" >&2
  echo "right-arrow key event count: $INPUT_RIGHT_COUNT" >&2
  echo "equal key event count: $INPUT_EQUAL_COUNT" >&2
  echo "hint: ensure Terminal has focus and Accessibility permissions are granted for Terminal/System Events." >&2
  exit 1
fi

SHORTCUT_SCREENSHOT_RESPONSE="$(send_request "automation.capture_screenshot" '{"step":"shortcut-trace"}')"
SHORTCUT_SCREENSHOT_PATH="$(echo "$SHORTCUT_SCREENSHOT_RESPONSE" | sed -nE 's/.*"path":[[:space:]]*"([^"]+)".*/\1/p' | sed 's#\\/#/#g')"
if [[ -z "$SHORTCUT_SCREENSHOT_PATH" || ! -f "$SHORTCUT_SCREENSHOT_PATH" ]]; then
  echo "error: screenshot path missing or file not found in response" >&2
  echo "screenshot response: ${SHORTCUT_SCREENSHOT_RESPONSE}" >&2
  exit 1
fi

echo "baseline root ratio: $BASELINE_RATIO"
echo "resized root ratio: $RESIZED_RATIO"
echo "equalized root ratio: $EQUALIZED_RATIO"
echo "resize intent logs: $RESIZE_LOG_COUNT"
echo "equalize intent logs: $EQUALIZE_LOG_COUNT"
echo "right-arrow input logs: $INPUT_RIGHT_COUNT"
echo "equal input logs: $INPUT_EQUAL_COUNT"
echo "shortcut screenshot: ${SHORTCUT_SCREENSHOT_PATH:-unknown}"
echo "trace log: $TRACE_LOG_PATH"
echo "app log: $APP_LOG_FILE"
