#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOOTSTRAP_WORKTREE_SCRIPT="$ROOT_DIR/scripts/dev/bootstrap-worktree.sh"
RUN_ID="${RUN_ID:-shortcut-trace-$(date +%Y%m%d-%H%M%S)}"
FIXTURE="${FIXTURE:-split-workspace}"
DEV_RUN_ROOT="${DEV_RUN_ROOT:-$ROOT_DIR/artifacts/dev-runs/$RUN_ID}"
DERIVED_PATH="${DERIVED_PATH:-$DEV_RUN_ROOT/Derived}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$DEV_RUN_ROOT/artifacts}"
TOASTTY_RUNTIME_HOME="${TOASTTY_RUNTIME_HOME:-$DEV_RUN_ROOT/runtime-home}"
SOCKET_TOKEN="$(printf '%s' "$RUN_ID" | cksum | awk '{printf "%08x", $1}')"
SOCKET_PATH="${SOCKET_PATH:-${TMPDIR:-/tmp}/tt-trace-${SOCKET_TOKEN}.sock}"
ARCH="${ARCH:-$(uname -m)}"
CLICK_X="${CLICK_X:-760}"
CLICK_Y="${CLICK_Y:-420}"
TRACE_LOG_PATH="${TRACE_LOG_PATH:-$TOASTTY_RUNTIME_HOME/logs/shortcut-trace.log}"
SPLIT_KEY_CODE="${SPLIT_KEY_CODE:-2}"
FOCUS_NEXT_KEY_CODE="${FOCUS_NEXT_KEY_CODE:-30}"
FOCUS_PREVIOUS_KEY_CODE="${FOCUS_PREVIOUS_KEY_CODE:-33}"
RESIZE_KEY_CODE="${RESIZE_KEY_CODE:-124}"
EQUALIZE_KEY_CODE="${EQUALIZE_KEY_CODE:-24}"

if [[ "$ARCH" != "arm64" && "$ARCH" != "x86_64" ]]; then
  ARCH="arm64"
fi

READY_FILE="$ARTIFACTS_DIR/automation-ready-${RUN_ID}.json"
APP_BINARY="$DERIVED_PATH/Build/Products/Debug/Toastty.app/Contents/MacOS/Toastty"
APP_LOG_FILE="$ARTIFACTS_DIR/app-${RUN_ID}.log"
GHOSTTY_DEBUG_XCFRAMEWORK_PATH="$ROOT_DIR/Dependencies/GhosttyKit.Debug.xcframework"
GHOSTTY_RELEASE_XCFRAMEWORK_PATH="$ROOT_DIR/Dependencies/GhosttyKit.Release.xcframework"

mkdir -p "$ARTIFACTS_DIR" "$TOASTTY_RUNTIME_HOME" "$(dirname "$SOCKET_PATH")" "$(dirname "$TRACE_LOG_PATH")"
rm -f "$SOCKET_PATH" "$READY_FILE" "$APP_LOG_FILE"
rm -f "$TRACE_LOG_PATH"

if [[ "${TUIST_DISABLE_GHOSTTY:-0}" == "1" || "${TOASTTY_DISABLE_GHOSTTY:-0}" == "1" ]]; then
  echo "error: shortcut trace requires Ghostty-enabled build (disable flags are set)" >&2
  exit 78
fi

if ! command -v nc >/dev/null 2>&1; then
  echo "error: nc is required for socket requests" >&2
  exit 78
fi

if ! command -v uuidgen >/dev/null 2>&1; then
  echo "error: uuidgen is required for request ids" >&2
  exit 78
fi

if ! command -v osascript >/dev/null 2>&1; then
  echo "error: osascript is required for shortcut tracing" >&2
  exit 78
fi

if ! command -v perl >/dev/null 2>&1; then
  echo "error: perl is required for shortcut tracing permission preflight" >&2
  exit 78
fi

run_with_timeout() {
  local timeout_seconds="$1"
  shift

  perl -e '
my $timeout = shift @ARGV;
my $pid = fork();
die "fork failed\n" unless defined $pid;
if ($pid == 0) {
  exec @ARGV or exit 127;
}
local $SIG{ALRM} = sub {
  kill "TERM", $pid;
  select undef, undef, undef, 0.2;
  kill "KILL", $pid;
  exit 124;
};
alarm $timeout;
waitpid($pid, 0);
alarm 0;
exit($? >> 8);
' "$timeout_seconds" "$@"
}

verify_system_events_access() {
  if run_with_timeout 5 osascript -e 'tell application "System Events" to count processes' >/dev/null 2>&1; then
    return 0
  fi

  local exit_code=$?
  case "$exit_code" in
    124)
      echo "error: System Events automation check timed out. Grant Automation and Accessibility permissions in the active GUI session before running shortcut-trace" >&2
      ;;
    *)
      echo "error: System Events automation check failed. Grant Automation and Accessibility permissions in the active GUI session before running shortcut-trace" >&2
      ;;
  esac
  return 78
}

