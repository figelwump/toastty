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
APP_BINARY="$DERIVED_PATH/Build/Products/Debug/Toastty.app/Contents/MacOS/Toastty"
LOG_FILE="$ARTIFACTS_DIR/app-${RUN_ID}.log"
GHOSTTY_DEBUG_XCFRAMEWORK_PATH="$ROOT_DIR/Dependencies/GhosttyKit.Debug.xcframework"
GHOSTTY_RELEASE_XCFRAMEWORK_PATH="$ROOT_DIR/Dependencies/GhosttyKit.Release.xcframework"
GHOSTTY_XCFRAMEWORK_PATH=""
if [[ -d "$GHOSTTY_DEBUG_XCFRAMEWORK_PATH" ]]; then
  GHOSTTY_XCFRAMEWORK_PATH="$GHOSTTY_DEBUG_XCFRAMEWORK_PATH"
elif [[ -d "$GHOSTTY_RELEASE_XCFRAMEWORK_PATH" ]]; then
  GHOSTTY_XCFRAMEWORK_PATH="$GHOSTTY_RELEASE_XCFRAMEWORK_PATH"
fi
GHOSTTY_INTEGRATION_DISABLED="${TUIST_DISABLE_GHOSTTY:-${TOASTTY_DISABLE_GHOSTTY:-0}}"
GHOSTTY_INPUT_READINESS_REQUIRED=0
if [[ "$GHOSTTY_INTEGRATION_DISABLED" != "1" && -n "$GHOSTTY_XCFRAMEWORK_PATH" ]]; then
  GHOSTTY_INPUT_READINESS_REQUIRED=1
fi
RESTORE_GHOSTTY_ENABLED_WORKSPACE=0
if [[ "$GHOSTTY_INTEGRATION_DISABLED" == "1" && -n "$GHOSTTY_XCFRAMEWORK_PATH" ]]; then
  RESTORE_GHOSTTY_ENABLED_WORKSPACE=1
fi
DROP_IMAGE_PATH_TO_CLEANUP=""
TERMINAL_PROFILES_PATH="$ARTIFACTS_DIR/terminal-profiles-${RUN_ID}.toml"
PROFILE_SMOKE_PROFILE_ID="smoke-profile"
PROFILE_SMOKE_TITLE="Profile Ready"
PROFILE_SMOKE_VISIBLE_MARKER="PROFILE:${PROFILE_SMOKE_PROFILE_ID}:create"

mkdir -p "$ARTIFACTS_DIR"
rm -f "$SOCKET_PATH" "$READY_FILE" "$LOG_FILE"

if ! command -v nc >/dev/null 2>&1; then
  echo "error: nc is required for socket requests" >&2
  exit 1
fi

run_tuist() {
  if command -v sv >/dev/null 2>&1; then
    sv exec -- tuist "$@"
  else
    tuist "$@"
  fi
}

ensure_tuist_dependencies() {
  run_tuist install >/dev/null
}

cleanup() {
  local exit_code=$?
  if [[ -n "$DROP_IMAGE_PATH_TO_CLEANUP" && -f "$DROP_IMAGE_PATH_TO_CLEANUP" ]]; then
    rm -f "$DROP_IMAGE_PATH_TO_CLEANUP"
  fi
  if [[ -n "${APP_PID:-}" ]]; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi

  # Fallback smoke runs regenerate the project without Ghostty; restore the
  # default Xcode workspace afterward when local artifacts are available.
  if [[ "$RESTORE_GHOSTTY_ENABLED_WORKSPACE" == "1" ]]; then
    if ! (
      unset TUIST_DISABLE_GHOSTTY TOASTTY_DISABLE_GHOSTTY
      run_tuist generate --no-open >/dev/null
    ); then
      echo "warning: failed to restore Ghostty-enabled workspace after fallback smoke run" >&2
    fi
  fi

  return "$exit_code"
}
trap cleanup EXIT

cd "$ROOT_DIR"

cat > "$TERMINAL_PROFILES_PATH" <<EOF
[${PROFILE_SMOKE_PROFILE_ID}]
displayName = "Smoke Profile"
badge = "SMOKE"
startupCommand = "printf 'PROFILE:%s:%s\\\\n' \"\$TOASTTY_TERMINAL_PROFILE_ID\" \"\$TOASTTY_LAUNCH_REASON\"; printf '\\\\033]2;${PROFILE_SMOKE_TITLE}\\\\007'; sleep 2"
EOF

ensure_tuist_dependencies
run_tuist generate --no-open >/dev/null
xcodebuild \
  -workspace toastty.xcworkspace \
  -scheme ToasttyApp \
  -configuration Debug \
  -destination "platform=macOS,arch=${ARCH}" \
  -derivedDataPath "$DERIVED_PATH" \
  build >/dev/null

TOASTTY_AUTOMATION=1 \
TOASTTY_SKIP_QUIT_CONFIRMATION=1 \
TOASTTY_SOCKET_PATH="$SOCKET_PATH" \
TOASTTY_TERMINAL_PROFILES_PATH="$TERMINAL_PROFILES_PATH" \
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

extract_bool_field() {
  local json="$1"
  local field="$2"
  if command -v jq >/dev/null 2>&1; then
    echo "$json" | jq -r --arg field "$field" '(.result[$field] // .[$field] // empty) | select(type == "boolean")'
    return
  fi
  echo "$json" | sed -nE "s/.*\"${field}\":[[:space:]]*(true|false).*/\\1/p"
}

extract_int_field() {
  local json="$1"
  local field="$2"
  if command -v jq >/dev/null 2>&1; then
    echo "$json" | jq -r --arg field "$field" '(.result[$field] // .[$field] // empty) | select(type == "number") | floor'
    return
  fi
  echo "$json" | sed -nE "s/.*\"${field}\":[[:space:]]*(-?[0-9]+).*/\\1/p"
}

extract_double_field() {
  local json="$1"
  local field="$2"
  if command -v jq >/dev/null 2>&1; then
    echo "$json" | jq -r --arg field "$field" '(.result[$field] // .[$field] // empty) | select(type == "number")'
    return
  fi
  echo "$json" | sed -nE "s/.*\"${field}\":[[:space:]]*(-?[0-9]+(\\.[0-9]+)?).*/\\1/p"
}

json_escape_string() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  printf '%s' "$value"
}

canonicalize_path() {
  local path="$1"
  if [[ -z "$path" ]]; then
    printf ''
    return
  fi
  if [[ -d "$path" ]]; then
    (cd "$path" && pwd -P) || printf '%s' "$path"
    return
  fi
  printf '%s' "$path"
}

probe_terminal_send_text_availability() {
  local panel_id="$1"
  send_request "automation.terminal_send_text" "{\"text\":\"\",\"submit\":false,\"allowUnavailable\":true,\"panelID\":\"${panel_id}\"}"
}

send_request "automation.ping" '{}'
send_request "automation.load_fixture" "{\"name\":\"${FIXTURE}\"}"

