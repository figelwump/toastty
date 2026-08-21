#!/usr/bin/env bash
set -euo pipefail

REMOTE_EXEC=0
if [[ "${1:-}" == "--remote-exec" ]]; then
  REMOTE_EXEC=1
  ROOT_DIR=""
  SCRIPT_PATH=""
else
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
  SCRIPT_PATH="$ROOT_DIR/scripts/remote/cleanup-simulator-app.sh"
fi

MODE="dry-run"
MIN_PROCESS_AGE_SECONDS=900
REMOTE_HOST="${TOASTTY_REMOTE_GUI_HOST:-}"
REMOTE_REPO_ROOT="${TOASTTY_REMOTE_GUI_REPO_ROOT:-}"
REMOTE_GUI_ROOT="${TOASTTY_REMOTE_GUI_ROOT:-}"
LOCK_DIR=""
QUIT_HELPER_PID=""

ELIGIBLE=0
TERMINATED=0
RETAINED=0
MANUAL_REVIEW=0
TERMINATE_FAILURES=0
BOOTED_DEVICES=0
ACTIVE_IOS_RUNS=0
AMBIGUOUS_LIVE_RUNS=0
AMBIGUOUS_SIMULATOR_PROCESSES=0
RECENT_SIMULATOR_PROCESSES=0
SAFETY_REASON=""
SIMULATOR_PIDS=()

usage() {
  cat <<'EOF'
Usage: ./scripts/remote/cleanup-simulator-app.sh --dry-run|--apply

Safely closes stale Simulator.app window shells on the configured Toastty
remote validation Mac. Apply mode terminates only exact Simulator.app
processes that are at least 15 minutes old, and only when no Simulator device
is booted and no live iOS remote test owner or path-scoped process is present.
It never shuts down or deletes a Simulator device. The default is a dry run.

Run this script through `sv exec --` so the manifest-scoped remote host and
path configuration are available.

Options:
  --dry-run   Report whether Simulator.app can be terminated safely.
  --apply     Revalidate safety conditions and terminate Simulator.app.
  -h, --help  Show this help.

Required environment:
  TOASTTY_REMOTE_GUI_HOST       SSH host for the dedicated validation Mac.
  TOASTTY_REMOTE_GUI_REPO_ROOT  Absolute Toastty repository path on that Mac.
  TOASTTY_REMOTE_GUI_ROOT       Absolute remote validation data root.
EOF
}