cleanup() {
  if [[ -n "${APP_PID:-}" ]]; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if ! "$BOOTSTRAP_WORKTREE_SCRIPT" >/dev/null; then
  exit 1
fi

if [[ ! -f "$GHOSTTY_DEBUG_XCFRAMEWORK_PATH/Info.plist" && ! -f "$GHOSTTY_RELEASE_XCFRAMEWORK_PATH/Info.plist" ]]; then
  echo "error: Ghostty xcframework missing or invalid after bootstrap: expected $GHOSTTY_DEBUG_XCFRAMEWORK_PATH or $GHOSTTY_RELEASE_XCFRAMEWORK_PATH" >&2
  exit 78
fi

verify_system_events_access

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

extract_string_field() {
  local json="$1"
  local field="$2"
  if command -v jq >/dev/null 2>&1; then
    echo "$json" | jq -r --arg field "$field" '(.result[$field] // .[$field] // empty) | select(type == "string")'
    return
  fi

  echo "$json" \
    | tr -d '\n' \
    | sed -nE "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\\1/p"
}

extract_bool_field() {
  local json="$1"
  local field="$2"
  if command -v jq >/dev/null 2>&1; then
    echo "$json" | jq -r --arg field "$field" '(.result[$field] // .[$field] // empty) | select(type == "boolean")'
    return
  fi

  echo "$json" \
    | tr -d '\n' \
    | sed -nE "s/.*\"${field}\"[[:space:]]*:[[:space:]]*(true|false).*/\\1/p"
}

count_intent_logs() {
  local intent="$1"
  awk -v intent="\"intent\":\"${intent}\"" 'index($0, intent) { c++ } END { print c + 0 }' "$TRACE_LOG_PATH"
}

count_input_key_logs() {
  local key_code="$1"
  awk -v keyCode="\"key_code\":\"${key_code}\"" 'index($0, "\"category\":\"input\"") && index($0, keyCode) { c++ } END { print c + 0 }' "$TRACE_LOG_PATH"
}

focus_app_terminal() {
  osascript <<OSA
tell application "Toastty" to activate
delay 0.5
tell application "System Events"
  click at {${CLICK_X}, ${CLICK_Y}}
  delay 0.2
end tell
OSA
}

send_split_right_shortcut() {
  osascript -e "tell application \"System Events\" to key code ${SPLIT_KEY_CODE} using {command down}"
}

send_split_down_shortcut() {
  osascript -e "tell application \"System Events\" to key code ${SPLIT_KEY_CODE} using {command down, shift down}"
}

send_focus_next_shortcut() {
  osascript -e "tell application \"System Events\" to key code ${FOCUS_NEXT_KEY_CODE} using {command down}"
}

send_focus_previous_shortcut() {
  osascript -e "tell application \"System Events\" to key code ${FOCUS_PREVIOUS_KEY_CODE} using {command down}"
}

send_resize_shortcut() {
  osascript -e "tell application \"System Events\" to key code ${RESIZE_KEY_CODE} using {command down, control down}"
}

send_equalize_shortcut() {
  osascript -e "tell application \"System Events\" to key code ${EQUALIZE_KEY_CODE} using {command down, control down}"
}

send_workspace_shortcut() {
  local index="$1"
  osascript -e "tell application \"System Events\" to keystroke \"${index}\" using {option down}"
}

send_panel_focus_shortcut() {
  local index="$1"
  osascript -e "tell application \"System Events\" to keystroke \"${index}\" using {option down, shift down}"
}

send_close_shortcut() {
  osascript -e 'tell application "System Events" to keystroke "w" using {command down}'
}

send_workspace_close_menu() {
  osascript <<'OSA'
tell application "Toastty" to activate
delay 0.2
tell application "System Events"
  tell process "Toastty"
    click menu item "Close Panel" of menu "Workspace" of menu bar item "Workspace" of menu bar 1
  end tell
end tell
OSA
}

strip_focus_from_layout_signature() {
  local signature="$1"
  echo "${signature#*;}"
}

prepare_close_equivalence_fixture() {
  local baseline_snapshot=""
  local baseline_slot_count_raw=""
  local baseline_slot_count=""
  local split_right_snapshot=""
  local split_right_slot_count_raw=""
  local split_down_snapshot=""
  local split_down_slot_count_raw=""

  send_request "automation.load_fixture" "{\"name\":\"${FIXTURE}\"}" >/dev/null

  for _ in $(seq 1 20); do
    baseline_snapshot="$(send_request "automation.workspace_snapshot" '{}')"
    baseline_slot_count_raw="$(extract_double_field "$baseline_snapshot" "slotCount")"
    if [[ -n "$baseline_slot_count_raw" ]]; then
      break
    fi
    sleep 0.1
  done
  if [[ -z "$baseline_slot_count_raw" ]]; then
    echo "error: close-equivalence baseline snapshot missing slotCount" >&2
    echo "snapshot response: ${baseline_snapshot}" >&2
    exit 1
  fi
  baseline_slot_count="${baseline_slot_count_raw%.*}"

  send_request "automation.perform_action" '{"action":"workspace.split.right"}' >/dev/null
  for _ in $(seq 1 20); do
    split_right_snapshot="$(send_request "automation.workspace_snapshot" '{}')"
    split_right_slot_count_raw="$(extract_double_field "$split_right_snapshot" "slotCount")"
    if [[ -n "$split_right_slot_count_raw" && "${split_right_slot_count_raw%.*}" -ge $((baseline_slot_count + 1)) ]]; then
      break
    fi
    sleep 0.1
  done
  if [[ -z "$split_right_slot_count_raw" ]]; then
    echo "error: close-equivalence split-right snapshot missing slotCount" >&2
    echo "snapshot response: ${split_right_snapshot}" >&2
    exit 1
  fi

  send_request "automation.perform_action" '{"action":"workspace.split.down"}' >/dev/null
  for _ in $(seq 1 20); do
    split_down_snapshot="$(send_request "automation.workspace_snapshot" '{}')"
    split_down_slot_count_raw="$(extract_double_field "$split_down_snapshot" "slotCount")"
    if [[ -n "$split_down_slot_count_raw" && "${split_down_slot_count_raw%.*}" -ge $((baseline_slot_count + 2)) ]]; then
      break
    fi
    sleep 0.1
  done
  if [[ -z "$split_down_slot_count_raw" ]]; then
    echo "error: close-equivalence split-down snapshot missing slotCount" >&2
    echo "snapshot response: ${split_down_snapshot}" >&2
    exit 1
  fi

  PREPARED_CLOSE_SLOT_COUNT="${split_down_slot_count_raw%.*}"
}

capture_close_outcome() {
  local path_kind="$1"
  local close_snapshot=""
  local render_snapshot=""
  local close_slot_count=""
  local all_renderable=""
  local layout_signature=""
  local expected_close_count=""

  prepare_close_equivalence_fixture
  expected_close_count=$((PREPARED_CLOSE_SLOT_COUNT - 1))
  focus_app_terminal

  case "$path_kind" in
    action)
      send_request "automation.perform_action" '{"action":"workspace.close-focused-panel"}' >/dev/null
      ;;
    menu)
      send_workspace_close_menu
      ;;
    shortcut)
      send_close_shortcut
      ;;
    *)
      echo "error: unknown close path kind: $path_kind" >&2
      exit 1
      ;;
  esac

  for _ in $(seq 1 40); do
    close_snapshot="$(send_request "automation.workspace_snapshot" '{}')"
    close_slot_count="$(extract_double_field "$close_snapshot" "slotCount")"
    layout_signature="$(extract_string_field "$close_snapshot" "layoutSignature")"
    render_snapshot="$(send_request "automation.workspace_render_snapshot" '{}')"
    all_renderable="$(extract_bool_field "$render_snapshot" "allRenderable")"
    if [[ -n "$close_slot_count" && "${close_slot_count%.*}" == "$expected_close_count" && -n "$layout_signature" && "$all_renderable" == "true" ]]; then
      printf '%s' "$layout_signature"
      return 0
    fi
    sleep 0.1
  done

  echo "error: ${path_kind} close path did not reach expected close outcome" >&2
  echo "expected slot count: ${expected_close_count}" >&2
  echo "observed slot count: ${close_slot_count:-<missing>}" >&2
  echo "layout signature: ${layout_signature:-<missing>}" >&2
  echo "workspace snapshot response: ${close_snapshot}" >&2
  echo "render snapshot response: ${render_snapshot}" >&2
  exit 1
}