WORKSPACE_BASELINE_RESPONSE="$(send_request "automation.workspace_snapshot" '{}')"
BASELINE_SLOT_COUNT="$(extract_int_field "$WORKSPACE_BASELINE_RESPONSE" "slotCount")"
BASELINE_FOCUSED_PANEL_ID="$(extract_string_field "$WORKSPACE_BASELINE_RESPONSE" "focusedPanelID")"
NEXT_FOCUSED_PANEL_ID=""
PREVIOUS_FOCUSED_PANEL_ID=""
if [[ -z "$BASELINE_SLOT_COUNT" || -z "$BASELINE_FOCUSED_PANEL_ID" ]]; then
  echo "error: failed to read baseline workspace snapshot" >&2
  echo "snapshot response: ${WORKSPACE_BASELINE_RESPONSE}" >&2
  exit 1
fi

if (( BASELINE_SLOT_COUNT > 1 )); then
  BASELINE_ROOT_SPLIT_RATIO="$(extract_double_field "$WORKSPACE_BASELINE_RESPONSE" "rootSplitRatio")"
  if [[ -z "$BASELINE_ROOT_SPLIT_RATIO" ]]; then
    echo "error: root split ratio missing for multi-slot workspace" >&2
    echo "snapshot response: ${WORKSPACE_BASELINE_RESPONSE}" >&2
    exit 1
  fi

  send_request "automation.perform_action" '{"action":"workspace.resize-split.right","args":{"amount":2}}'
  RESIZED_SPLIT_RESPONSE="$(send_request "automation.workspace_snapshot" '{}')"
  RESIZED_ROOT_SPLIT_RATIO="$(extract_double_field "$RESIZED_SPLIT_RESPONSE" "rootSplitRatio")"
  if [[ -z "$RESIZED_ROOT_SPLIT_RATIO" ]]; then
    echo "error: root split ratio missing after workspace.resize-split.right" >&2
    echo "snapshot response: ${RESIZED_SPLIT_RESPONSE}" >&2
    exit 1
  fi
  if ! awk -v before="$BASELINE_ROOT_SPLIT_RATIO" -v after="$RESIZED_ROOT_SPLIT_RATIO" 'BEGIN { exit !(after > before) }'; then
    echo "error: workspace.resize-split.right did not increase root split ratio" >&2
    echo "baseline root ratio: ${BASELINE_ROOT_SPLIT_RATIO}" >&2
    echo "resized root ratio: ${RESIZED_ROOT_SPLIT_RATIO}" >&2
    echo "snapshot response: ${RESIZED_SPLIT_RESPONSE}" >&2
    exit 1
  fi

  send_request "automation.perform_action" '{"action":"workspace.equalize-splits"}'
  EQUALIZED_SPLIT_RESPONSE="$(send_request "automation.workspace_snapshot" '{}')"
  EQUALIZED_ROOT_SPLIT_RATIO="$(extract_double_field "$EQUALIZED_SPLIT_RESPONSE" "rootSplitRatio")"
  if [[ -z "$EQUALIZED_ROOT_SPLIT_RATIO" ]]; then
    echo "error: root split ratio missing after workspace.equalize-splits" >&2
    echo "snapshot response: ${EQUALIZED_SPLIT_RESPONSE}" >&2
    exit 1
  fi
  if ! awk -v ratio="$EQUALIZED_ROOT_SPLIT_RATIO" 'BEGIN { d = ratio - 0.5; if (d < 0) d = -d; exit !(d < 0.0001) }'; then
    echo "error: workspace.equalize-splits did not normalize root split ratio to 0.5" >&2
    echo "equalized root ratio: ${EQUALIZED_ROOT_SPLIT_RATIO}" >&2
    echo "snapshot response: ${EQUALIZED_SPLIT_RESPONSE}" >&2
    exit 1
  fi

  send_request "automation.perform_action" '{"action":"workspace.focus-slot.next"}'
  FOCUS_NEXT_RESPONSE="$(send_request "automation.workspace_snapshot" '{}')"
  NEXT_FOCUSED_PANEL_ID="$(extract_string_field "$FOCUS_NEXT_RESPONSE" "focusedPanelID")"
  if [[ -z "$NEXT_FOCUSED_PANEL_ID" ]]; then
    echo "error: focused panel missing after workspace.focus-slot.next" >&2
    echo "snapshot response: ${FOCUS_NEXT_RESPONSE}" >&2
    exit 1
  fi
  if [[ "$NEXT_FOCUSED_PANEL_ID" == "$BASELINE_FOCUSED_PANEL_ID" ]]; then
    echo "error: workspace.focus-slot.next did not change focused panel" >&2
    echo "baseline focused panel: ${BASELINE_FOCUSED_PANEL_ID}" >&2
    echo "snapshot response: ${FOCUS_NEXT_RESPONSE}" >&2
    exit 1
  fi

  send_request "automation.perform_action" '{"action":"workspace.focus-slot.previous"}'
  FOCUS_PREVIOUS_RESPONSE="$(send_request "automation.workspace_snapshot" '{}')"
  PREVIOUS_FOCUSED_PANEL_ID="$(extract_string_field "$FOCUS_PREVIOUS_RESPONSE" "focusedPanelID")"
  if [[ "$PREVIOUS_FOCUSED_PANEL_ID" != "$BASELINE_FOCUSED_PANEL_ID" ]]; then
    echo "error: workspace.focus-slot.previous did not return focus to baseline panel" >&2
    echo "baseline focused panel: ${BASELINE_FOCUSED_PANEL_ID}" >&2
    echo "snapshot response: ${FOCUS_PREVIOUS_RESPONSE}" >&2
    exit 1
  fi
else
  echo "note: skipping focus-next/previous assertions for single-slot fixture"
fi

send_request "automation.perform_action" '{"action":"workspace.split.right"}'
SPLIT_RIGHT_RESPONSE="$(send_request "automation.workspace_snapshot" '{}')"
SPLIT_RIGHT_SLOT_COUNT="$(extract_int_field "$SPLIT_RIGHT_RESPONSE" "slotCount")"
SPLIT_RIGHT_FOCUSED_PANEL_ID="$(extract_string_field "$SPLIT_RIGHT_RESPONSE" "focusedPanelID")"
if [[ -z "$SPLIT_RIGHT_SLOT_COUNT" || -z "$SPLIT_RIGHT_FOCUSED_PANEL_ID" ]]; then
  echo "error: slot count or focused panel missing after workspace.split.right" >&2
  echo "snapshot response: ${SPLIT_RIGHT_RESPONSE}" >&2
  exit 1
fi
if (( SPLIT_RIGHT_SLOT_COUNT <= BASELINE_SLOT_COUNT )); then
  echo "error: workspace.split.right did not increase slot count" >&2
  echo "baseline slot count: ${BASELINE_SLOT_COUNT}" >&2
  echo "post-split slot count: ${SPLIT_RIGHT_SLOT_COUNT}" >&2
  echo "snapshot response: ${SPLIT_RIGHT_RESPONSE}" >&2
  exit 1
fi