log() {
  printf '[remote-simulator-app-cleanup] %s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ "$QUIT_HELPER_PID" =~ ^[1-9][0-9]*$ ]] \
    && kill -0 "$QUIT_HELPER_PID" >/dev/null 2>&1; then
    kill -TERM "$QUIT_HELPER_PID" >/dev/null 2>&1 || true
    sleep 1
    kill -KILL "$QUIT_HELPER_PID" >/dev/null 2>&1 || true
    wait "$QUIT_HELPER_PID" >/dev/null 2>&1 || true
  fi
  QUIT_HELPER_PID=""
  if [[ -n "$LOCK_DIR" && -d "$LOCK_DIR" ]]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

encode_base64() {
  printf '%s' "$1" | base64 | tr -d '\n'
}

decode_base64() {
  if base64 --help 2>&1 | grep -q -- '--decode'; then
    printf '%s' "$1" | base64 --decode
  else
    printf '%s' "$1" | base64 -D
  fi
}

validate_remote_identity() {
  local repo_root
  local git_root
  local gui_root

  [[ "$REMOTE_REPO_ROOT" == /* && "$REMOTE_GUI_ROOT" == /* ]] \
    || fail "remote repository and validation roots must be absolute"
  [[ -f "$REMOTE_REPO_ROOT/Project.swift" \
    && -f "$REMOTE_REPO_ROOT/scripts/remote/test.sh" ]] \
    || fail "remote repository markers are missing"
  [[ -d "$REMOTE_GUI_ROOT/test-runs" && -d "$REMOTE_GUI_ROOT/worktrees" ]] \
    || fail "remote validation root is missing test-runs/worktrees"
  [[ ! -L "$REMOTE_GUI_ROOT/test-runs" && ! -L "$REMOTE_GUI_ROOT/worktrees" ]] \
    || fail "remote test-runs/worktrees containers must not be symlinks"

  repo_root="$(cd "$REMOTE_REPO_ROOT" && pwd -P)"
  git_root="$(git -C "$REMOTE_REPO_ROOT" rev-parse --show-toplevel 2>/dev/null)" \
    || fail "remote repository root is not a git worktree"
  git_root="$(cd "$git_root" && pwd -P)"
  [[ "$repo_root" == "$git_root" ]] \
    || fail "remote repository root is not the git top level"
  gui_root="$(cd "$REMOTE_GUI_ROOT" && pwd -P)"
  case "$gui_root" in
    "$repo_root"|"$repo_root"/*) fail "remote validation root must not be inside the repository" ;;
    /|/Users|/Users/*/GiantThings) fail "remote validation root is too broad: $gui_root" ;;
  esac

  REMOTE_REPO_ROOT="$repo_root"
  REMOTE_GUI_ROOT="$gui_root"
}

process_matches_live_owner() {
  local pid="$1"
  local expected_started_at="$2"
  local actual_started_at

  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  actual_started_at="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$pid" 2>/dev/null | awk '{$1=$1; print}' || true)"
  if [[ -n "$actual_started_at" ]]; then
    [[ "$actual_started_at" == "$expected_started_at" ]]
    return
  fi
  kill -0 "$pid" >/dev/null 2>&1
}

path_has_live_process() {
  local target_path="$1"
  local pid
  local command_line

  [[ -n "$target_path" && "$target_path" == /* ]] || return 0
  while read -r pid command_line; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    case "$command_line" in
      *"$target_path"*) return 0 ;;
    esac
  done < <(ps -axww -o pid=,command=)
  return 1
}

evaluate_live_ios_runs() {
  local run_dir
  local manifest
  local run_label
  local worktree
  local owner_pid
  local owner_started_at

  ACTIVE_IOS_RUNS=0
  AMBIGUOUS_LIVE_RUNS=0
  while IFS= read -r -d '' run_dir; do
    manifest="$run_dir/run-ownership.json"
    run_label="$(basename "$run_dir")"
    worktree="$REMOTE_GUI_ROOT/worktrees/$run_label"
    if [[ -d "$run_dir" && ! -L "$run_dir" \
      && -f "$manifest" && ! -L "$manifest" ]] \
      && jq -e \
        --arg runLabel "$run_label" \
        --arg runRoot "$run_dir" \
        --arg worktree "$worktree" '
          .schemaVersion == 1
          and .ownership == "toastty-remote-test"
          and .runLabel == $runLabel
          and .remoteRunRoot == $runRoot
          and .remoteWorktreePath == $worktree
          and .derivedDataPath == ($runRoot + "/Derived")
          and .runtimeHomePath == ($runRoot + "/runtime-home")
          and .platform == "ios"
          and (.owner.pid | type == "number" and floor == . and . > 0)
          and (.owner.startedAt | type == "string" and length > 0)
        ' "$manifest" >/dev/null 2>&1; then
      owner_pid="$(jq -r '.owner.pid' "$manifest")"
      owner_started_at="$(jq -r '.owner.startedAt' "$manifest")"
      if process_matches_live_owner "$owner_pid" "$owner_started_at" \
        || path_has_live_process "$run_dir" \
        || { [[ -d "$worktree" && ! -L "$worktree" ]] \
          && path_has_live_process "$worktree"; }; then
        ACTIVE_IOS_RUNS=$((ACTIVE_IOS_RUNS + 1))
      fi
    elif path_has_live_process "$run_dir"; then
      AMBIGUOUS_LIVE_RUNS=$((AMBIGUOUS_LIVE_RUNS + 1))
    fi
  done < <(find "$REMOTE_GUI_ROOT/test-runs" -mindepth 1 -maxdepth 1 -print0)
}

load_booted_device_count() {
  local devices_json

  devices_json="$(xcrun simctl list devices booted --json)" \
    || fail "simctl failed to list booted devices"
  jq -e '
    .devices | type == "object"
    and all(to_entries[];
      .value | type == "array"
      and all(.[]; .state | type == "string" and length > 0)
    )
  ' <<<"$devices_json" >/dev/null \
    || fail "simctl returned malformed booted-device JSON"
  BOOTED_DEVICES="$(jq '[.devices[][]] | length' <<<"$devices_json")"
}

simulator_executable_for_pid() {
  local pid="$1"
  ps -ww -o comm= -p "$pid" 2>/dev/null | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

is_simulator_app_executable() {
  case "$1" in
    */Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator) return 0 ;;
    *) return 1 ;;
  esac
}

simulator_process_age_seconds() {
  local pid="$1"
  local elapsed

  elapsed="$(ps -ww -o etime= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  [[ "$elapsed" =~ ^([0-9]+-)?([0-9]{1,2}:)?[0-9]{1,2}:[0-9]{2}$ ]] || return 1
  awk -F '[-:]' '
    NF == 2 { print ($1 * 60) + $2; exit }
    NF == 3 { print ($1 * 3600) + ($2 * 60) + $3; exit }
    NF == 4 { print ($1 * 86400) + ($2 * 3600) + ($3 * 60) + $4; exit }
    { exit 1 }
  ' <<<"$elapsed"
}

simulator_process_exists() {
  local pid="$1"
  local observed_pid

  observed_pid="$(ps -ww -o pid= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  [[ "$observed_pid" == "$pid" ]]
}

request_bounded_simulator_quit() {
  local pid="$1"
  local attempt
  local helper_reaped=0

  osascript -e 'tell application id "com.apple.iphonesimulator" to quit' \
    >/dev/null 2>&1 &
  QUIT_HELPER_PID=$!
  for ((attempt = 0; attempt < 50; attempt += 1)); do
    if ! simulator_process_exists "$pid"; then
      if (( helper_reaped == 0 )); then
        if kill -0 "$QUIT_HELPER_PID" >/dev/null 2>&1; then
          kill -TERM "$QUIT_HELPER_PID" >/dev/null 2>&1 || true
        fi
        wait "$QUIT_HELPER_PID" >/dev/null 2>&1 || true
      fi
      QUIT_HELPER_PID=""
      return 0
    fi
    if (( helper_reaped == 0 )) \
      && ! kill -0 "$QUIT_HELPER_PID" >/dev/null 2>&1; then
      wait "$QUIT_HELPER_PID" >/dev/null 2>&1 || true
      helper_reaped=1
      QUIT_HELPER_PID=""
    fi
    sleep 0.1
  done

  if (( helper_reaped == 0 )) \
    && [[ "$QUIT_HELPER_PID" =~ ^[1-9][0-9]*$ ]] \
    && kill -0 "$QUIT_HELPER_PID" >/dev/null 2>&1; then
    kill -TERM "$QUIT_HELPER_PID" >/dev/null 2>&1 || true
    sleep 1
    kill -KILL "$QUIT_HELPER_PID" >/dev/null 2>&1 || true
    wait "$QUIT_HELPER_PID" >/dev/null 2>&1 || true
  fi
  QUIT_HELPER_PID=""
  return 1
}

load_simulator_processes() {
  local pid
  local executable
  local age_seconds

  SIMULATOR_PIDS=()
  AMBIGUOUS_SIMULATOR_PROCESSES=0
  RECENT_SIMULATOR_PROCESSES=0
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || {
      AMBIGUOUS_SIMULATOR_PROCESSES=$((AMBIGUOUS_SIMULATOR_PROCESSES + 1))
      continue
    }
    executable="$(simulator_executable_for_pid "$pid")"
    if is_simulator_app_executable "$executable"; then
      if age_seconds="$(simulator_process_age_seconds "$pid")" \
        && [[ "$age_seconds" =~ ^[0-9]+$ ]]; then
        if (( age_seconds >= MIN_PROCESS_AGE_SECONDS )); then
          SIMULATOR_PIDS+=("$pid")
        else
          RECENT_SIMULATOR_PROCESSES=$((RECENT_SIMULATOR_PROCESSES + 1))
          warn "manual review: retained recent Simulator.app process: pid=$pid age_seconds=$age_seconds"
        fi
      else
        AMBIGUOUS_SIMULATOR_PROCESSES=$((AMBIGUOUS_SIMULATOR_PROCESSES + 1))
        warn "manual review: Simulator.app process age is unavailable: pid=$pid"
      fi
    else
      AMBIGUOUS_SIMULATOR_PROCESSES=$((AMBIGUOUS_SIMULATOR_PROCESSES + 1))
      warn "manual review: process named Simulator has unexpected executable: pid=$pid executable=${executable:-unknown}"
    fi
  done < <(pgrep -x Simulator || true)
}

evaluate_safety() {
  SAFETY_REASON=""
  load_booted_device_count
  evaluate_live_ios_runs
  if (( BOOTED_DEVICES > 0 )); then
    SAFETY_REASON="$BOOTED_DEVICES Simulator device(s) are booted"
    return 1
  fi
  if (( ACTIVE_IOS_RUNS > 0 )); then
    SAFETY_REASON="$ACTIVE_IOS_RUNS live iOS remote test run(s) are present"
    return 1
  fi
  if (( AMBIGUOUS_LIVE_RUNS > 0 )); then
    SAFETY_REASON="$AMBIGUOUS_LIVE_RUNS unowned or malformed remote run path(s) have live processes"
    return 1
  fi
  return 0
}

terminate_simulator_process() {
  local pid="$1"
  local executable
  local attempt

  executable="$(simulator_executable_for_pid "$pid")"
  is_simulator_app_executable "$executable" || return 1
  if request_bounded_simulator_quit "$pid"; then
    return 0
  fi
  executable="$(simulator_executable_for_pid "$pid")"
  is_simulator_app_executable "$executable" || return 0
  if ! kill -TERM "$pid" >/dev/null 2>&1; then
    simulator_process_exists "$pid" && return 1
    return 0
  fi
  for ((attempt = 0; attempt < 100; attempt += 1)); do
    simulator_process_exists "$pid" || return 0
    sleep 0.1
  done
  return 1
}

process_simulator_app() {
  local pid
  local index
  local process_count

  load_simulator_processes
  if (( AMBIGUOUS_SIMULATOR_PROCESSES > 0 || RECENT_SIMULATOR_PROCESSES > 0 )); then
    MANUAL_REVIEW=$((MANUAL_REVIEW + 1))
    RETAINED=$((RETAINED + AMBIGUOUS_SIMULATOR_PROCESSES + RECENT_SIMULATOR_PROCESSES + ${#SIMULATOR_PIDS[@]}))
    if (( ${#SIMULATOR_PIDS[@]} > 0 )); then
      warn "manual review: retained all Simulator processes because process identity or age is ambiguous"
    fi
    return 0
  fi
  if (( ${#SIMULATOR_PIDS[@]} == 0 )); then
    return 0
  fi

  if ! evaluate_safety; then
    RETAINED=$((RETAINED + ${#SIMULATOR_PIDS[@]}))
    MANUAL_REVIEW=$((MANUAL_REVIEW + 1))
    warn "manual review: retained Simulator.app ($SAFETY_REASON)"
    return 0
  fi

  ELIGIBLE=$((ELIGIBLE + ${#SIMULATOR_PIDS[@]}))
  for pid in "${SIMULATOR_PIDS[@]}"; do
    log "eligible pid=$pid executable=$(simulator_executable_for_pid "$pid")"
  done
  [[ "$MODE" == "apply" ]] || return 0

  load_simulator_processes
  if (( AMBIGUOUS_SIMULATOR_PROCESSES > 0 || RECENT_SIMULATOR_PROCESSES > 0 )); then
    MANUAL_REVIEW=$((MANUAL_REVIEW + 1))
    RETAINED=$((RETAINED + AMBIGUOUS_SIMULATOR_PROCESSES + RECENT_SIMULATOR_PROCESSES + ${#SIMULATOR_PIDS[@]}))
    warn "retained after process identity/age recheck: Simulator.app"
    return 0
  fi
  if (( ${#SIMULATOR_PIDS[@]} == 0 )); then
    return 0
  fi
  process_count="${#SIMULATOR_PIDS[@]}"
  for ((index = 0; index < process_count; index += 1)); do
    pid="${SIMULATOR_PIDS[$index]}"
    if ! evaluate_safety; then
      RETAINED=$((RETAINED + process_count - index))
      MANUAL_REVIEW=$((MANUAL_REVIEW + 1))
      warn "retained after safety recheck: Simulator.app ($SAFETY_REASON)"
      break
    fi
    if terminate_simulator_process "$pid"; then
      TERMINATED=$((TERMINATED + 1))
    else
      TERMINATE_FAILURES=$((TERMINATE_FAILURES + 1))
      warn "failed to terminate exact Simulator.app process: pid=$pid"
    fi
  done
}

run_remote_mode() {
  [[ $# -eq 4 ]] || fail "invalid remote cleanup invocation"
  MODE="$1"
  REMOTE_REPO_ROOT="$(decode_base64 "$2")"
  REMOTE_GUI_ROOT="$(decode_base64 "$3")"
  [[ "$4" == "cleanup-simulator-app.sh" ]] || fail "invalid script identity"
  [[ "$MODE" == "dry-run" || "$MODE" == "apply" ]] || fail "invalid mode: $MODE"

  require_command base64
  require_command find
  require_command git
  require_command jq
  require_command osascript
  require_command pgrep
  require_command ps
  require_command xcrun
  validate_remote_identity

  if [[ "$MODE" == "apply" ]]; then
    LOCK_DIR="$REMOTE_GUI_ROOT/.simulator-app-cleanup.lock"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
      LOCK_DIR=""
      fail "remote Simulator.app cleanup is already running or left a stale lock"
    fi
  fi

  process_simulator_app
  log "mode=$MODE eligible=$ELIGIBLE terminated=$TERMINATED retained=$RETAINED booted_devices=$BOOTED_DEVICES active_ios_runs=$ACTIVE_IOS_RUNS ambiguous_live_runs=$AMBIGUOUS_LIVE_RUNS manual_review=$MANUAL_REVIEW terminate_failures=$TERMINATE_FAILURES"
  [[ "$TERMINATE_FAILURES" == "0" ]]
}

run_local_mode() {
  [[ -n "$REMOTE_HOST" ]] \
    || fail "TOASTTY_REMOTE_GUI_HOST is required; run through sv exec --"
  [[ -n "$REMOTE_REPO_ROOT" && -n "$REMOTE_GUI_ROOT" ]] \
    || fail "remote roots are required"
  require_command base64
  require_command ssh
  log "target=$REMOTE_HOST mode=$MODE"
  ssh -T -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_HOST" /bin/bash -s -- \
    --remote-exec \
    "$MODE" \
    "$(encode_base64 "$REMOTE_REPO_ROOT")" \
    "$(encode_base64 "$REMOTE_GUI_ROOT")" \
    cleanup-simulator-app.sh \
    <"$SCRIPT_PATH"
}

main() {
  if [[ "$REMOTE_EXEC" == "1" ]]; then
    shift
    run_remote_mode "$@"
    return
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        [[ "$MODE" != "apply" ]] || fail "--dry-run and --apply cannot be combined"
        MODE="dry-run"
        DRY_RUN_EXPLICIT=1
        ;;
      --apply)
        [[ "$MODE" != "dry-run" || "${DRY_RUN_EXPLICIT:-0}" != "1" ]] \
          || fail "--dry-run and --apply cannot be combined"
        MODE="apply"
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *) fail "unknown argument: $1" ;;
    esac
    shift
  done
  run_local_mode
}

main "$@"