cd "$ROOT_DIR"

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
TOASTTY_LOG_LEVEL=debug \
TOASTTY_LOG_FILE="$TRACE_LOG_PATH" \
"$APP_BINARY" \
  --automation \
  --skip-quit-confirmation \
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

send_request "automation.load_fixture" "{\"name\":\"${FIXTURE}\"}"
SPLIT_BASELINE_SNAPSHOT=""
SPLIT_BASELINE_SLOT_COUNT_RAW=""
SPLIT_BASELINE_FOCUS_ID=""
for _ in $(seq 1 20); do
  SPLIT_BASELINE_SNAPSHOT="$(send_request "automation.workspace_snapshot" '{}')"
  SPLIT_BASELINE_SLOT_COUNT_RAW="$(extract_double_field "$SPLIT_BASELINE_SNAPSHOT" "slotCount")"
  SPLIT_BASELINE_FOCUS_ID="$(extract_string_field "$SPLIT_BASELINE_SNAPSHOT" "focusedPanelID")"
  if [[ -n "$SPLIT_BASELINE_SLOT_COUNT_RAW" && -n "$SPLIT_BASELINE_FOCUS_ID" ]]; then
    break
  fi
  sleep 0.1
done
if [[ -z "$SPLIT_BASELINE_SLOT_COUNT_RAW" || -z "$SPLIT_BASELINE_FOCUS_ID" ]]; then
  echo "error: missing split-workflow baseline snapshot fields" >&2
  echo "snapshot response: ${SPLIT_BASELINE_SNAPSHOT}" >&2
  exit 1
fi
SPLIT_BASELINE_SLOT_COUNT="${SPLIT_BASELINE_SLOT_COUNT_RAW%.*}"

focus_app_terminal

send_split_right_shortcut
SPLIT_RIGHT_SNAPSHOT=""
SPLIT_RIGHT_SLOT_COUNT=""
SPLIT_RIGHT_FOCUS_ID=""
EXPECTED_SPLIT_RIGHT_COUNT=$((SPLIT_BASELINE_SLOT_COUNT + 1))
for _ in $(seq 1 20); do
  SPLIT_RIGHT_SNAPSHOT="$(send_request "automation.workspace_snapshot" '{}')"
  SPLIT_RIGHT_SLOT_COUNT_RAW="$(extract_double_field "$SPLIT_RIGHT_SNAPSHOT" "slotCount")"
  SPLIT_RIGHT_FOCUS_ID="$(extract_string_field "$SPLIT_RIGHT_SNAPSHOT" "focusedPanelID")"
  if [[ -n "$SPLIT_RIGHT_SLOT_COUNT_RAW" ]]; then
    SPLIT_RIGHT_SLOT_COUNT="${SPLIT_RIGHT_SLOT_COUNT_RAW%.*}"
  fi
  if [[ -n "$SPLIT_RIGHT_SLOT_COUNT" && "$SPLIT_RIGHT_SLOT_COUNT" -ge "$EXPECTED_SPLIT_RIGHT_COUNT" && -n "$SPLIT_RIGHT_FOCUS_ID" ]]; then
    break
  fi
  sleep 0.1
done
if [[ -z "$SPLIT_RIGHT_SLOT_COUNT" || "$SPLIT_RIGHT_SLOT_COUNT" -lt "$EXPECTED_SPLIT_RIGHT_COUNT" || -z "$SPLIT_RIGHT_FOCUS_ID" ]]; then
  echo "error: split-right shortcut did not increase slot count" >&2
  echo "baseline slot count: ${SPLIT_BASELINE_SLOT_COUNT}" >&2
  echo "expected minimum slot count: ${EXPECTED_SPLIT_RIGHT_COUNT}" >&2
  echo "observed slot count: ${SPLIT_RIGHT_SLOT_COUNT:-<missing>}" >&2
  echo "snapshot response: ${SPLIT_RIGHT_SNAPSHOT}" >&2
  exit 1
fi

send_focus_next_shortcut
FOCUS_NEXT_SNAPSHOT=""
FOCUS_NEXT_PANEL_ID=""
for _ in $(seq 1 20); do
  FOCUS_NEXT_SNAPSHOT="$(send_request "automation.workspace_snapshot" '{}')"
  FOCUS_NEXT_PANEL_ID="$(extract_string_field "$FOCUS_NEXT_SNAPSHOT" "focusedPanelID")"
  if [[ -n "$FOCUS_NEXT_PANEL_ID" && "$FOCUS_NEXT_PANEL_ID" != "$SPLIT_RIGHT_FOCUS_ID" ]]; then
    break
  fi
  sleep 0.1
