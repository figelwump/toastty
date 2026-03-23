#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOOTSTRAP_WORKTREE_SCRIPT="$ROOT_DIR/scripts/dev/bootstrap-worktree.sh"
RUN_ID="${RUN_ID:-shortcut-hints-smoke-$(date +%Y%m%d-%H%M%S)}"
FIXTURE="${FIXTURE:-split-workspace}"
RESTORE_FRONT_APP_AFTER_LAUNCH="${TOASTTY_SHORTCUT_HINTS_RESTORE_FRONT_APP:-1}"
DEV_RUN_ROOT="${DEV_RUN_ROOT:-$ROOT_DIR/artifacts/dev-runs/$RUN_ID}"
DERIVED_PATH="${DERIVED_PATH:-$DEV_RUN_ROOT/Derived}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$DEV_RUN_ROOT/artifacts}"
TOASTTY_RUNTIME_HOME="${TOASTTY_RUNTIME_HOME:-$DEV_RUN_ROOT/runtime-home}"
SOCKET_PATH="${SOCKET_PATH:-${TMPDIR:-/tmp}/toastty-${RUN_ID}.sock}"
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
      echo "warning: failed to restore Ghostty-enabled workspace after fallback shortcut-hints smoke run" >&2
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
  if command -v jq >/dev/null 2>&1; then
    echo "$json" | jq -r --arg field "$field" '(.result[$field] // .[$field] // empty) | select(type == "string")'
    return
  fi
  echo "$json" | sed -nE "s/.*\"${field}\":[[:space:]]*\"([^\"]+)\".*/\\1/p" | sed 's#\\/#/#g'
}

send_request "automation.load_fixture" "{\"name\":\"${FIXTURE}\"}" >/dev/null

SCREENSHOT_RESPONSE="$(send_request "automation.capture_screenshot" '{"step":"shortcut-hints-smoke"}')"
SCREENSHOT_PATH="$(extract_string_field "$SCREENSHOT_RESPONSE" "path")"
if [[ -z "$SCREENSHOT_PATH" || ! -f "$SCREENSHOT_PATH" ]]; then
  echo "error: screenshot path missing or file not found in response" >&2
  echo "screenshot response: ${SCREENSHOT_RESPONSE}" >&2
  exit 1
fi

STATE_DUMP_RESPONSE="$(send_request "automation.dump_state" '{"includeRuntime":false}')"
STATE_DUMP_PATH="$(extract_string_field "$STATE_DUMP_RESPONSE" "path")"
STATE_HASH="$(extract_string_field "$STATE_DUMP_RESPONSE" "hash")"
if [[ -z "$STATE_DUMP_PATH" || ! -f "$STATE_DUMP_PATH" ]]; then
  echo "error: state dump path missing or file not found in response" >&2
  echo "state dump response: ${STATE_DUMP_RESPONSE}" >&2
  exit 1
fi

echo "ready file: $READY_FILE"
echo "socket path: $SOCKET_PATH"
echo "shortcut hints screenshot: $SCREENSHOT_PATH"
echo "state dump: $STATE_DUMP_PATH"
echo "state hash: $STATE_HASH"
echo "app log: $LOG_FILE"