send_request "automation.perform_action" '{"action":"workspace.split.down"}'
SPLIT_DOWN_RESPONSE="$(send_request "automation.workspace_snapshot" '{}')"
SPLIT_DOWN_SLOT_COUNT="$(extract_int_field "$SPLIT_DOWN_RESPONSE" "slotCount")"
SPLIT_DOWN_FOCUSED_PANEL_ID="$(extract_string_field "$SPLIT_DOWN_RESPONSE" "focusedPanelID")"
if [[ -z "$SPLIT_DOWN_SLOT_COUNT" || -z "$SPLIT_DOWN_FOCUSED_PANEL_ID" ]]; then
  echo "error: slot count or focused panel missing after workspace.split.down" >&2
  echo "snapshot response: ${SPLIT_DOWN_RESPONSE}" >&2
  exit 1
fi
if (( SPLIT_DOWN_SLOT_COUNT <= SPLIT_RIGHT_SLOT_COUNT )); then
  echo "error: workspace.split.down did not increase slot count" >&2
  echo "post-split-right slot count: ${SPLIT_RIGHT_SLOT_COUNT}" >&2
  echo "post-split-down slot count: ${SPLIT_DOWN_SLOT_COUNT}" >&2
  echo "snapshot response: ${SPLIT_DOWN_RESPONSE}" >&2
  exit 1
fi
if [[ "$SPLIT_DOWN_FOCUSED_PANEL_ID" == "$SPLIT_RIGHT_FOCUSED_PANEL_ID" ]]; then
  echo "error: workspace.split.down did not move focus to a new panel" >&2
  echo "split-right focused panel: ${SPLIT_RIGHT_FOCUSED_PANEL_ID}" >&2
  echo "split-down focused panel: ${SPLIT_DOWN_FOCUSED_PANEL_ID}" >&2
  echo "snapshot response: ${SPLIT_DOWN_RESPONSE}" >&2
  exit 1
fi

CLOSE_SNAPSHOT_RESPONSE=""
RENDER_SNAPSHOT_RESPONSE=""
CLOSE_SLOT_COUNT="$SPLIT_DOWN_SLOT_COUNT"
ALL_RENDERABLE=""
FINAL_CLOSE_LAYOUT_SIGNATURE=""
FINAL_CLOSE_FOCUSED_PANEL_ID=""
CLOSE_TERMINAL_READY="false"
CLOSE_TERMINAL_PROBE_RESPONSE=""
while (( CLOSE_SLOT_COUNT > 1 )); do
  send_request "automation.perform_action" '{"action":"workspace.close-focused-panel"}'
  EXPECTED_CLOSE_SLOT_COUNT=$((CLOSE_SLOT_COUNT - 1))

  for _ in $(seq 1 40); do
    CLOSE_SNAPSHOT_RESPONSE="$(send_request "automation.workspace_snapshot" '{}')"
    CLOSE_SLOT_COUNT="$(extract_int_field "$CLOSE_SNAPSHOT_RESPONSE" "slotCount")"
    FINAL_CLOSE_LAYOUT_SIGNATURE="$(extract_string_field "$CLOSE_SNAPSHOT_RESPONSE" "layoutSignature")"
    FINAL_CLOSE_FOCUSED_PANEL_ID="$(extract_string_field "$CLOSE_SNAPSHOT_RESPONSE" "focusedPanelID")"
    RENDER_SNAPSHOT_RESPONSE="$(send_request "automation.workspace_render_snapshot" '{}')"
    ALL_RENDERABLE="$(extract_bool_field "$RENDER_SNAPSHOT_RESPONSE" "allRenderable")"
    CLOSE_TERMINAL_PROBE_RESPONSE=""
    CLOSE_TERMINAL_READY="true"
    if [[ "$GHOSTTY_INPUT_READINESS_REQUIRED" == "1" ]]; then
      CLOSE_TERMINAL_READY="false"
      if [[ "$ALL_RENDERABLE" == "true" && -n "$FINAL_CLOSE_FOCUSED_PANEL_ID" ]]; then
        CLOSE_TERMINAL_PROBE_RESPONSE="$(probe_terminal_send_text_availability "$FINAL_CLOSE_FOCUSED_PANEL_ID")"
        if [[ "$(extract_bool_field "$CLOSE_TERMINAL_PROBE_RESPONSE" "available")" == "true" ]]; then
          CLOSE_TERMINAL_READY="true"
        fi
      fi
    fi
    if [[ "$CLOSE_SLOT_COUNT" == "$EXPECTED_CLOSE_SLOT_COUNT" && "$ALL_RENDERABLE" == "true" && -n "$FINAL_CLOSE_FOCUSED_PANEL_ID" && "$CLOSE_TERMINAL_READY" == "true" ]]; then
      break
    fi
    sleep 0.1
  done

  if [[ "$CLOSE_SLOT_COUNT" != "$EXPECTED_CLOSE_SLOT_COUNT" ]]; then
    echo "error: workspace.close-focused-panel did not reduce slot count as expected" >&2
    echo "expected slot count: ${EXPECTED_CLOSE_SLOT_COUNT}" >&2
    echo "actual slot count: ${CLOSE_SLOT_COUNT:-missing}" >&2
    echo "snapshot response: ${CLOSE_SNAPSHOT_RESPONSE}" >&2
    exit 1
  fi
  if [[ -z "$ALL_RENDERABLE" ]]; then
    echo "error: render snapshot missing allRenderable field after close-focused-panel" >&2
    echo "render snapshot response: ${RENDER_SNAPSHOT_RESPONSE}" >&2
    exit 1
  fi
  if [[ "$ALL_RENDERABLE" != "true" ]]; then
    echo "error: one or more terminal slots are not render-attached after close-focused-panel" >&2
    echo "workspace snapshot response: ${CLOSE_SNAPSHOT_RESPONSE}" >&2
    echo "render snapshot response: ${RENDER_SNAPSHOT_RESPONSE}" >&2
    exit 1
  fi
  if [[ -z "$FINAL_CLOSE_FOCUSED_PANEL_ID" ]]; then
    echo "error: workspace snapshot missing focusedPanelID after close-focused-panel" >&2
    echo "snapshot response: ${CLOSE_SNAPSHOT_RESPONSE}" >&2
    exit 1
  fi
  if [[ "$GHOSTTY_INPUT_READINESS_REQUIRED" == "1" && "$CLOSE_TERMINAL_READY" != "true" ]]; then
    echo "error: focused terminal surface not ready for send_text after close-focused-panel" >&2
    echo "workspace snapshot response: ${CLOSE_SNAPSHOT_RESPONSE}" >&2
    echo "render snapshot response: ${RENDER_SNAPSHOT_RESPONSE}" >&2
    echo "last terminal probe response: ${CLOSE_TERMINAL_PROBE_RESPONSE}" >&2
    exit 1
  fi
done

if [[ "$CLOSE_SLOT_COUNT" != "1" ]]; then
  echo "error: repeated close-focused-panel loop did not converge to a single slot" >&2
  echo "final slot count: ${CLOSE_SLOT_COUNT:-missing}" >&2
  echo "snapshot response: ${CLOSE_SNAPSHOT_RESPONSE}" >&2
  exit 1
fi
if [[ -z "$FINAL_CLOSE_LAYOUT_SIGNATURE" ]]; then
  echo "error: workspace snapshot missing layoutSignature after repeated close-focused-panel checks" >&2
  echo "snapshot response: ${CLOSE_SNAPSHOT_RESPONSE}" >&2
  exit 1