done
if [[ -z "$FOCUS_NEXT_PANEL_ID" || "$FOCUS_NEXT_PANEL_ID" == "$SPLIT_RIGHT_FOCUS_ID" ]]; then
  echo "error: focus-next shortcut did not change focused panel" >&2
  echo "focused panel before focus-next: ${SPLIT_RIGHT_FOCUS_ID}" >&2
  echo "focused panel after focus-next: ${FOCUS_NEXT_PANEL_ID:-<missing>}" >&2
  echo "snapshot response: ${FOCUS_NEXT_SNAPSHOT}" >&2
  exit 1
fi

send_focus_previous_shortcut
FOCUS_PREVIOUS_SNAPSHOT=""
FOCUS_PREVIOUS_PANEL_ID=""
for _ in $(seq 1 20); do
  FOCUS_PREVIOUS_SNAPSHOT="$(send_request "automation.workspace_snapshot" '{}')"
  FOCUS_PREVIOUS_PANEL_ID="$(extract_string_field "$FOCUS_PREVIOUS_SNAPSHOT" "focusedPanelID")"
  if [[ -n "$FOCUS_PREVIOUS_PANEL_ID" && "$FOCUS_PREVIOUS_PANEL_ID" == "$SPLIT_RIGHT_FOCUS_ID" ]]; then
    break
  fi
  sleep 0.1
done
if [[ -z "$FOCUS_PREVIOUS_PANEL_ID" || "$FOCUS_PREVIOUS_PANEL_ID" != "$SPLIT_RIGHT_FOCUS_ID" ]]; then
  echo "error: focus-previous shortcut did not restore focused panel" >&2
  echo "expected focused panel after focus-previous: ${SPLIT_RIGHT_FOCUS_ID}" >&2
  echo "observed focused panel: ${FOCUS_PREVIOUS_PANEL_ID:-<missing>}" >&2
  echo "snapshot response: ${FOCUS_PREVIOUS_SNAPSHOT}" >&2
  exit 1
fi

send_split_down_shortcut
SPLIT_DOWN_SNAPSHOT=""
SPLIT_DOWN_SLOT_COUNT=""
EXPECTED_SPLIT_DOWN_COUNT=$((SPLIT_BASELINE_SLOT_COUNT + 2))
for _ in $(seq 1 20); do
  SPLIT_DOWN_SNAPSHOT="$(send_request "automation.workspace_snapshot" '{}')"
  SPLIT_DOWN_SLOT_COUNT_RAW="$(extract_double_field "$SPLIT_DOWN_SNAPSHOT" "slotCount")"
  if [[ -n "$SPLIT_DOWN_SLOT_COUNT_RAW" ]]; then
    SPLIT_DOWN_SLOT_COUNT="${SPLIT_DOWN_SLOT_COUNT_RAW%.*}"
  fi
  if [[ -n "$SPLIT_DOWN_SLOT_COUNT" && "$SPLIT_DOWN_SLOT_COUNT" -ge "$EXPECTED_SPLIT_DOWN_COUNT" ]]; then
    break
  fi
  sleep 0.1
done
if [[ -z "$SPLIT_DOWN_SLOT_COUNT" || "$SPLIT_DOWN_SLOT_COUNT" -lt "$EXPECTED_SPLIT_DOWN_COUNT" ]]; then
  echo "error: split-down shortcut did not increase slot count" >&2
  echo "expected minimum slot count: ${EXPECTED_SPLIT_DOWN_COUNT}" >&2
  echo "observed slot count: ${SPLIT_DOWN_SLOT_COUNT:-<missing>}" >&2
  echo "snapshot response: ${SPLIT_DOWN_SNAPSHOT}" >&2
  exit 1
fi

send_request "automation.load_fixture" "{\"name\":\"${FIXTURE}\"}" >/dev/null
WORKSPACE_SWITCH_FIRST_SNAPSHOT=""
WORKSPACE_SWITCH_FIRST_WORKSPACE_ID=""
WORKSPACE_SWITCH_FIRST_SLOT_COUNT_RAW=""
for _ in $(seq 1 20); do
  WORKSPACE_SWITCH_FIRST_SNAPSHOT="$(send_request "automation.workspace_snapshot" '{}')"
  WORKSPACE_SWITCH_FIRST_WORKSPACE_ID="$(extract_string_field "$WORKSPACE_SWITCH_FIRST_SNAPSHOT" "workspaceID")"
  WORKSPACE_SWITCH_FIRST_SLOT_COUNT_RAW="$(extract_double_field "$WORKSPACE_SWITCH_FIRST_SNAPSHOT" "slotCount")"
  if [[ -n "$WORKSPACE_SWITCH_FIRST_WORKSPACE_ID" && -n "$WORKSPACE_SWITCH_FIRST_SLOT_COUNT_RAW" ]]; then
    break
  fi
  sleep 0.1
done
if [[ -z "$WORKSPACE_SWITCH_FIRST_WORKSPACE_ID" || -z "$WORKSPACE_SWITCH_FIRST_SLOT_COUNT_RAW" ]]; then
  echo "error: missing baseline workspace snapshot fields for workspace-switch regression" >&2
  echo "snapshot response: ${WORKSPACE_SWITCH_FIRST_SNAPSHOT}" >&2
  exit 1
fi
WORKSPACE_SWITCH_FIRST_SLOT_COUNT="${WORKSPACE_SWITCH_FIRST_SLOT_COUNT_RAW%.*}"

send_request "automation.perform_action" '{"action":"sidebar.workspaces.new"}' >/dev/null
WORKSPACE_SWITCH_SECOND_SNAPSHOT=""
WORKSPACE_SWITCH_SECOND_WORKSPACE_ID=""
WORKSPACE_SWITCH_SECOND_SLOT_COUNT_RAW=""
for _ in $(seq 1 20); do
  WORKSPACE_SWITCH_SECOND_SNAPSHOT="$(send_request "automation.workspace_snapshot" '{}')"
  WORKSPACE_SWITCH_SECOND_WORKSPACE_ID="$(extract_string_field "$WORKSPACE_SWITCH_SECOND_SNAPSHOT" "workspaceID")"
  WORKSPACE_SWITCH_SECOND_SLOT_COUNT_RAW="$(extract_double_field "$WORKSPACE_SWITCH_SECOND_SNAPSHOT" "slotCount")"
  if [[ -n "$WORKSPACE_SWITCH_SECOND_WORKSPACE_ID" && -n "$WORKSPACE_SWITCH_SECOND_SLOT_COUNT_RAW" ]]; then
    break
  fi
  sleep 0.1
done
if [[ -z "$WORKSPACE_SWITCH_SECOND_WORKSPACE_ID" || -z "$WORKSPACE_SWITCH_SECOND_SLOT_COUNT_RAW" ]]; then
  echo "error: missing second-workspace snapshot fields for workspace-switch regression" >&2
  echo "snapshot response: ${WORKSPACE_SWITCH_SECOND_SNAPSHOT}" >&2
  exit 1
fi
if [[ "$WORKSPACE_SWITCH_SECOND_WORKSPACE_ID" == "$WORKSPACE_SWITCH_FIRST_WORKSPACE_ID" ]]; then
  echo "error: sidebar.workspaces.new did not select a distinct workspace" >&2
  echo "first workspace ID: ${WORKSPACE_SWITCH_FIRST_WORKSPACE_ID}" >&2
  echo "second workspace snapshot response: ${WORKSPACE_SWITCH_SECOND_SNAPSHOT}" >&2
  exit 1
fi
WORKSPACE_SWITCH_SECOND_SLOT_COUNT="${WORKSPACE_SWITCH_SECOND_SLOT_COUNT_RAW%.*}"

focus_app_terminal
send_workspace_shortcut 1

WORKSPACE_SWITCH_SELECTED_FIRST_SNAPSHOT=""
WORKSPACE_SWITCH_SELECTED_FIRST_WORKSPACE_ID=""
for _ in $(seq 1 20); do
  WORKSPACE_SWITCH_SELECTED_FIRST_SNAPSHOT="$(send_request "automation.workspace_snapshot" '{}')"
  WORKSPACE_SWITCH_SELECTED_FIRST_WORKSPACE_ID="$(extract_string_field "$WORKSPACE_SWITCH_SELECTED_FIRST_SNAPSHOT" "workspaceID")"
  if [[ -n "$WORKSPACE_SWITCH_SELECTED_FIRST_WORKSPACE_ID" && "$WORKSPACE_SWITCH_SELECTED_FIRST_WORKSPACE_ID" == "$WORKSPACE_SWITCH_FIRST_WORKSPACE_ID" ]]; then
    break
  fi
  sleep 0.1
done
if [[ -z "$WORKSPACE_SWITCH_SELECTED_FIRST_WORKSPACE_ID" || "$WORKSPACE_SWITCH_SELECTED_FIRST_WORKSPACE_ID" != "$WORKSPACE_SWITCH_FIRST_WORKSPACE_ID" ]]; then
  echo "error: workspace-switch regression did not select workspace 1 via Option+1" >&2
  echo "expected workspace ID: ${WORKSPACE_SWITCH_FIRST_WORKSPACE_ID}" >&2
  echo "observed workspace ID: ${WORKSPACE_SWITCH_SELECTED_FIRST_WORKSPACE_ID:-<missing>}" >&2
  echo "snapshot response: ${WORKSPACE_SWITCH_SELECTED_FIRST_SNAPSHOT}" >&2
  exit 1
fi

send_split_right_shortcut
WORKSPACE_SWITCH_FIRST_AFTER_SPLIT_SNAPSHOT=""
WORKSPACE_SWITCH_FIRST_AFTER_SPLIT_SLOT_COUNT=""
EXPECTED_WORKSPACE_SWITCH_FIRST_AFTER_SPLIT=$((WORKSPACE_SWITCH_FIRST_SLOT_COUNT + 1))
for _ in $(seq 1 20); do
  WORKSPACE_SWITCH_FIRST_AFTER_SPLIT_SNAPSHOT="$(send_request "automation.workspace_snapshot" "{\"workspaceID\":\"${WORKSPACE_SWITCH_FIRST_WORKSPACE_ID}\"}")"
  WORKSPACE_SWITCH_FIRST_AFTER_SPLIT_SLOT_COUNT_RAW="$(extract_double_field "$WORKSPACE_SWITCH_FIRST_AFTER_SPLIT_SNAPSHOT" "slotCount")"
  if [[ -n "$WORKSPACE_SWITCH_FIRST_AFTER_SPLIT_SLOT_COUNT_RAW" ]]; then
    WORKSPACE_SWITCH_FIRST_AFTER_SPLIT_SLOT_COUNT="${WORKSPACE_SWITCH_FIRST_AFTER_SPLIT_SLOT_COUNT_RAW%.*}"
  fi
  if [[ -n "$WORKSPACE_SWITCH_FIRST_AFTER_SPLIT_SLOT_COUNT" && "$WORKSPACE_SWITCH_FIRST_AFTER_SPLIT_SLOT_COUNT" -ge "$EXPECTED_WORKSPACE_SWITCH_FIRST_AFTER_SPLIT" ]]; then
    break
  fi
  sleep 0.1
done
if [[ -z "$WORKSPACE_SWITCH_FIRST_AFTER_SPLIT_SLOT_COUNT" || "$WORKSPACE_SWITCH_FIRST_AFTER_SPLIT_SLOT_COUNT" -lt "$EXPECTED_WORKSPACE_SWITCH_FIRST_AFTER_SPLIT" ]]; then
  echo "error: Cmd+D after Option+1 workspace switch did not split the visible workspace" >&2
  echo "workspace 1 baseline slot count: ${WORKSPACE_SWITCH_FIRST_SLOT_COUNT}" >&2
  echo "expected workspace 1 slot count after split: ${EXPECTED_WORKSPACE_SWITCH_FIRST_AFTER_SPLIT}" >&2
  echo "observed workspace 1 slot count: ${WORKSPACE_SWITCH_FIRST_AFTER_SPLIT_SLOT_COUNT:-<missing>}" >&2
  echo "snapshot response: ${WORKSPACE_SWITCH_FIRST_AFTER_SPLIT_SNAPSHOT}" >&2
  exit 1