fi
if [[ -z "$FINAL_CLOSE_FOCUSED_PANEL_ID" ]]; then
  echo "error: workspace snapshot missing focusedPanelID after repeated close-focused-panel checks" >&2
  echo "snapshot response: ${CLOSE_SNAPSHOT_RESPONSE}" >&2
  exit 1
fi

TERMINAL_VIEWPORT_SCREENSHOT_PATH=""
FOCUSED_TERMINAL_SCREENSHOT_PATH=""
FOCUSED_TERMINAL_SECOND_SCREENSHOT_PATH=""
if [[ "$GHOSTTY_INTEGRATION_DISABLED" != "1" && -d "$GHOSTTY_XCFRAMEWORK_PATH" ]]; then
  if [[ ! -f "$GHOSTTY_XCFRAMEWORK_PATH/Info.plist" ]]; then
    echo "error: Ghostty xcframework appears invalid (missing Info.plist): $GHOSTTY_XCFRAMEWORK_PATH" >&2
    exit 1
  fi

  TERMINAL_TARGET_PANEL_ID=""
  TERMINAL_CANDIDATE_PANEL_IDS=(
    "$FINAL_CLOSE_FOCUSED_PANEL_ID"
  )
  TERMINAL_MARKER="TOASTTY_VIEWPORT_END_${RUN_ID//[^A-Za-z0-9_]/_}"
  TERMINAL_COMMAND="find /usr/bin -maxdepth 1 | head -n 120; echo ${TERMINAL_MARKER}"
  TERMINAL_COMMAND_JSON="$(json_escape_string "$TERMINAL_COMMAND")"
  TERMINAL_SEND_RESPONSE=""
  TERMINAL_PROBE_RESPONSE=""
  TERMINAL_SEND_READY=0
  TERMINAL_READY_ATTEMPTS="${TERMINAL_READY_ATTEMPTS:-40}"
  TERMINAL_READY_INTERVAL_SEC="${TERMINAL_READY_INTERVAL_SEC:-0.1}"
  for _ in $(seq 1 "$TERMINAL_READY_ATTEMPTS"); do
    for candidate_panel_id in "${TERMINAL_CANDIDATE_PANEL_IDS[@]}"; do
      if [[ -z "$candidate_panel_id" ]]; then
        continue
      fi
      TERMINAL_PROBE_RESPONSE="$(probe_terminal_send_text_availability "$candidate_panel_id")"
      if [[ "$(extract_bool_field "$TERMINAL_PROBE_RESPONSE" "available")" == "true" ]]; then
        TERMINAL_TARGET_PANEL_ID="$candidate_panel_id"
        TERMINAL_SEND_READY=1
        break
      fi
    done
    if [[ "$TERMINAL_SEND_READY" -eq 1 ]]; then
      break
    fi
    sleep "$TERMINAL_READY_INTERVAL_SEC"
  done
  if [[ "$TERMINAL_SEND_READY" -ne 1 ]]; then
    echo "error: terminal surface unavailable for send_text during smoke run" >&2
    echo "candidate panel ids: ${TERMINAL_CANDIDATE_PANEL_IDS[*]}" >&2
    echo "last terminal probe response: ${TERMINAL_PROBE_RESPONSE}" >&2
    exit 1
  fi

  send_request "automation.perform_action" "{\"action\":\"workspace.focus-panel\",\"args\":{\"panelID\":\"${TERMINAL_TARGET_PANEL_ID}\"}}" >/dev/null

  TERMINAL_SEND_READY=0
  TERMINAL_PROBE_RESPONSE=""
  for _ in $(seq 1 "$TERMINAL_READY_ATTEMPTS"); do
    TERMINAL_PROBE_RESPONSE="$(probe_terminal_send_text_availability "$TERMINAL_TARGET_PANEL_ID")"
    if [[ "$(extract_bool_field "$TERMINAL_PROBE_RESPONSE" "available")" == "true" ]]; then
      TERMINAL_SEND_READY=1
      break
    fi
    sleep "$TERMINAL_READY_INTERVAL_SEC"
  done
  if [[ "$TERMINAL_SEND_READY" -ne 1 ]]; then
    echo "error: terminal surface unavailable after workspace.focus-panel during smoke run" >&2
    echo "target panel id: ${TERMINAL_TARGET_PANEL_ID}" >&2
    echo "last terminal probe response: ${TERMINAL_PROBE_RESPONSE}" >&2
    exit 1
  fi

  CWD_ASSERTION_DIR="/tmp/toastty-smoke-cwd-${RUN_ID//[^A-Za-z0-9_-]/_}"
  mkdir -p "$CWD_ASSERTION_DIR"
  CWD_ASSERTION_COMMAND="cd \"${CWD_ASSERTION_DIR}\"; pwd"
  CWD_ASSERTION_COMMAND_JSON="$(json_escape_string "$CWD_ASSERTION_COMMAND")"
  send_request "automation.terminal_send_text" "{\"text\":\"${CWD_ASSERTION_COMMAND_JSON}\",\"submit\":true,\"allowUnavailable\":false,\"panelID\":\"${TERMINAL_TARGET_PANEL_ID}\"}" >/dev/null

  EXPECTED_CWD_CANONICAL="$(canonicalize_path "$CWD_ASSERTION_DIR")"
  CWD_SYNCED=0
  TERMINAL_STATE_RESPONSE=""
  TERMINAL_STATE_CWD=""
  TERMINAL_STATE_CWD_CANONICAL=""
  for _ in $(seq 1 40); do
    TERMINAL_STATE_RESPONSE="$(send_request "automation.terminal_state" "{\"panelID\":\"${TERMINAL_TARGET_PANEL_ID}\"}")"
    TERMINAL_STATE_CWD="$(extract_string_field "$TERMINAL_STATE_RESPONSE" "cwd")"
    TERMINAL_STATE_CWD_CANONICAL="$(canonicalize_path "$TERMINAL_STATE_CWD")"
    if [[ "$TERMINAL_STATE_CWD_CANONICAL" == "$EXPECTED_CWD_CANONICAL" ]]; then
      CWD_SYNCED=1
      break
    fi
    sleep 0.1
  done
  if [[ "$CWD_SYNCED" -ne 1 ]]; then
    echo "error: terminal cwd did not update after cd command" >&2
    echo "target panel id: ${TERMINAL_TARGET_PANEL_ID}" >&2
    echo "expected cwd: ${EXPECTED_CWD_CANONICAL}" >&2
    echo "last terminal_state response: ${TERMINAL_STATE_RESPONSE}" >&2
    exit 1
  fi

  send_request "automation.perform_action" '{"action":"workspace.split.right"}' >/dev/null
  CWD_SPLIT_RESPONSE="$(send_request "automation.workspace_snapshot" '{}')"
  SPLIT_INHERITED_PANEL_ID="$(extract_string_field "$CWD_SPLIT_RESPONSE" "focusedPanelID")"
  if [[ -z "$SPLIT_INHERITED_PANEL_ID" ]]; then
    echo "error: focused panel missing after cwd split assertion" >&2
    echo "snapshot response: ${CWD_SPLIT_RESPONSE}" >&2
    exit 1
  fi

  SPLIT_TERMINAL_STATE_RESPONSE=""
  SPLIT_TERMINAL_CWD=""
  SPLIT_TERMINAL_CWD_CANONICAL=""
  SPLIT_CWD_SYNCED=0
  for _ in $(seq 1 40); do
    SPLIT_TERMINAL_STATE_RESPONSE="$(send_request "automation.terminal_state" "{\"panelID\":\"${SPLIT_INHERITED_PANEL_ID}\"}")"
    SPLIT_TERMINAL_CWD="$(extract_string_field "$SPLIT_TERMINAL_STATE_RESPONSE" "cwd")"
    SPLIT_TERMINAL_CWD_CANONICAL="$(canonicalize_path "$SPLIT_TERMINAL_CWD")"
    if [[ "$SPLIT_TERMINAL_CWD_CANONICAL" == "$EXPECTED_CWD_CANONICAL" ]]; then
      SPLIT_CWD_SYNCED=1
      break
    fi
    sleep 0.1
  done
  if [[ "$SPLIT_CWD_SYNCED" -ne 1 ]]; then
    echo "error: split panel did not inherit cwd from source panel" >&2
    echo "source panel id: ${TERMINAL_TARGET_PANEL_ID}" >&2
    echo "new panel id: ${SPLIT_INHERITED_PANEL_ID}" >&2
    echo "expected cwd: ${EXPECTED_CWD_CANONICAL}" >&2
    echo "terminal_state response: ${SPLIT_TERMINAL_STATE_RESPONSE}" >&2
    exit 1
  fi
  TERMINAL_TARGET_PANEL_ID="$SPLIT_INHERITED_PANEL_ID"

  TERMINAL_SEND_READY=0
  TERMINAL_PROBE_RESPONSE=""
  for _ in $(seq 1 "$TERMINAL_READY_ATTEMPTS"); do
    TERMINAL_PROBE_RESPONSE="$(send_request "automation.terminal_send_text" "{\"text\":\"\",\"submit\":false,\"allowUnavailable\":true,\"panelID\":\"${TERMINAL_TARGET_PANEL_ID}\"}")"
    if [[ "$(extract_bool_field "$TERMINAL_PROBE_RESPONSE" "available")" == "true" ]]; then
      TERMINAL_SEND_READY=1
      break
    fi
    sleep "$TERMINAL_READY_INTERVAL_SEC"
  done
  if [[ "$TERMINAL_SEND_READY" -ne 1 ]]; then
    echo "error: split-created terminal surface unavailable for send_text during smoke run" >&2
    echo "target panel id: ${TERMINAL_TARGET_PANEL_ID}" >&2
    echo "last terminal probe response: ${TERMINAL_PROBE_RESPONSE}" >&2
    exit 1
  fi

  TERMINAL_SEND_RESPONSE="$(send_request "automation.terminal_send_text" "{\"text\":\"${TERMINAL_COMMAND_JSON}\",\"submit\":true,\"allowUnavailable\":false,\"panelID\":\"${TERMINAL_TARGET_PANEL_ID}\"}")"

  TERMINAL_FOUND=0
  TERMINAL_VISIBLE_RESPONSE=""
  for _ in $(seq 1 40); do
    TERMINAL_VISIBLE_RESPONSE="$(send_request "automation.terminal_visible_text" "{\"contains\":\"${TERMINAL_MARKER}\",\"panelID\":\"${TERMINAL_TARGET_PANEL_ID}\"}")"
    if echo "$TERMINAL_VISIBLE_RESPONSE" | grep -qE '"contains"[[:space:]]*:[[:space:]]*true'; then
      TERMINAL_FOUND=1
      break
    fi
    sleep 0.1
  done

  if [[ "$TERMINAL_FOUND" -ne 1 ]]; then
    echo "error: terminal viewport marker not observed during smoke run" >&2
    echo "target panel id: ${TERMINAL_TARGET_PANEL_ID}" >&2
    echo "last terminal response: ${TERMINAL_VISIBLE_RESPONSE}" >&2
    exit 1
  fi

  DROP_IMAGE_PATH="$(mktemp "/tmp/toastty drop ${RUN_ID} XXXXXX.png")"
  DROP_IMAGE_PATH_TO_CLEANUP="$DROP_IMAGE_PATH"
  DROP_IMAGE_PATH_JSON="$(json_escape_string "$DROP_IMAGE_PATH")"
  DROP_IMAGE_RESPONSE="$(send_request "automation.terminal_drop_image_files" "{\"files\":[\"${DROP_IMAGE_PATH_JSON}\"],\"panelID\":\"${TERMINAL_TARGET_PANEL_ID}\",\"allowUnavailable\":false}")"
  if [[ "$(extract_bool_field "$DROP_IMAGE_RESPONSE" "available")" != "true" ]]; then
    echo "error: terminal_drop_image_files reported unavailable surface" >&2
    echo "response: ${DROP_IMAGE_RESPONSE}" >&2
    exit 1
  fi
  DROP_ACCEPTED_COUNT="$(extract_int_field "$DROP_IMAGE_RESPONSE" "acceptedImageCount")"
  if [[ -z "$DROP_ACCEPTED_COUNT" || "$DROP_ACCEPTED_COUNT" -lt 1 ]]; then
    echo "error: terminal_drop_image_files did not accept image file" >&2
    echo "response: ${DROP_IMAGE_RESPONSE}" >&2
    exit 1
  fi

  DROP_EXPECTED_INPUT="'${DROP_IMAGE_PATH}'"
  DROP_EXPECTED_INPUT_JSON="$(json_escape_string "$DROP_EXPECTED_INPUT")"
  DROP_FOUND=0
  DROP_VISIBLE_RESPONSE=""
  for _ in $(seq 1 30); do
    DROP_VISIBLE_RESPONSE="$(send_request "automation.terminal_visible_text" "{\"contains\":\"${DROP_EXPECTED_INPUT_JSON}\",\"panelID\":\"${TERMINAL_TARGET_PANEL_ID}\"}")"
    if echo "$DROP_VISIBLE_RESPONSE" | grep -qE '"contains"[[:space:]]*:[[:space:]]*true'; then
      DROP_FOUND=1
      break
    fi
    sleep 0.1
  done

  if [[ "$DROP_FOUND" -ne 1 ]]; then
    echo "error: dropped image path not observed in terminal viewport during smoke run" >&2
    echo "target panel id: ${TERMINAL_TARGET_PANEL_ID}" >&2
    echo "expected input: ${DROP_EXPECTED_INPUT}" >&2
    echo "last terminal response: ${DROP_VISIBLE_RESPONSE}" >&2
    exit 1
  fi

  if [[ "$GHOSTTY_INPUT_READINESS_REQUIRED" == "1" ]]; then
    send_request "automation.perform_action" "{\"action\":\"workspace.split.right.with-profile\",\"args\":{\"profileID\":\"${PROFILE_SMOKE_PROFILE_ID}\"}}" >/dev/null
    PROFILE_SPLIT_RESPONSE="$(send_request "automation.workspace_snapshot" '{}')"
    PROFILE_PANEL_ID="$(extract_string_field "$PROFILE_SPLIT_RESPONSE" "focusedPanelID")"
    if [[ -z "$PROFILE_PANEL_ID" ]]; then
      echo "error: focused panel missing after profiled split" >&2
      echo "snapshot response: ${PROFILE_SPLIT_RESPONSE}" >&2
      exit 1
    fi

    PROFILE_VISIBLE_RESPONSE=""
    PROFILE_VISIBLE_FOUND=0
    for _ in $(seq 1 40); do
      PROFILE_VISIBLE_RESPONSE="$(send_request "automation.terminal_visible_text" "{\"contains\":\"${PROFILE_SMOKE_VISIBLE_MARKER}\",\"panelID\":\"${PROFILE_PANEL_ID}\"}")"
      if echo "$PROFILE_VISIBLE_RESPONSE" | grep -qE '"contains"[[:space:]]*:[[:space:]]*true'; then
        PROFILE_VISIBLE_FOUND=1
        break
      fi
      sleep 0.1
    done
    if [[ "$PROFILE_VISIBLE_FOUND" -ne 1 ]]; then
      echo "error: profiled pane startup command output not observed" >&2
      echo "panel id: ${PROFILE_PANEL_ID}" >&2
      echo "expected marker: ${PROFILE_SMOKE_VISIBLE_MARKER}" >&2
      echo "last visible text response: ${PROFILE_VISIBLE_RESPONSE}" >&2
      exit 1
    fi

    PROFILE_STATE_RESPONSE=""
    PROFILE_STATE_MATCHED=0
    for _ in $(seq 1 40); do
      PROFILE_STATE_RESPONSE="$(send_request "automation.terminal_state" "{\"panelID\":\"${PROFILE_PANEL_ID}\"}")"
      PROFILE_STATE_TITLE="$(extract_string_field "$PROFILE_STATE_RESPONSE" "title")"
      PROFILE_STATE_PROFILE_ID="$(extract_string_field "$PROFILE_STATE_RESPONSE" "profileID")"
      if [[ "$PROFILE_STATE_TITLE" == "$PROFILE_SMOKE_TITLE" && "$PROFILE_STATE_PROFILE_ID" == "$PROFILE_SMOKE_PROFILE_ID" ]]; then
        PROFILE_STATE_MATCHED=1
        break
      fi
      sleep 0.1
    done
    if [[ "$PROFILE_STATE_MATCHED" -ne 1 ]]; then
      echo "error: profiled pane metadata did not reflect startup title/profile binding" >&2
      echo "panel id: ${PROFILE_PANEL_ID}" >&2
      echo "expected title: ${PROFILE_SMOKE_TITLE}" >&2
      echo "expected profile id: ${PROFILE_SMOKE_PROFILE_ID}" >&2
      echo "last terminal_state response: ${PROFILE_STATE_RESPONSE}" >&2
      exit 1
    fi

    PROFILE_CLOSE_SLOT_COUNT="$(extract_int_field "$PROFILE_SPLIT_RESPONSE" "slotCount")"
    if [[ -z "$PROFILE_CLOSE_SLOT_COUNT" || "$PROFILE_CLOSE_SLOT_COUNT" -lt 2 ]]; then
      echo "error: profiled split did not leave enough slots for close-focused-panel validation" >&2
      echo "snapshot response: ${PROFILE_SPLIT_RESPONSE}" >&2
      exit 1
    fi

    send_request "automation.perform_action" '{"action":"workspace.close-focused-panel"}' >/dev/null
    EXPECTED_PROFILE_CLOSE_SLOT_COUNT=$((PROFILE_CLOSE_SLOT_COUNT - 1))
    PROFILE_CLOSE_RESPONSE=""
    PROFILE_CLOSE_RENDER_RESPONSE=""
    PROFILE_CLOSE_FOCUSED_PANEL_ID=""
    PROFILE_CLOSE_TERMINAL_READY="false"
    PROFILE_CLOSE_PROBE_RESPONSE=""
    for _ in $(seq 1 40); do
      PROFILE_CLOSE_RESPONSE="$(send_request "automation.workspace_snapshot" '{}')"
      PROFILE_CLOSE_SLOT_COUNT="$(extract_int_field "$PROFILE_CLOSE_RESPONSE" "slotCount")"
      PROFILE_CLOSE_FOCUSED_PANEL_ID="$(extract_string_field "$PROFILE_CLOSE_RESPONSE" "focusedPanelID")"
      PROFILE_CLOSE_RENDER_RESPONSE="$(send_request "automation.workspace_render_snapshot" '{}')"
      PROFILE_CLOSE_ALL_RENDERABLE="$(extract_bool_field "$PROFILE_CLOSE_RENDER_RESPONSE" "allRenderable")"
      PROFILE_CLOSE_TERMINAL_READY="true"
      PROFILE_CLOSE_PROBE_RESPONSE=""
      if [[ "$GHOSTTY_INPUT_READINESS_REQUIRED" == "1" ]]; then
        PROFILE_CLOSE_TERMINAL_READY="false"
        if [[ "$PROFILE_CLOSE_ALL_RENDERABLE" == "true" && -n "$PROFILE_CLOSE_FOCUSED_PANEL_ID" ]]; then
          PROFILE_CLOSE_PROBE_RESPONSE="$(probe_terminal_send_text_availability "$PROFILE_CLOSE_FOCUSED_PANEL_ID")"
          if [[ "$(extract_bool_field "$PROFILE_CLOSE_PROBE_RESPONSE" "available")" == "true" ]]; then
            PROFILE_CLOSE_TERMINAL_READY="true"
          fi
        fi
      fi
      if [[ "$PROFILE_CLOSE_SLOT_COUNT" == "$EXPECTED_PROFILE_CLOSE_SLOT_COUNT" && "$PROFILE_CLOSE_ALL_RENDERABLE" == "true" && -n "$PROFILE_CLOSE_FOCUSED_PANEL_ID" && "$PROFILE_CLOSE_TERMINAL_READY" == "true" ]]; then
        break
      fi
      sleep 0.1
    done
    if [[ "$PROFILE_CLOSE_SLOT_COUNT" != "$EXPECTED_PROFILE_CLOSE_SLOT_COUNT" ]]; then
      echo "error: profiled close-focused-panel did not reduce slot count as expected" >&2
      echo "expected slot count: ${EXPECTED_PROFILE_CLOSE_SLOT_COUNT}" >&2
      echo "actual slot count: ${PROFILE_CLOSE_SLOT_COUNT:-missing}" >&2
      echo "snapshot response: ${PROFILE_CLOSE_RESPONSE}" >&2
      exit 1
    fi
    if [[ "$PROFILE_CLOSE_ALL_RENDERABLE" != "true" ]]; then
      echo "error: profiled close-focused-panel left one or more surfaces non-renderable" >&2
      echo "workspace snapshot response: ${PROFILE_CLOSE_RESPONSE}" >&2
      echo "render snapshot response: ${PROFILE_CLOSE_RENDER_RESPONSE}" >&2
      exit 1
    fi
    if [[ -z "$PROFILE_CLOSE_FOCUSED_PANEL_ID" ]]; then
      echo "error: profiled close-focused-panel did not resolve a focused survivor panel" >&2
      echo "snapshot response: ${PROFILE_CLOSE_RESPONSE}" >&2
      exit 1
    fi
    if [[ "$GHOSTTY_INPUT_READINESS_REQUIRED" == "1" && "$PROFILE_CLOSE_TERMINAL_READY" != "true" ]]; then
      echo "error: surviving terminal surface was not input-ready after profiled close-focused-panel" >&2
      echo "workspace snapshot response: ${PROFILE_CLOSE_RESPONSE}" >&2
      echo "render snapshot response: ${PROFILE_CLOSE_RENDER_RESPONSE}" >&2
      echo "last terminal probe response: ${PROFILE_CLOSE_PROBE_RESPONSE}" >&2
      exit 1
    fi
  fi

  TERMINAL_VIEWPORT_RESPONSE="$(send_request "automation.capture_screenshot" '{"step":"terminal-viewport-smoke"}')"
  TERMINAL_VIEWPORT_SCREENSHOT_PATH="$(extract_string_field "$TERMINAL_VIEWPORT_RESPONSE" "path")"
  if [[ -z "$TERMINAL_VIEWPORT_SCREENSHOT_PATH" || ! -f "$TERMINAL_VIEWPORT_SCREENSHOT_PATH" ]]; then
    echo "error: terminal viewport screenshot path missing or file not found" >&2
    echo "capture response: ${TERMINAL_VIEWPORT_RESPONSE}" >&2
    exit 1
  fi

  send_request "automation.load_fixture" "{\"name\":\"${FIXTURE}\"}" >/dev/null
  FOCUSED_TERMINAL_BASELINE_RESPONSE="$(send_request "automation.workspace_snapshot" '{}')"
  FOCUSED_TERMINAL_BASELINE_PANEL_ID="$(extract_string_field "$FOCUSED_TERMINAL_BASELINE_RESPONSE" "focusedPanelID")"
  if [[ -z "$FOCUSED_TERMINAL_BASELINE_PANEL_ID" ]]; then
    echo "error: focused terminal baseline panel missing for focused-mode render scenario" >&2
    echo "snapshot response: ${FOCUSED_TERMINAL_BASELINE_RESPONSE}" >&2
    exit 1
  fi

  send_request "automation.perform_action" '{"action":"workspace.focus-slot.next"}' >/dev/null
  FOCUSED_TERMINAL_RIGHT_RESPONSE=""
  FOCUSED_TERMINAL_RIGHT_PANEL_ID=""
  for _ in $(seq 1 20); do
    FOCUSED_TERMINAL_RIGHT_RESPONSE="$(send_request "automation.workspace_snapshot" '{}')"
    FOCUSED_TERMINAL_RIGHT_PANEL_ID="$(extract_string_field "$FOCUSED_TERMINAL_RIGHT_RESPONSE" "focusedPanelID")"
    if [[ -n "$FOCUSED_TERMINAL_RIGHT_PANEL_ID" && "$FOCUSED_TERMINAL_RIGHT_PANEL_ID" != "$FOCUSED_TERMINAL_BASELINE_PANEL_ID" ]]; then
      break
    fi
    sleep 0.1
  done
  if [[ -z "$FOCUSED_TERMINAL_RIGHT_PANEL_ID" || "$FOCUSED_TERMINAL_RIGHT_PANEL_ID" == "$FOCUSED_TERMINAL_BASELINE_PANEL_ID" ]]; then
    echo "error: failed to focus right-side terminal before focused-mode render scenario" >&2
    echo "baseline focused panel: ${FOCUSED_TERMINAL_BASELINE_PANEL_ID}" >&2
    echo "snapshot response: ${FOCUSED_TERMINAL_RIGHT_RESPONSE}" >&2
    exit 1
  fi

  send_request "automation.perform_action" '{"action":"workspace.split.down"}' >/dev/null
  FOCUSED_TERMINAL_SPLIT_RESPONSE=""
  FOCUSED_TERMINAL_PANEL_ID=""
  FOCUSED_TERMINAL_SLOT_COUNT=""
  for _ in $(seq 1 30); do
    FOCUSED_TERMINAL_SPLIT_RESPONSE="$(send_request "automation.workspace_snapshot" '{}')"
    FOCUSED_TERMINAL_PANEL_ID="$(extract_string_field "$FOCUSED_TERMINAL_SPLIT_RESPONSE" "focusedPanelID")"
    FOCUSED_TERMINAL_SLOT_COUNT="$(extract_int_field "$FOCUSED_TERMINAL_SPLIT_RESPONSE" "slotCount")"
    if [[ -n "$FOCUSED_TERMINAL_PANEL_ID" && -n "$FOCUSED_TERMINAL_SLOT_COUNT" && "$FOCUSED_TERMINAL_SLOT_COUNT" -ge 3 && "$FOCUSED_TERMINAL_PANEL_ID" != "$FOCUSED_TERMINAL_RIGHT_PANEL_ID" ]]; then
      break
    fi
    sleep 0.1
  done
  if [[ -z "$FOCUSED_TERMINAL_PANEL_ID" || -z "$FOCUSED_TERMINAL_SLOT_COUNT" || "$FOCUSED_TERMINAL_SLOT_COUNT" -lt 3 ]]; then
    echo "error: focused terminal split-down scenario did not create third slot" >&2
    echo "snapshot response: ${FOCUSED_TERMINAL_SPLIT_RESPONSE}" >&2
    exit 1
  fi

  FOCUSED_TERMINAL_READY=0
  FOCUSED_TERMINAL_PROBE_RESPONSE=""
  for _ in $(seq 1 "$TERMINAL_READY_ATTEMPTS"); do
    FOCUSED_TERMINAL_PROBE_RESPONSE="$(send_request "automation.terminal_send_text" "{\"text\":\"\",\"submit\":false,\"allowUnavailable\":true,\"panelID\":\"${FOCUSED_TERMINAL_PANEL_ID}\"}")"
    if [[ "$(extract_bool_field "$FOCUSED_TERMINAL_PROBE_RESPONSE" "available")" == "true" ]]; then
      FOCUSED_TERMINAL_READY=1
      break
    fi
    sleep "$TERMINAL_READY_INTERVAL_SEC"
  done
  if [[ "$FOCUSED_TERMINAL_READY" -ne 1 ]]; then
    echo "error: third-slot terminal surface unavailable for focused-mode render scenario" >&2
    echo "target panel id: ${FOCUSED_TERMINAL_PANEL_ID}" >&2
    echo "last terminal probe response: ${FOCUSED_TERMINAL_PROBE_RESPONSE}" >&2
    exit 1
  fi

  FOCUSED_TERMINAL_MARKER="TOASTTY_FOCUSED_RENDER_${RUN_ID//[^A-Za-z0-9_]/_}"
  FOCUSED_TERMINAL_EXPECTED_OUTPUT="$(printf '%s' "$FOCUSED_TERMINAL_MARKER" | LC_ALL=C tr 'A-Z' 'a-z')"
  FOCUSED_TERMINAL_COMMAND="printf '%s\\n' \"\$(printf '%s' '${FOCUSED_TERMINAL_MARKER}' | LC_ALL=C tr 'A-Z' 'a-z')\""
  FOCUSED_TERMINAL_COMMAND_JSON="$(json_escape_string "$FOCUSED_TERMINAL_COMMAND")"
  send_request "automation.terminal_send_text" "{\"text\":\"${FOCUSED_TERMINAL_COMMAND_JSON}\",\"submit\":true,\"allowUnavailable\":false,\"panelID\":\"${FOCUSED_TERMINAL_PANEL_ID}\"}" >/dev/null

  FOCUSED_TERMINAL_VISIBLE_RESPONSE=""
  FOCUSED_TERMINAL_MARKER_FOUND=0
  for _ in $(seq 1 40); do
    FOCUSED_TERMINAL_VISIBLE_RESPONSE="$(send_request "automation.terminal_visible_text" "{\"contains\":\"${FOCUSED_TERMINAL_EXPECTED_OUTPUT}\",\"panelID\":\"${FOCUSED_TERMINAL_PANEL_ID}\"}")"
    if echo "$FOCUSED_TERMINAL_VISIBLE_RESPONSE" | grep -qE '"contains"[[:space:]]*:[[:space:]]*true'; then
      FOCUSED_TERMINAL_MARKER_FOUND=1
      break
    fi
    sleep 0.1
  done
  if [[ "$FOCUSED_TERMINAL_MARKER_FOUND" -ne 1 ]]; then
    echo "error: focused-mode terminal command output not observed before screenshot capture" >&2
    echo "target panel id: ${FOCUSED_TERMINAL_PANEL_ID}" >&2
    echo "last terminal response: ${FOCUSED_TERMINAL_VISIBLE_RESPONSE}" >&2
    exit 1
  fi

  send_request "automation.perform_action" '{"action":"topbar.toggle.focused-panel"}' >/dev/null
  FOCUSED_TERMINAL_VISIBLE_RESPONSE=""
  FOCUSED_TERMINAL_MARKER_FOUND=0
  for _ in $(seq 1 40); do
    FOCUSED_TERMINAL_VISIBLE_RESPONSE="$(send_request "automation.terminal_visible_text" "{\"contains\":\"${FOCUSED_TERMINAL_EXPECTED_OUTPUT}\",\"panelID\":\"${FOCUSED_TERMINAL_PANEL_ID}\"}")"
    if echo "$FOCUSED_TERMINAL_VISIBLE_RESPONSE" | grep -qE '"contains"[[:space:]]*:[[:space:]]*true'; then
      FOCUSED_TERMINAL_MARKER_FOUND=1
      break
    fi
    sleep 0.1
  done
  if [[ "$FOCUSED_TERMINAL_MARKER_FOUND" -ne 1 ]]; then
    echo "error: focused terminal output not visible after first focus-mode toggle" >&2
    echo "target panel id: ${FOCUSED_TERMINAL_PANEL_ID}" >&2
    echo "last terminal response: ${FOCUSED_TERMINAL_VISIBLE_RESPONSE}" >&2
    exit 1
  fi
  FOCUSED_TERMINAL_SCREENSHOT_RESPONSE="$(send_request "automation.capture_screenshot" '{"step":"focused-terminal-third-slot-smoke"}')"
  FOCUSED_TERMINAL_SCREENSHOT_PATH="$(extract_string_field "$FOCUSED_TERMINAL_SCREENSHOT_RESPONSE" "path")"
  if [[ -z "$FOCUSED_TERMINAL_SCREENSHOT_PATH" || ! -f "$FOCUSED_TERMINAL_SCREENSHOT_PATH" ]]; then
    echo "error: focused terminal screenshot path missing or file not found" >&2
    echo "capture response: ${FOCUSED_TERMINAL_SCREENSHOT_RESPONSE}" >&2
    exit 1
  fi
  send_request "automation.perform_action" '{"action":"topbar.toggle.focused-panel"}' >/dev/null
  # Match the reported manual repro: focus on, restore layout, then focus on again.
  sleep 0.2
  send_request "automation.perform_action" '{"action":"topbar.toggle.focused-panel"}' >/dev/null
  FOCUSED_TERMINAL_VISIBLE_RESPONSE=""
  FOCUSED_TERMINAL_MARKER_FOUND=0
  for _ in $(seq 1 40); do
    FOCUSED_TERMINAL_VISIBLE_RESPONSE="$(send_request "automation.terminal_visible_text" "{\"contains\":\"${FOCUSED_TERMINAL_EXPECTED_OUTPUT}\",\"panelID\":\"${FOCUSED_TERMINAL_PANEL_ID}\"}")"
    if echo "$FOCUSED_TERMINAL_VISIBLE_RESPONSE" | grep -qE '"contains"[[:space:]]*:[[:space:]]*true'; then
      FOCUSED_TERMINAL_MARKER_FOUND=1
      break
    fi
    sleep 0.1
  done
  if [[ "$FOCUSED_TERMINAL_MARKER_FOUND" -ne 1 ]]; then
    echo "error: focused terminal output not visible after second focus-mode toggle" >&2
    echo "target panel id: ${FOCUSED_TERMINAL_PANEL_ID}" >&2
    echo "last terminal response: ${FOCUSED_TERMINAL_VISIBLE_RESPONSE}" >&2
    exit 1
  fi
  FOCUSED_TERMINAL_SECOND_SCREENSHOT_RESPONSE="$(send_request "automation.capture_screenshot" '{"step":"focused-terminal-third-slot-second-pass-smoke"}')"
  FOCUSED_TERMINAL_SECOND_SCREENSHOT_PATH="$(extract_string_field "$FOCUSED_TERMINAL_SECOND_SCREENSHOT_RESPONSE" "path")"
  if [[ -z "$FOCUSED_TERMINAL_SECOND_SCREENSHOT_PATH" || ! -f "$FOCUSED_TERMINAL_SECOND_SCREENSHOT_PATH" ]]; then
    echo "error: second-pass focused terminal screenshot path missing or file not found" >&2
    echo "capture response: ${FOCUSED_TERMINAL_SECOND_SCREENSHOT_RESPONSE}" >&2
    exit 1
  fi
  send_request "automation.perform_action" '{"action":"topbar.toggle.focused-panel"}' >/dev/null
  send_request "automation.load_fixture" "{\"name\":\"${FIXTURE}\"}" >/dev/null
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
echo "focused terminal screenshot: ${FOCUSED_TERMINAL_SCREENSHOT_PATH:-skipped}"
echo "focused terminal second screenshot: ${FOCUSED_TERMINAL_SECOND_SCREENSHOT_PATH:-skipped}"
echo "focused screenshot: ${FOCUSED_SCREENSHOT_PATH:-unknown}"
echo "screenshot: ${SCREENSHOT_PATH:-unknown}"
echo "state dump: ${STATE_PATH:-unknown}"
echo "state hash: ${STATE_HASH:-unknown}"
echo "app log: $LOG_FILE"