fi

send_workspace_shortcut 2
WORKSPACE_SWITCH_SELECTED_SECOND_SNAPSHOT=""
WORKSPACE_SWITCH_SELECTED_SECOND_WORKSPACE_ID=""
for _ in $(seq 1 20); do
  WORKSPACE_SWITCH_SELECTED_SECOND_SNAPSHOT="$(send_request "automation.workspace_snapshot" '{}')"
  WORKSPACE_SWITCH_SELECTED_SECOND_WORKSPACE_ID="$(extract_string_field "$WORKSPACE_SWITCH_SELECTED_SECOND_SNAPSHOT" "workspaceID")"
  if [[ -n "$WORKSPACE_SWITCH_SELECTED_SECOND_WORKSPACE_ID" && "$WORKSPACE_SWITCH_SELECTED_SECOND_WORKSPACE_ID" == "$WORKSPACE_SWITCH_SECOND_WORKSPACE_ID" ]]; then
    break
  fi
  sleep 0.1
done
if [[ -z "$WORKSPACE_SWITCH_SELECTED_SECOND_WORKSPACE_ID" || "$WORKSPACE_SWITCH_SELECTED_SECOND_WORKSPACE_ID" != "$WORKSPACE_SWITCH_SECOND_WORKSPACE_ID" ]]; then
  echo "error: workspace-switch regression did not return to workspace 2 via Option+2" >&2
  echo "expected workspace ID: ${WORKSPACE_SWITCH_SECOND_WORKSPACE_ID}" >&2
  echo "observed workspace ID: ${WORKSPACE_SWITCH_SELECTED_SECOND_WORKSPACE_ID:-<missing>}" >&2
  echo "snapshot response: ${WORKSPACE_SWITCH_SELECTED_SECOND_SNAPSHOT}" >&2
  exit 1
fi

WORKSPACE_SWITCH_SECOND_AFTER_RETURN_SNAPSHOT=""
WORKSPACE_SWITCH_SECOND_AFTER_RETURN_SLOT_COUNT=""
for _ in $(seq 1 20); do
  WORKSPACE_SWITCH_SECOND_AFTER_RETURN_SNAPSHOT="$(send_request "automation.workspace_snapshot" "{\"workspaceID\":\"${WORKSPACE_SWITCH_SECOND_WORKSPACE_ID}\"}")"
  WORKSPACE_SWITCH_SECOND_AFTER_RETURN_SLOT_COUNT_RAW="$(extract_double_field "$WORKSPACE_SWITCH_SECOND_AFTER_RETURN_SNAPSHOT" "slotCount")"
  if [[ -n "$WORKSPACE_SWITCH_SECOND_AFTER_RETURN_SLOT_COUNT_RAW" ]]; then
    WORKSPACE_SWITCH_SECOND_AFTER_RETURN_SLOT_COUNT="${WORKSPACE_SWITCH_SECOND_AFTER_RETURN_SLOT_COUNT_RAW%.*}"
  fi
  if [[ -n "$WORKSPACE_SWITCH_SECOND_AFTER_RETURN_SLOT_COUNT" && "$WORKSPACE_SWITCH_SECOND_AFTER_RETURN_SLOT_COUNT" == "$WORKSPACE_SWITCH_SECOND_SLOT_COUNT" ]]; then
    break
  fi
  sleep 0.1
done
if [[ -z "$WORKSPACE_SWITCH_SECOND_AFTER_RETURN_SLOT_COUNT" || "$WORKSPACE_SWITCH_SECOND_AFTER_RETURN_SLOT_COUNT" != "$WORKSPACE_SWITCH_SECOND_SLOT_COUNT" ]]; then
  echo "error: Cmd+D after Option+2 workspace switch mutated the hidden workspace instead of the visible one" >&2
  echo "workspace 2 baseline slot count: ${WORKSPACE_SWITCH_SECOND_SLOT_COUNT}" >&2
  echo "observed workspace 2 slot count after returning: ${WORKSPACE_SWITCH_SECOND_AFTER_RETURN_SLOT_COUNT:-<missing>}" >&2
  echo "snapshot response: ${WORKSPACE_SWITCH_SECOND_AFTER_RETURN_SNAPSHOT}" >&2
  exit 1
fi

send_request "automation.load_fixture" "{\"name\":\"${FIXTURE}\"}" >/dev/null
PANEL_FOCUS_BASELINE_SNAPSHOT=""
PANEL_FOCUS_BASELINE_FIRST_PANEL_ID=""
PANEL_FOCUS_BASELINE_SECOND_PANEL_ID=""
for _ in $(seq 1 20); do
  PANEL_FOCUS_BASELINE_SNAPSHOT="$(send_request "automation.workspace_snapshot" '{}')"
  PANEL_FOCUS_BASELINE_FIRST_PANEL_ID="$(extract_string_field "$PANEL_FOCUS_BASELINE_SNAPSHOT" "focusedPanelID")"
  if [[ -n "$PANEL_FOCUS_BASELINE_FIRST_PANEL_ID" ]]; then
    break
  fi
  sleep 0.1
done
if [[ -z "$PANEL_FOCUS_BASELINE_FIRST_PANEL_ID" ]]; then
  echo "error: missing baseline focused panel for panel-focus regression" >&2
  echo "workspace snapshot response: ${PANEL_FOCUS_BASELINE_SNAPSHOT}" >&2
  exit 1
fi

send_request "automation.perform_action" '{"action":"workspace.focus-slot.next"}' >/dev/null
for _ in $(seq 1 20); do
  PANEL_FOCUS_BASELINE_SNAPSHOT="$(send_request "automation.workspace_snapshot" '{}')"
  PANEL_FOCUS_BASELINE_SECOND_PANEL_ID="$(extract_string_field "$PANEL_FOCUS_BASELINE_SNAPSHOT" "focusedPanelID")"
  if [[ -n "$PANEL_FOCUS_BASELINE_FIRST_PANEL_ID" && -n "$PANEL_FOCUS_BASELINE_SECOND_PANEL_ID" ]]; then
    break
  fi
  sleep 0.1
done
if [[ -z "$PANEL_FOCUS_BASELINE_FIRST_PANEL_ID" || -z "$PANEL_FOCUS_BASELINE_SECOND_PANEL_ID" ]]; then
  echo "error: missing panel IDs for panel-focus regression" >&2
  echo "workspace snapshot response: ${PANEL_FOCUS_BASELINE_SNAPSHOT}" >&2
  exit 1
fi

send_request "automation.perform_action" '{"action":"workspace.focus-slot.previous"}' >/dev/null

focus_app_terminal
send_panel_focus_shortcut 2
PANEL_FOCUS_SECOND_SNAPSHOT=""
PANEL_FOCUS_SECOND_PANEL_ID=""
for _ in $(seq 1 20); do
  PANEL_FOCUS_SECOND_SNAPSHOT="$(send_request "automation.workspace_snapshot" '{}')"
  PANEL_FOCUS_SECOND_PANEL_ID="$(extract_string_field "$PANEL_FOCUS_SECOND_SNAPSHOT" "focusedPanelID")"
  if [[ -n "$PANEL_FOCUS_SECOND_PANEL_ID" && "$PANEL_FOCUS_SECOND_PANEL_ID" == "$PANEL_FOCUS_BASELINE_SECOND_PANEL_ID" ]]; then
    break
  fi
  sleep 0.1
done
if [[ -z "$PANEL_FOCUS_SECOND_PANEL_ID" || "$PANEL_FOCUS_SECOND_PANEL_ID" != "$PANEL_FOCUS_BASELINE_SECOND_PANEL_ID" ]]; then
  echo "error: panel-focus regression did not focus panel 2 via Option+Shift+2" >&2
  echo "expected panel ID: ${PANEL_FOCUS_BASELINE_SECOND_PANEL_ID}" >&2
  echo "observed panel ID: ${PANEL_FOCUS_SECOND_PANEL_ID:-<missing>}" >&2
  echo "snapshot response: ${PANEL_FOCUS_SECOND_SNAPSHOT}" >&2
  exit 1
fi

send_panel_focus_shortcut 1
PANEL_FOCUS_FIRST_SNAPSHOT=""
PANEL_FOCUS_FIRST_PANEL_ID=""
for _ in $(seq 1 20); do
  PANEL_FOCUS_FIRST_SNAPSHOT="$(send_request "automation.workspace_snapshot" '{}')"
  PANEL_FOCUS_FIRST_PANEL_ID="$(extract_string_field "$PANEL_FOCUS_FIRST_SNAPSHOT" "focusedPanelID")"
  if [[ -n "$PANEL_FOCUS_FIRST_PANEL_ID" && "$PANEL_FOCUS_FIRST_PANEL_ID" == "$PANEL_FOCUS_BASELINE_FIRST_PANEL_ID" ]]; then
    break
  fi
  sleep 0.1
done
if [[ -z "$PANEL_FOCUS_FIRST_PANEL_ID" || "$PANEL_FOCUS_FIRST_PANEL_ID" != "$PANEL_FOCUS_BASELINE_FIRST_PANEL_ID" ]]; then
  echo "error: panel-focus regression did not return to panel 1 via Option+Shift+1" >&2
  echo "expected panel ID: ${PANEL_FOCUS_BASELINE_FIRST_PANEL_ID}" >&2
  echo "observed panel ID: ${PANEL_FOCUS_FIRST_PANEL_ID:-<missing>}" >&2
  echo "snapshot response: ${PANEL_FOCUS_FIRST_SNAPSHOT}" >&2
  exit 1
fi

send_request "automation.load_fixture" "{\"name\":\"${FIXTURE}\"}" >/dev/null

ACTION_CLOSE_SIGNATURE="$(capture_close_outcome action)"
MENU_CLOSE_SIGNATURE="$(capture_close_outcome menu)"
SHORTCUT_CLOSE_SIGNATURE="$(capture_close_outcome shortcut)"
ACTION_CLOSE_STRUCTURE="$(strip_focus_from_layout_signature "$ACTION_CLOSE_SIGNATURE")"
MENU_CLOSE_STRUCTURE="$(strip_focus_from_layout_signature "$MENU_CLOSE_SIGNATURE")"
SHORTCUT_CLOSE_STRUCTURE="$(strip_focus_from_layout_signature "$SHORTCUT_CLOSE_SIGNATURE")"

if [[ "$ACTION_CLOSE_STRUCTURE" != "$MENU_CLOSE_STRUCTURE" || "$ACTION_CLOSE_STRUCTURE" != "$SHORTCUT_CLOSE_STRUCTURE" ]]; then
  echo "error: close paths diverged structurally between action, menu, and Cmd+W" >&2
  echo "action close structure: ${ACTION_CLOSE_STRUCTURE}" >&2
  echo "menu close structure: ${MENU_CLOSE_STRUCTURE}" >&2
  echo "shortcut close structure: ${SHORTCUT_CLOSE_STRUCTURE}" >&2
  echo "action close layout signature: ${ACTION_CLOSE_SIGNATURE}" >&2
  echo "menu close layout signature: ${MENU_CLOSE_SIGNATURE}" >&2
  echo "shortcut close layout signature: ${SHORTCUT_CLOSE_SIGNATURE}" >&2
  exit 1
fi

if [[ ! -f "$TRACE_LOG_PATH" ]]; then
  echo "error: trace log file was not created: $TRACE_LOG_PATH" >&2
  exit 1
fi

SPLIT_RIGHT_LOG_COUNT="$(count_intent_logs "split.right")"
SPLIT_DOWN_LOG_COUNT="$(count_intent_logs "split.down")"
FOCUS_NEXT_LOG_COUNT="$(count_intent_logs "focus.next")"
FOCUS_PREVIOUS_LOG_COUNT="$(count_intent_logs "focus.previous")"
RESIZE_LOG_COUNT="$(count_intent_logs "resize_split.right")"
EQUALIZE_LOG_COUNT="$(count_intent_logs "equalize_splits")"
INPUT_SPLIT_COUNT="$(count_input_key_logs "$SPLIT_KEY_CODE")"
INPUT_FOCUS_NEXT_COUNT="$(count_input_key_logs "$FOCUS_NEXT_KEY_CODE")"
INPUT_FOCUS_PREVIOUS_COUNT="$(count_input_key_logs "$FOCUS_PREVIOUS_KEY_CODE")"
INPUT_RIGHT_COUNT="$(count_input_key_logs "$RESIZE_KEY_CODE")"
INPUT_EQUAL_COUNT="$(count_input_key_logs "$EQUALIZE_KEY_CODE")"

if [[ "$SPLIT_RIGHT_LOG_COUNT" == "0" || "$SPLIT_DOWN_LOG_COUNT" == "0" || "$FOCUS_NEXT_LOG_COUNT" == "0" || "$FOCUS_PREVIOUS_LOG_COUNT" == "0" || "$RESIZE_LOG_COUNT" == "0" || "$EQUALIZE_LOG_COUNT" == "0" ]]; then
  echo "error: missing expected Ghostty intent logs in $TRACE_LOG_PATH" >&2
  echo "split.right intent count: $SPLIT_RIGHT_LOG_COUNT" >&2
  echo "split.down intent count: $SPLIT_DOWN_LOG_COUNT" >&2
  echo "focus.next intent count: $FOCUS_NEXT_LOG_COUNT" >&2
  echo "focus.previous intent count: $FOCUS_PREVIOUS_LOG_COUNT" >&2
  echo "resize intent count: $RESIZE_LOG_COUNT" >&2
  echo "equalize intent count: $EQUALIZE_LOG_COUNT" >&2
  exit 1
fi

if [[ "$INPUT_SPLIT_COUNT" == "0" || "$INPUT_FOCUS_NEXT_COUNT" == "0" || "$INPUT_FOCUS_PREVIOUS_COUNT" == "0" || "$INPUT_RIGHT_COUNT" == "0" || "$INPUT_EQUAL_COUNT" == "0" ]]; then
  echo "error: missing expected key event logs in $TRACE_LOG_PATH" >&2
  echo "split key event count: $INPUT_SPLIT_COUNT (key code $SPLIT_KEY_CODE)" >&2
  echo "focus-next key event count: $INPUT_FOCUS_NEXT_COUNT (key code $FOCUS_NEXT_KEY_CODE)" >&2
  echo "focus-previous key event count: $INPUT_FOCUS_PREVIOUS_COUNT (key code $FOCUS_PREVIOUS_KEY_CODE)" >&2
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
echo "split baseline slot count: $SPLIT_BASELINE_SLOT_COUNT"
echo "after split-right slot count: $SPLIT_RIGHT_SLOT_COUNT"
echo "after split-down slot count: $SPLIT_DOWN_SLOT_COUNT"
echo "focus baseline panel: $SPLIT_BASELINE_FOCUS_ID"
echo "focus after split-right: $SPLIT_RIGHT_FOCUS_ID"
echo "focus after focus-next: $FOCUS_NEXT_PANEL_ID"
echo "focus after focus-previous: $FOCUS_PREVIOUS_PANEL_ID"
echo "workspace 1 ID: $WORKSPACE_SWITCH_FIRST_WORKSPACE_ID"
echo "workspace 2 ID: $WORKSPACE_SWITCH_SECOND_WORKSPACE_ID"
echo "workspace 1 baseline slot count: $WORKSPACE_SWITCH_FIRST_SLOT_COUNT"
echo "workspace 2 baseline slot count: $WORKSPACE_SWITCH_SECOND_SLOT_COUNT"
echo "workspace 1 slot count after Option+1 then Cmd+D: $WORKSPACE_SWITCH_FIRST_AFTER_SPLIT_SLOT_COUNT"
echo "workspace 2 slot count after returning with Option+2: $WORKSPACE_SWITCH_SECOND_AFTER_RETURN_SLOT_COUNT"
echo "panel 1 baseline ID: $PANEL_FOCUS_BASELINE_FIRST_PANEL_ID"
echo "panel 2 baseline ID: $PANEL_FOCUS_BASELINE_SECOND_PANEL_ID"
echo "focused panel after Option+Shift+2: $PANEL_FOCUS_SECOND_PANEL_ID"
echo "focused panel after returning with Option+Shift+1: $PANEL_FOCUS_FIRST_PANEL_ID"
echo "action close structure: $ACTION_CLOSE_STRUCTURE"
echo "menu close structure: $MENU_CLOSE_STRUCTURE"
echo "shortcut close structure: $SHORTCUT_CLOSE_STRUCTURE"
echo "action close layout signature: $ACTION_CLOSE_SIGNATURE"
echo "menu close layout signature: $MENU_CLOSE_SIGNATURE"
echo "shortcut close layout signature: $SHORTCUT_CLOSE_SIGNATURE"
echo "split.right intent logs: $SPLIT_RIGHT_LOG_COUNT"
echo "split.down intent logs: $SPLIT_DOWN_LOG_COUNT"
echo "focus.next intent logs: $FOCUS_NEXT_LOG_COUNT"
echo "focus.previous intent logs: $FOCUS_PREVIOUS_LOG_COUNT"
echo "resize intent logs: $RESIZE_LOG_COUNT"
echo "equalize intent logs: $EQUALIZE_LOG_COUNT"
echo "split input logs: $INPUT_SPLIT_COUNT"
echo "focus-next input logs: $INPUT_FOCUS_NEXT_COUNT"
echo "focus-previous input logs: $INPUT_FOCUS_PREVIOUS_COUNT"
echo "right-arrow input logs: $INPUT_RIGHT_COUNT"
echo "equal input logs: $INPUT_EQUAL_COUNT"
echo "shortcut screenshot: ${SHORTCUT_SCREENSHOT_PATH:-unknown}"
echo "trace log: $TRACE_LOG_PATH"
echo "app log: $APP_LOG_FILE"
