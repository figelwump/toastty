#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
source "$ROOT_DIR/scripts/remote/run-support.sh"
source "$ROOT_DIR/scripts/automation/runtime-ownership.sh"
SCRIPT_PATH="scripts/remote/computer-use-run.sh"

REMOTE_PREPARE=0
REMOTE_SESSION=0
REMOTE_STOP=0
RUN_LABEL="${RUN_LABEL:-$(toastty_default_run_label computer-use)}"
VALIDATION_SCOPE="working-tree"
REF_SPEC=""
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
QUEUE_TIMEOUT_SECONDS="${TOASTTY_REMOTE_QUEUE_TIMEOUT_SECONDS:-3600}"
KEEP_REMOTE=0
FULL_ARTIFACTS=0
PROMPT_FILE=""
PROMPT_TEXT=""
CODEX_COMPUTER_USE_MODEL="${CODEX_COMPUTER_USE_MODEL:-gpt-6.1-terra}"
CODEX_COMPUTER_USE_REASONING_EFFORT="${CODEX_COMPUTER_USE_REASONING_EFFORT:-high}"
CODEX_COMPUTER_USE_SERVICE_TIER="${CODEX_COMPUTER_USE_SERVICE_TIER:-fast}"
CURRENT_CODEX_APP_CLI="/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
LEGACY_CODEX_APP_CLI="/Applications/Codex.app/Contents/Resources/codex"

DEFAULT_REMOTE_REPO_ROOT="$ROOT_DIR"
REMOTE_HOST="${TOASTTY_REMOTE_GUI_HOST:-}"
REMOTE_REPO_ROOT="${TOASTTY_REMOTE_GUI_REPO_ROOT:-$DEFAULT_REMOTE_REPO_ROOT}"
DEFAULT_REMOTE_GUI_ROOT="$(dirname "$REMOTE_REPO_ROOT")/toastty-remote-gui"
REMOTE_GUI_ROOT="${TOASTTY_REMOTE_GUI_ROOT:-$DEFAULT_REMOTE_GUI_ROOT}"

LOCAL_ARTIFACTS_DIR=""
REMOTE_PREFLIGHT_ERROR=""

REMOTE_RUN_ROOT_ARG=""
REMOTE_WORKTREE_DIR_ARG=""
SOCKET_PATH_ARG=""
APP_PID_ARG=""
APP_SERVER_PID_ARG=""
APP_SERVER_LISTENER_PID_ARG=""
APP_SERVER_LAUNCHD_LABEL_ARG=""

CLEANUP_REMOTE_WORKTREE_CREATED=0
CLEANUP_REMOTE_PREPARED=0
CLEANUP_REMOTE_STOPPED=0
CLEANUP_REMOTE_REMOVED=0
CLEANUP_TUNNEL_PID=""
CLEANUP_SESSION_PID=""
CLEANUP_CLIENT_PID=""
CLEANUP_SESSION_INPUT_OPEN=0
CLEANUP_REMOTE_WORKTREE_DIR=""
CLEANUP_REMOTE_RUN_ROOT=""
CLEANUP_SOCKET_PATH=""
CLEANUP_APP_PID=""
CLEANUP_APP_SERVER_PID=""
CLEANUP_APP_SERVER_LISTENER_PID=""
CLEANUP_APP_SERVER_LAUNCHD_LABEL=""

usage() {
  cat <<'EOF'
Usage:
  ./scripts/remote/computer-use-run.sh [options]

Runs one remote Codex Computer Use turn on the dedicated macOS GUI machine.
The wrapper creates a disposable remote worktree, builds and launches Toastty,
starts Codex app-server on the remote host, drives one prompt over JSON-RPC,
and copies the resulting artifacts back under artifacts/remote-gui/<run-label>/.

Options:
  --prompt <text>                       Prompt text to send to Codex app-server
  --prompt-file <path>                  Read prompt text from a local file
  --scope working-tree|head|ref         Local change scope to validate (default: working-tree)
  --ref <git-ref>                       Git ref to export when --scope ref is used
  --run-label <label>                   Stable run label for local and remote artifacts
  --timeout-seconds <seconds>           Hard timeout for the Codex turn (default: 300)
  --full-artifacts                      Copy build products and caches as well as evidence
  --keep-remote                         Keep the remote worktree and run directory after completion
  --remote-session                      Internal admitted build, turn, and cleanup session
  --remote-prepare                      Internal mode used on the remote host
  --remote-stop                         Internal mode used on the remote host
  -h, --help                            Show this help

Required local environment:
  TOASTTY_REMOTE_GUI_HOST               SSH host for the dedicated remote GUI machine

Optional local environment:
  TOASTTY_REMOTE_GUI_REPO_ROOT          Absolute Toastty repo path on the remote host
  TOASTTY_REMOTE_GUI_ROOT               Remote directory that will hold disposable worktrees and runs
  TOASTTY_REMOTE_QUEUE_TIMEOUT_SECONDS Admission wait limit (default: 3600)
  CODEX_COMPUTER_USE_MODEL              Codex model for app-server turns (default: gpt-6.1-terra)
  CODEX_COMPUTER_USE_REASONING_EFFORT   Codex reasoning effort for app-server turns (default: high)
  CODEX_COMPUTER_USE_SERVICE_TIER       Codex service tier for app-server turns (default: fast)

Default prompt:
  @Computer Use Toastty is already running on this Mac. Use computer use only.
  In Toastty, click Get Started…, then stop and report what you observed. Do not
  run shell commands. Do not edit files. Do not change settings.
EOF
}

log() {
  printf '[computer-use-run] %s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || fail "Missing required command: $command_name"
}

escape_sh() {
  printf "%q" "$1"
}

timestamp_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

run_hash() {
  printf '%s' "$1" | cksum | awk '{print $1}'
}

pick_unused_port() {
  local port=""
  local attempt=0

  while [[ "$attempt" -lt 100 ]]; do
    port=$((20000 + RANDOM % 20000))
    if ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      printf '%s\n' "$port"
      return 0
    fi
    attempt=$((attempt + 1))
  done

  return 1
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

default_prompt() {
  cat <<'EOF'
@Computer Use Toastty is already running on this Mac. Use computer use only. In Toastty, click Get Started…, then stop and report what you observed. Do not run shell commands. Do not edit files. Do not change settings.
EOF
}

export_ref_tree() {
  local ref_name="$1"
  local export_root
  export_root="$(mktemp -d)"
  git -C "$ROOT_DIR" archive "$ref_name" | tar -x -C "$export_root"
  printf '%s\n' "$export_root"
}

sync_worktree_to_remote() {
  local source_root="$1"
  local remote_worktree_dir="$2"

  rsync -a --delete \
    -e 'ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=30 -o ServerAliveCountMax=3' \
    --exclude '.git' \
    --exclude '.DS_Store' \
    --exclude 'artifacts' \
    --exclude 'Derived' \
    --exclude 'Derived*' \
    --exclude 'toastty.xcodeproj' \
    --exclude 'toastty.xcworkspace' \
    --exclude 'Tuist/.build' \
    --exclude 'Dependencies/GhosttyKit.Debug.xcframework' \
    --exclude 'Dependencies/GhosttyKit.Release.xcframework' \
    --exclude 'Dependencies/GhosttyKit.Debug.metadata.env' \
    --exclude 'Dependencies/GhosttyKit.Release.metadata.env' \
    "$source_root/" \
    "$REMOTE_HOST:$remote_worktree_dir/"
}

remote_shell() {
  local script="$1"
  ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 "$REMOTE_HOST" /bin/bash -l -s -- <<EOF
set -euo pipefail
$script
EOF
}

run_remote_preflight() {
  local output
  if ! output="$(
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 "$REMOTE_HOST" /bin/bash -l -s -- \
      "$REMOTE_REPO_ROOT" \
      "$REMOTE_GUI_ROOT" \
      "$CURRENT_CODEX_APP_CLI" \
      "$LEGACY_CODEX_APP_CLI" <<'EOF' 2>&1
set -euo pipefail
remote_repo_root="$1"
remote_gui_root="$2"
git -C "$remote_repo_root" rev-parse --is-inside-work-tree >/dev/null
command -v python3 >/dev/null
test -x "$3" || test -x "$4" || {
  printf 'No app-bundled Codex CLI found at %s or %s\n' "$3" "$4" >&2
  exit 1
}
mkdir -p "$remote_gui_root/worktrees" "$remote_gui_root/runs"
test -w "$remote_gui_root/worktrees"
test -w "$remote_gui_root/runs"
EOF
  )"; then
    REMOTE_PREFLIGHT_ERROR="$output"
    return 1
  fi

  REMOTE_PREFLIGHT_ERROR=""
  return 0
}

prepare_local_artifacts() {
  LOCAL_ARTIFACTS_DIR="$ROOT_DIR/artifacts/remote-gui/$RUN_LABEL"
  toastty_validate_run_label "$RUN_LABEL" || return 1
  toastty_allocate_local_artifacts "$LOCAL_ARTIFACTS_DIR" || return 1
  mkdir -p "$LOCAL_ARTIFACTS_DIR/remote"
}

write_request_env() {
  local path="$1"
  cat >"$path" <<EOF
run_label=$RUN_LABEL
scope=$VALIDATION_SCOPE
ref_spec=$REF_SPEC
timeout_seconds=$TIMEOUT_SECONDS
remote_host=$REMOTE_HOST
remote_repo_root=$REMOTE_REPO_ROOT
remote_gui_root=$REMOTE_GUI_ROOT
prompt_file=$PROMPT_FILE
codex_model=$CODEX_COMPUTER_USE_MODEL
codex_reasoning_effort=$CODEX_COMPUTER_USE_REASONING_EFFORT
codex_service_tier=$CODEX_COMPUTER_USE_SERVICE_TIER
EOF
}

configured_model_json() {
  jq -cn \
    --arg name "$CODEX_COMPUTER_USE_MODEL" \
    --arg reasoningEffort "$CODEX_COMPUTER_USE_REASONING_EFFORT" \
    --arg serviceTier "$CODEX_COMPUTER_USE_SERVICE_TIER" \
    '{
      name: $name,
      provider: null,
      serviceTier: $serviceTier,
      reasoningEffort: $reasoningEffort
    }'
}

write_result_json() {
  local path="$1"
  local status="$2"
  local started_at="$3"
  local ended_at="$4"
  local summary_text="$5"
  local failure_reason_json="$6"
  local tokens_json="$7"
  local thread_id="$8"
  local turn_id="$9"
  local duration_seconds="${10}"
  local app_list_count="${11}"
  local computer_use_ready="${12}"
  local final_text="${13}"
  local remote_run_root="${14}"
  local remote_worktree_dir="${15}"
  local model_json="${16}"

  jq -n \
    --arg status "$status" \
    --arg startedAt "$started_at" \
    --arg endedAt "$ended_at" \
    --arg summary "$summary_text" \
    --arg threadId "$thread_id" \
    --arg turnId "$turn_id" \
    --arg finalText "$final_text" \
    --arg remoteRunRoot "$remote_run_root" \
    --arg remoteWorktreeDir "$remote_worktree_dir" \
    --arg promptPath "prompt.txt" \
    --arg transcriptPath "remote/transcript.jsonl" \
    --arg buildLogPath "remote/build.log" \
    --arg appLogPath "remote/app.log" \
    --arg appServerLogPath "remote/app-server.log" \
    --arg appServerSessionLogPath "remote/app-server-session.log" \
    --arg launchPath "remote/launch.json" \
    --arg clientSummaryPath "client-summary.json" \
    --argjson model "$model_json" \
    --argjson durationSeconds "$duration_seconds" \
    --argjson timeoutSeconds "$TIMEOUT_SECONDS" \
    --argjson retryCount 0 \
    --argjson appListCount "$app_list_count" \
    --argjson computerUseReady "$computer_use_ready" \
    --argjson failureReason "$failure_reason_json" \
    --argjson tokensUsed "$tokens_json" \
    '{
      schemaVersion: 1,
      status: $status,
      mode: "computer_use",
      executionPath: "codex_app_server",
      startedAt: $startedAt,
      endedAt: $endedAt,
      durationSeconds: $durationSeconds,
      timeoutSeconds: $timeoutSeconds,
      retryCount: $retryCount,
      model: $model,
      tokensUsed: $tokensUsed,
      costUSD: null,
      summary: $summary,
      failureReason: $failureReason,
      threadId: (if $threadId == "" then null else $threadId end),
      turnId: (if $turnId == "" then null else $turnId end),
      appListCount: $appListCount,
      computerUseReady: $computerUseReady,
      finalText: (if $finalText == "" then null else $finalText end),
      remoteRunRoot: $remoteRunRoot,
      remoteWorktreeDir: $remoteWorktreeDir,
      artifacts: {
        prompt: $promptPath,
        transcript: $transcriptPath,
        buildLog: $buildLogPath,
        appLog: $appLogPath,
        appServerLog: $appServerLogPath,
        appServerSessionLog: $appServerSessionLogPath,
        launch: $launchPath,
        clientSummary: $clientSummaryPath
      }
    }' >"$path"
}

copy_prompt_to_artifacts() {
  local output_path="$LOCAL_ARTIFACTS_DIR/prompt.txt"

  if [[ -n "$PROMPT_FILE" ]]; then
    cp "$PROMPT_FILE" "$output_path"
  elif [[ -n "$PROMPT_TEXT" ]]; then
    printf '%s\n' "$PROMPT_TEXT" >"$output_path"
  else
    default_prompt >"$output_path"
  fi

  PROMPT_FILE="$output_path"
}

copy_remote_artifacts_back() {
  mkdir -p "$LOCAL_ARTIFACTS_DIR/remote"
  toastty_copy_run_artifacts "$REMOTE_HOST:$1" "$LOCAL_ARTIFACTS_DIR/remote" "$FULL_ARTIFACTS"
}

pid_is_descendant_of() {
  local candidate="$1"
  local ancestor="$2"
  [[ "$candidate" =~ ^[0-9]+$ && "$ancestor" =~ ^[0-9]+$ ]] || return 1
  local depth=0
  while (( candidate > 1 && depth < 256 )); do
    [[ "$candidate" == "$ancestor" ]] && return 0
    candidate="$(ps -p "$candidate" -o ppid= 2>/dev/null | tr -d '[:space:]')" || return 1
    [[ "$candidate" =~ ^[0-9]+$ ]] || return 1
    depth=$((depth + 1))
  done
  return 1
}

run_remote_prepare_mode() {
  require_command xcodebuild
  require_command jq
  require_command curl
  require_command lsof
  require_command script

  local remote_run_root="$REMOTE_RUN_ROOT_ARG"
  local remote_worktree_dir="$REMOTE_WORKTREE_DIR_ARG"
  [[ -n "$remote_run_root" ]] || fail "--remote-run-root is required for --remote-prepare"
  [[ -n "$remote_worktree_dir" ]] || fail "--remote-worktree-dir is required for --remote-prepare"

  local run_hash_value
  run_hash_value="$(run_hash "$RUN_LABEL")"
  local derived_path="$remote_run_root/Derived"
  local runtime_home="$remote_run_root/runtime-home"
  local runtime_label
  runtime_label="$(toastty_sanitize_runtime_label "$RUN_LABEL")"
  local socket_path="${TMPDIR:-/tmp}/tt-cu-${run_hash_value}.sock"
  local build_log="$remote_run_root/build.log"
  local app_log="$remote_run_root/app.log"
  local bootstrap_log="$remote_run_root/bootstrap.log"
  local app_server_log="$remote_run_root/app-server.log"
  local app_server_session_log="$remote_run_root/app-server-session.log"
  local launch_json="$remote_run_root/launch.json"
  local arch="${ARCH:-arm64}"
  local app_bundle="$derived_path/Build/Products/Debug/Toastty.app"
  local app_binary="$app_bundle/Contents/MacOS/Toastty"
  local instance_json="$runtime_home/instance.json"
  local codex_cli="$CURRENT_CODEX_APP_CLI"
  if [[ ! -x "$codex_cli" ]]; then
    codex_cli="$LEGACY_CODEX_APP_CLI"
  fi
  [[ -x "$codex_cli" ]] || fail "No app-bundled Codex CLI found in ChatGPT.app or Codex.app"
  local codex_version=""
  local app_server_launchd_label="com.giantthings.toastty.cu-appserver.${run_hash_value}"
  local app_server_plist="$remote_run_root/app-server.plist"
  local app_server_launcher="$remote_run_root/app-server-launch.sh"
  local gui_domain="gui/$(id -u)"
  local app_pid=""
  local app_server_pid=""
  local app_server_listener_pid=""
  local app_server_port=""
  local release_marker="$remote_run_root/desktop-active"
  local app_server_started=0
  local app_server_ownership_uncertain=0
  local control_reader_pid=""
  local session_ready="$remote_run_root/session-ready"
  local session_control="$remote_run_root/session-control.txt"
  local control_reader_ready="$remote_run_root/control-reader-ready"
  local supervisor_pid="${TOASTTY_ADMISSION_SUPERVISOR_PID:-}"

  resolve_app_server_listener() {
    [[ -n "$app_server_pid" ]] || app_server_pid="$(launchctl print "$gui_domain/$app_server_launchd_label" 2>/dev/null | grep -m 1 'pid =' | grep -Eo '[0-9]+' || true)"
    [[ "$app_server_pid" =~ ^[0-9]+$ ]] || return 1
    local candidate
    candidate="$(lsof -tiTCP:"$app_server_port" -sTCP:LISTEN | sort -u || true)"
    # A bound port does not establish ownership. The listener must belong to
    # this run's LaunchAgent before it can be recorded or stopped.
    if pid_is_descendant_of "$candidate" "$app_server_pid"; then
      app_server_listener_pid="$candidate"
      return 0
    fi
    return 1
  }

  cleanup_remote_prepare() {
    local cleanup_exit_code=$?
    if [[ -n "$control_reader_pid" ]]; then
      kill "$control_reader_pid" >/dev/null 2>&1 || true
      wait "$control_reader_pid" >/dev/null 2>&1 || true
    fi
    if [[ "$app_server_started" == "1" && -z "$app_server_listener_pid" ]]; then
      if ! resolve_app_server_listener; then
        app_server_ownership_uncertain=1
      fi
    fi
    SOCKET_PATH_ARG="$socket_path"
    APP_PID_ARG="$app_pid"
    APP_SERVER_PID_ARG="$app_server_pid"
    APP_SERVER_LISTENER_PID_ARG="$app_server_listener_pid"
    APP_SERVER_LAUNCHD_LABEL_ARG="$app_server_launchd_label"
    # A signal can land between spawning the app and recording $!; retain the
    # reservation if that tiny window leaves ownership unconfirmed.
    if run_remote_stop_mode && [[ "$app_server_ownership_uncertain" == "0" && ( ! -f "$release_marker" || -n "$app_pid" ) ]]; then
      rm -f "$release_marker"
    else
      warn "Owned GUI processes did not stop; desktop admission remains reserved: $release_marker"
      cleanup_exit_code=1
    fi
    return "$cleanup_exit_code"
  }
  trap cleanup_remote_prepare EXIT
  trap 'exit 143' TERM HUP
  trap 'exit 130' INT

  mkdir -p "$remote_run_root" "$runtime_home" "$(dirname "$socket_path")"
  rm -f "$socket_path"
  rm -f "$launch_json"

  if [[ "$REMOTE_SESSION" == "1" ]]; then
    [[ "$supervisor_pid" =~ ^[0-9]+$ && "$supervisor_pid" == "$PPID" ]] \
      || fail "--remote-session requires its admission supervisor"
    rm -f "$session_ready" "$session_control" "$control_reader_ready"
    trap 'exit 0' USR1
    # One reader owns the control stream from before preparation through the
    # turn. Builds cannot consume it, and an SSH EOF cancels a long build too.
    exec 8<&0
    python3 - "$supervisor_pid" "$$" "$control_reader_ready" "$session_control" "$session_ready" "$((3600 + TIMEOUT_SECONDS + 120))" <<'PYCONTROL' &
import os
from pathlib import Path
import select
import signal
import sys
import time

supervisor, session = map(int, sys.argv[1:3])
reader_ready, control, session_ready = map(Path, sys.argv[3:6])
deadline = time.monotonic() + int(sys.argv[6])

def finish(command):
    control.write_text(command + "\n")
    if command == "STOP" and session_ready.exists():
        os.kill(session, signal.SIGUSR1)
    else:
        # Admission owns the group and escalates if a build ignores TERM.
        os.kill(supervisor, signal.SIGTERM)

def watch():
    initial = True
    pending = b""
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            finish("TIMEOUT")
            return
        readable, _, _ = select.select([8], [], [], min(1, remaining) if initial else remaining)
        if not readable:
            if initial and not pending:
                # Already-buffered STOP/EOF must cancel before preparation.
                reader_ready.touch()
                initial = False
                continue
            finish("INVALID_CONTROL" if initial else "TIMEOUT")
            return
        chunk = os.read(8, 4096)
        if not chunk:
            finish("DISCONNECTED")
            return
        pending += chunk
        if b"\n" in pending:
            finish("STOP" if pending.partition(b"\n")[0] == b"STOP" else "INVALID_CONTROL")
            return
        if len(pending) >= 4096:
            finish("INVALID_CONTROL")
            return

try:
    watch()
except (OSError, ValueError):
    # A broken watcher must not leave preparation running unobserved.
    os.kill(supervisor, signal.SIGTERM)
    raise
PYCONTROL
    control_reader_pid=$!
    exec 8<&-
    local control_ready_deadline=$((SECONDS + 10))
    while [[ ! -f "$control_reader_ready" ]]; do
      [[ ! -f "$session_control" ]] || fail "Computer Use was cancelled before preparation"
      kill -0 "$control_reader_pid" >/dev/null 2>&1 || fail "Computer Use control reader exited before preparation"
      (( SECONDS < control_ready_deadline )) || fail "Computer Use control reader did not start"
      sleep 0.1
    done
  fi

  codex_version="$("$codex_cli" --version </dev/null)" || fail "Codex CLI at $codex_cli failed --version"
  if [[ "$codex_cli" == "$LEGACY_CODEX_APP_CLI" ]]; then
    warn "Using the legacy Codex app; its CLI may require overrides for CODEX_COMPUTER_USE_MODEL and CODEX_COMPUTER_USE_SERVICE_TIER"
  fi
  log "Using $codex_cli ($codex_version)" >&2

  (
    cd "$remote_worktree_dir"
    TUIST_TOASTTY_DISABLE_PUSH=1 ./scripts/dev/bootstrap-worktree.sh
  ) </dev/null >"$bootstrap_log" 2>&1

  (
    cd "$remote_worktree_dir"
    xcodebuild -jobs 4 \
      -workspace toastty.xcworkspace \
      -scheme ToasttyApp \
      -configuration Debug \
      -destination "platform=macOS,arch=${arch}" \
      -derivedDataPath "$derived_path" \
      build
  ) </dev/null >"$build_log" 2>&1

  local app_bundle_id
  app_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_bundle/Contents/Info.plist")" \
    || fail "Failed to read the built Toastty app's bundle identifier"
  [[ -n "$app_bundle_id" ]] || fail "Built Toastty app has no bundle identifier"

  # A new runtime home is a first launch, at which Toastty asks whether to
  # start the coordinator, in a sheet over the window. The session is about
  # something else, so it starts with the question answered.
  # Admission must stay blocked after an interrupted supervisor until cleanup is confirmed.
  [[ ! -f "$session_control" ]] || fail "Computer Use was cancelled during preparation"
  : >"$release_marker"
  TOASTTY_RUNTIME_HOME="$runtime_home" \
  TOASTTY_USER_SKILLS_ROOT="$runtime_home/skills" \
  TOASTTY_RUNTIME_LABEL="$runtime_label" \
  TOASTTY_SOCKET_PATH="$socket_path" \
  TOASTTY_DERIVED_PATH="$derived_path" \
  "$app_binary" -toastty.coordinator.startOfferAnswered YES </dev/null >"$app_log" 2>&1 &
  app_pid=$!

  for _ in $(seq 1 300); do
    if [[ -f "$instance_json" ]]; then
      break
    fi
    if ! kill -0 "$app_pid" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done

  [[ -f "$instance_json" ]] || fail "Toastty did not write instance.json at $instance_json"
  kill -0 "$app_pid" >/dev/null 2>&1 || fail "Toastty exited before the remote Computer Use turn started"
  toastty_assert_run_owned_instance "$instance_json" "$RUN_LABEL" "$runtime_home" "$socket_path" 0

  local recorded_pid
  recorded_pid="$(grep -Eo '"pid"[[:space:]]*:[[:space:]]*[0-9]+' "$instance_json" | grep -Eo '[0-9]+' | head -n 1 || true)"
  if [[ -n "$recorded_pid" ]]; then
    app_pid="$recorded_pid"
  fi

  app_server_port="$(pick_unused_port)" || fail "Failed to allocate a free port for codex app-server"

  # Run the app-server inside the Aqua (GUI) login session via a per-run
  # LaunchAgent. Launched from the SSH background session instead, the
  # Computer Use helper cannot resolve console-session apps or their windows
  # (procNotFound/cgWindowNotFound), and TCC consent prompts are auto-denied
  # because that session has no UI. The launcher keeps the bundled CLI's
  # directory on PATH because the helper spawns nested `codex` via `env`.
  cat >"$app_server_launcher" <<EOF
#!/bin/bash
export PATH="$(dirname "$codex_cli"):\$PATH"
exec script -q "$app_server_session_log" "$codex_cli" app-server \
  -c "model=\"${CODEX_COMPUTER_USE_MODEL}\"" \
  -c "model_reasoning_effort=\"${CODEX_COMPUTER_USE_REASONING_EFFORT}\"" \
  -c "service_tier=\"${CODEX_COMPUTER_USE_SERVICE_TIER}\"" \
  --listen "ws://127.0.0.1:${app_server_port}"
EOF
  chmod +x "$app_server_launcher"

  cat >"$app_server_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${app_server_launchd_label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${app_server_launcher}</string>
  </array>
  <key>WorkingDirectory</key><string>${remote_worktree_dir}</string>
  <key>StandardOutPath</key><string>${app_server_log}</string>
  <key>StandardErrorPath</key><string>${app_server_log}</string>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF

  launchctl bootout "$gui_domain/$app_server_launchd_label" >/dev/null 2>&1 || true
  app_server_started=1
  launchctl bootstrap "$gui_domain" "$app_server_plist" \
    || fail "Failed to bootstrap codex app-server into $gui_domain"

  for _ in $(seq 1 150); do
    if curl -fsS "http://127.0.0.1:${app_server_port}/readyz" >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
  done

  curl -fsS "http://127.0.0.1:${app_server_port}/readyz" >/dev/null 2>&1 || fail "codex app-server did not become ready"
  if ! resolve_app_server_listener; then
    app_server_ownership_uncertain=1
    fail "The app-server listener does not belong to this run's LaunchAgent"
  fi

  cat >"$launch_json" <<EOF
{
  "schemaVersion": 1,
  "executionPath": "codex_app_server",
  "runLabel": "$(json_escape "$RUN_LABEL")",
  "remoteRunRoot": "$(json_escape "$remote_run_root")",
  "remoteWorktreeDir": "$(json_escape "$remote_worktree_dir")",
  "derivedPath": "$(json_escape "$derived_path")",
  "runtimeHome": "$(json_escape "$runtime_home")",
  "runtimeLabel": "$(json_escape "$runtime_label")",
  "socketPath": "$(json_escape "$socket_path")",
  "instanceJson": "$(json_escape "$instance_json")",
  "appBundle": "$(json_escape "$app_bundle")",
  "appBundleID": "$(json_escape "$app_bundle_id")",
  "appBinary": "$(json_escape "$app_binary")",
  "appPid": ${app_pid},
  "codexModel": "$(json_escape "$CODEX_COMPUTER_USE_MODEL")",
  "codexReasoningEffort": "$(json_escape "$CODEX_COMPUTER_USE_REASONING_EFFORT")",
  "codexServiceTier": "$(json_escape "$CODEX_COMPUTER_USE_SERVICE_TIER")",
  "codexCLI": "$(json_escape "$codex_cli")",
  "codexVersion": "$(json_escape "$codex_version")",
  "appServerPort": ${app_server_port},
  "appServerPid": ${app_server_pid},
  "appServerListenerPid": $(if [[ -n "$app_server_listener_pid" ]]; then printf '%s' "$app_server_listener_pid"; else printf 'null'; fi),
  "appServerLaunchdLabel": "$(json_escape "$app_server_launchd_label")"
}
EOF

  if [[ "$REMOTE_SESSION" == "1" ]]; then
    [[ ! -f "$session_control" ]] || fail "Computer Use was cancelled during startup"
    : >"$session_ready"
    printf 'TOASTTY_COMPUTER_USE_READY\n'
    # The reader sends USR1 for a normal STOP, or cancels the supervisor for
    # EOF/invalid input. Waiting here remains interruptible by those signals.
    wait "$control_reader_pid"
    fail "Computer Use control reader exited without stopping the session"
  fi
  trap - EXIT TERM HUP INT USR1
}

run_remote_stop_mode() {
  [[ -n "$SOCKET_PATH_ARG" ]] || fail "--socket-path is required for --remote-stop"
  local stop_failed=0

  wait_for_pid_exit() {
    local pid="$1"
    for _ in $(seq 1 50); do
      if ! kill -0 "$pid" >/dev/null 2>&1; then
        return 0
      fi
      sleep 0.1
    done
    return 1
  }

  local listener_pid="$APP_SERVER_LISTENER_PID_ARG"
  if [[ -n "$listener_pid" ]] && kill -0 "$listener_pid" >/dev/null 2>&1; then
    if ! pid_is_descendant_of "$listener_pid" "$APP_SERVER_PID_ARG"; then
      warn "Refusing to stop a listener outside the owned LaunchAgent process tree"
      listener_pid=""
      stop_failed=1
    fi
  fi

  rm -f "$SOCKET_PATH_ARG"

  if [[ -n "$APP_SERVER_LAUNCHD_LABEL_ARG" ]]; then
    launchctl bootout "gui/$(id -u)/$APP_SERVER_LAUNCHD_LABEL_ARG" >/dev/null 2>&1 || true
    if launchctl print "gui/$(id -u)/$APP_SERVER_LAUNCHD_LABEL_ARG" >/dev/null 2>&1; then
      stop_failed=1
    fi
  fi

  if [[ -n "$listener_pid" ]]; then
    kill "$listener_pid" >/dev/null 2>&1 || true
    wait_for_pid_exit "$listener_pid" || stop_failed=1
  fi

  if [[ -n "$APP_SERVER_PID_ARG" ]]; then
    kill "$APP_SERVER_PID_ARG" >/dev/null 2>&1 || true
    wait_for_pid_exit "$APP_SERVER_PID_ARG" || stop_failed=1
  fi

  if [[ -n "$APP_PID_ARG" ]]; then
    kill "$APP_PID_ARG" >/dev/null 2>&1 || true
    wait_for_pid_exit "$APP_PID_ARG" || stop_failed=1
  fi
  return "$stop_failed"
}

stop_remote_session() {
  if [[ "$CLEANUP_SESSION_INPUT_OPEN" == "1" ]]; then
    # A failed remote process may already have closed its input.
    (trap '' PIPE; printf 'STOP\n' >&9) 2>/dev/null || true
    exec 9>&-
    CLEANUP_SESSION_INPUT_OPEN=0
  fi
  if [[ -n "$CLEANUP_SESSION_PID" ]]; then
    local session_pid="$CLEANUP_SESSION_PID"
    CLEANUP_SESSION_PID=""
    if [[ "${1:-}" == cancel && "$CLEANUP_REMOTE_PREPARED" != "1" ]]; then
      # Abort a queued/startup SSH session rather than waiting for its full budget.
      # The remote control reader observes STOP/EOF and cancels its supervisor.
      kill "$session_pid" >/dev/null 2>&1 || true
    fi
    if wait "$session_pid"; then
      CLEANUP_REMOTE_STOPPED=1
    else
      return 1
    fi
  fi
}

run_local_mode() {
  require_command git
  require_command jq
  require_command node
  require_command ssh
  require_command rsync
  require_command lsof
  require_command curl

  prepare_local_artifacts
  toastty_begin_run_metadata computer-use macos computer-use

  [[ -n "$REMOTE_HOST" ]] || fail "TOASTTY_REMOTE_GUI_HOST is required"
  if ! run_remote_preflight; then
    fail "Remote preflight failed: $REMOTE_PREFLIGHT_ERROR"
  fi

  copy_prompt_to_artifacts
  write_request_env "$LOCAL_ARTIFACTS_DIR/request.env"

  local started_at
  started_at="$(timestamp_utc)"

  local remote_worktree_dir="$REMOTE_GUI_ROOT/worktrees/$RUN_LABEL"
  local remote_run_root="$REMOTE_GUI_ROOT/runs/$RUN_LABEL"
  local tunnel_pid=""
  local tunnel_log="$LOCAL_ARTIFACTS_DIR/tunnel.log"
  local remote_prepare_stdout="$LOCAL_ARTIFACTS_DIR/remote-prepare.stdout.log"
  local remote_prepare_stderr="$LOCAL_ARTIFACTS_DIR/remote-prepare.stderr.log"
  local local_ws_port=""
  local app_pid=""
  local app_server_pid=""
  local app_server_listener_pid=""
  local socket_path=""

  CLEANUP_REMOTE_WORKTREE_CREATED=0
  CLEANUP_REMOTE_PREPARED=0
  CLEANUP_REMOTE_STOPPED=0
  CLEANUP_REMOTE_REMOVED=0
  CLEANUP_TUNNEL_PID=""
  CLEANUP_REMOTE_WORKTREE_DIR="$remote_worktree_dir"
  CLEANUP_REMOTE_RUN_ROOT="$remote_run_root"
  CLEANUP_SOCKET_PATH=""
  CLEANUP_APP_PID=""
  CLEANUP_APP_SERVER_PID=""
  CLEANUP_APP_SERVER_LISTENER_PID=""
  CLEANUP_APP_SERVER_LAUNCHD_LABEL=""

  cleanup_local_mode() {
    local cleanup_exit_code=$?
    trap '' TERM HUP INT

    if [[ -n "$CLEANUP_CLIENT_PID" ]]; then
      kill "$CLEANUP_CLIENT_PID" >/dev/null 2>&1 || true
      wait "$CLEANUP_CLIENT_PID" >/dev/null 2>&1 || true
    fi

    if [[ -n "$CLEANUP_TUNNEL_PID" ]]; then
      kill "$CLEANUP_TUNNEL_PID" >/dev/null 2>&1 || true
      wait "$CLEANUP_TUNNEL_PID" >/dev/null 2>&1 || true
    fi

    if ! stop_remote_session cancel; then
      warn "Remote session did not confirm cleanup; retaining evidence and any desktop reservation"
      [[ "$cleanup_exit_code" != 0 ]] || cleanup_exit_code=1
    fi

    if [[ "$CLEANUP_REMOTE_WORKTREE_CREATED" == "1" && "$CLEANUP_REMOTE_REMOVED" != "1" ]]; then
      warn "Retaining remote evidence: $CLEANUP_REMOTE_RUN_ROOT"
    fi
    toastty_finish_run_metadata "$cleanup_exit_code" || { [[ "$cleanup_exit_code" != 0 ]] || cleanup_exit_code=1; }

    exit "$cleanup_exit_code"
  }
  trap cleanup_local_mode EXIT
  trap 'exit 143' TERM HUP
  trap 'exit 130' INT

  TOASTTY_METADATA_REMOTE_RUN_ROOT="$remote_run_root"
  TOASTTY_METADATA_REMOTE_WORKTREE="$remote_worktree_dir"
  log "Preparing remote worktree on $REMOTE_HOST"
  remote_shell "
REMOTE_REPO_ROOT=$(escape_sh "$REMOTE_REPO_ROOT")
REMOTE_WORKTREE_DIR=$(escape_sh "$remote_worktree_dir")
REMOTE_RUN_ROOT=$(escape_sh "$remote_run_root")
$(declare -f toastty_allocate_remote_run)
toastty_allocate_remote_run \"\$REMOTE_REPO_ROOT\" \"\$REMOTE_WORKTREE_DIR\" \"\$REMOTE_RUN_ROOT\"
"
  TOASTTY_METADATA_REMOTE_ALLOCATED=true
  CLEANUP_REMOTE_WORKTREE_CREATED=1

  local sync_source_root="$ROOT_DIR"
  local export_root=""
  case "$VALIDATION_SCOPE" in
    working-tree)
      ;;
    head)
      export_root="$(export_ref_tree "$TOASTTY_SOURCE_COMMIT")"
      sync_source_root="$export_root"
      ;;
    ref)
      [[ -n "$REF_SPEC" ]] || fail "--ref is required when --scope ref is used"
      export_root="$(export_ref_tree "$TOASTTY_SOURCE_COMMIT")"
      sync_source_root="$export_root"
      ;;
    *)
      fail "Unsupported validation scope: $VALIDATION_SCOPE"
      ;;
  esac

  log "Syncing local files to remote worktree"
  if ! sync_worktree_to_remote "$sync_source_root" "$remote_worktree_dir"; then
    if [[ -n "$export_root" && -d "$export_root" ]]; then
      rm -rf "$export_root"
    fi
    fail "Failed syncing local files to remote worktree"
  fi
  if [[ -n "$export_root" && -d "$export_root" ]]; then
    rm -rf "$export_root"
  fi

  # Run the current controller separately from the selected source revision.
  # An older --scope head/ref export must still use host-wide admission.
  local controller_root="$remote_run_root/controller"
  toastty_stage_remote_controller "$remote_run_root"

  toastty_run_phase buildAndLaunch
  log "Queueing remote desktop for build, Computer Use turn, and cleanup"
  local session_input="$LOCAL_ARTIFACTS_DIR/session-input.fifo"
  mkfifo "$session_input"
  local remote_command
  remote_command="cd $(escape_sh "$remote_worktree_dir") && CODEX_COMPUTER_USE_MODEL=$(escape_sh "$CODEX_COMPUTER_USE_MODEL") CODEX_COMPUTER_USE_REASONING_EFFORT=$(escape_sh "$CODEX_COMPUTER_USE_REASONING_EFFORT") CODEX_COMPUTER_USE_SERVICE_TIER=$(escape_sh "$CODEX_COMPUTER_USE_SERVICE_TIER") python3 $(escape_sh "$controller_root/scripts/remote/admission.py") run --root $(escape_sh "$REMOTE_GUI_ROOT") --resource desktop --label $(escape_sh "$RUN_LABEL") --timeout $(escape_sh "$QUEUE_TIMEOUT_SECONDS") --runtime-timeout $((3600 + TIMEOUT_SECONDS + 120)) --report $(escape_sh "$remote_run_root/admission.json") --release-marker $(escape_sh "$remote_run_root/desktop-active") -- /bin/bash $(escape_sh "$controller_root/$SCRIPT_PATH") --run-label $(escape_sh "$RUN_LABEL") --remote-session --timeout-seconds $(escape_sh "$TIMEOUT_SECONDS") --remote-worktree-dir $(escape_sh "$remote_worktree_dir") --remote-run-root $(escape_sh "$remote_run_root")"
  ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
    "$REMOTE_HOST" "/bin/bash -l -c $(escape_sh "$remote_command")" \
    <"$session_input" >"$remote_prepare_stdout" 2>"$remote_prepare_stderr" &
  CLEANUP_SESSION_PID=$!
  exec 9>"$session_input"
  CLEANUP_SESSION_INPUT_OPEN=1
  rm -f "$session_input"

  local ready_deadline=$((SECONDS + QUEUE_TIMEOUT_SECONDS + 3600 + 120))
  while kill -0 "$CLEANUP_SESSION_PID" >/dev/null 2>&1; do
    if grep -qx 'TOASTTY_COMPUTER_USE_READY' "$remote_prepare_stdout"; then
      CLEANUP_REMOTE_PREPARED=1
      break
    fi
    if (( SECONDS >= ready_deadline )); then
      warn "Remote session did not become ready before its deadline"
      break
    fi
    sleep 0.2
  done
  if [[ "$CLEANUP_REMOTE_PREPARED" != "1" ]]; then
    stop_remote_session cancel || true
    warn "Remote prepare failed"
    toastty_run_phase artifactCopy
    copy_remote_artifacts_back "$remote_run_root" || true
    local ended_at
    ended_at="$(timestamp_utc)"
    write_result_json \
      "$LOCAL_ARTIFACTS_DIR/result.json" \
      "setup_error" \
      "$started_at" \
      "$ended_at" \
      "Remote Toastty build or Codex app-server startup failed" \
      '{"kind":"remote_prepare_failed","message":"Remote Toastty build or Codex app-server startup failed"}' \
      '{"input":0,"cachedInput":0,"output":0,"reasoningOutput":0,"total":0}' \
      "" \
      "" \
      "$(jq -n --arg started "$started_at" --arg finished "$ended_at" '((($finished | fromdateiso8601) - ($started | fromdateiso8601)) | floor)')" \
      0 \
      false \
      "" \
      "$remote_run_root" \
      "$remote_worktree_dir" \
      "$(configured_model_json)"
    return 1
  fi
  CLEANUP_REMOTE_PREPARED=1

  rsync -a -e 'ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=30 -o ServerAliveCountMax=3' "$REMOTE_HOST:$remote_run_root/launch.json" "$LOCAL_ARTIFACTS_DIR/remote/"

  local launch_json="$LOCAL_ARTIFACTS_DIR/remote/launch.json"
  app_pid="$(jq -r '.appPid' "$launch_json")"
  app_server_pid="$(jq -r '.appServerPid' "$launch_json")"
  app_server_listener_pid="$(jq -r '.appServerListenerPid // empty' "$launch_json")"
  local app_server_launchd_label
  app_server_launchd_label="$(jq -r '.appServerLaunchdLabel // empty' "$launch_json")"
  socket_path="$(jq -r '.socketPath' "$launch_json")"
  CLEANUP_APP_PID="$app_pid"
  CLEANUP_APP_SERVER_PID="$app_server_pid"
  CLEANUP_APP_SERVER_LISTENER_PID="$app_server_listener_pid"
  CLEANUP_APP_SERVER_LAUNCHD_LABEL="$app_server_launchd_label"
  CLEANUP_SOCKET_PATH="$socket_path"
  local remote_app_server_port
  remote_app_server_port="$(jq -r '.appServerPort' "$launch_json")"

  local_ws_port="$(pick_unused_port)" || fail "Failed to allocate a local tunnel port"

  log "Opening local tunnel to remote Codex app-server"
  ssh \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -N \
    -L "127.0.0.1:${local_ws_port}:127.0.0.1:${remote_app_server_port}" \
    "$REMOTE_HOST" >"$tunnel_log" 2>&1 9>&- &
  tunnel_pid=$!
  CLEANUP_TUNNEL_PID="$tunnel_pid"

  for _ in $(seq 1 100); do
    if lsof -nP -iTCP:"$local_ws_port" -sTCP:LISTEN >/dev/null 2>&1 \
      && curl -fsS "http://127.0.0.1:${local_ws_port}/readyz" >/dev/null 2>&1; then
      break
    fi
    if ! kill -0 "$tunnel_pid" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done

  kill -0 "$tunnel_pid" >/dev/null 2>&1 || fail "SSH tunnel to remote app-server exited early"
  lsof -nP -iTCP:"$local_ws_port" -sTCP:LISTEN >/dev/null 2>&1 || fail "Local tunnel did not start listening on port $local_ws_port"
  curl -fsS "http://127.0.0.1:${local_ws_port}/readyz" >/dev/null 2>&1 || fail "Local tunnel did not reach the remote app-server ready endpoint"

  local app_bundle_id
  app_bundle_id="$(jq -er '.appBundleID | select(type == "string" and length > 0)' "$launch_json")" \
    || fail "Remote launch metadata has no nonempty appBundleID"

  toastty_run_phase agentTurn
  log "Running remote Codex turn"
  local client_summary="$LOCAL_ARTIFACTS_DIR/client-summary.json"
  local client_stdout="$LOCAL_ARTIFACTS_DIR/client.stdout.log"
  local client_stderr="$LOCAL_ARTIFACTS_DIR/client.stderr.log"
  local client_exit_code=0

  node "$ROOT_DIR/scripts/remote/codex-app-server-client.mjs" \
      --ws-url "ws://127.0.0.1:${local_ws_port}" \
      --cwd "$remote_worktree_dir" \
      --app-bundle-id "$app_bundle_id" \
      --prompt-file "$PROMPT_FILE" \
      --transcript-path "$LOCAL_ARTIFACTS_DIR/remote/transcript.jsonl" \
      --summary-path "$client_summary" \
      --timeout-seconds "$TIMEOUT_SECONDS" \
      >"$client_stdout" 2>"$client_stderr" 9>&- &
  CLEANUP_CLIENT_PID=$!
  if wait "$CLEANUP_CLIENT_PID"; then
    :
  else
    client_exit_code=$?
  fi
  CLEANUP_CLIENT_PID=""

  toastty_run_phase stopRemoteProcesses
  log "Stopping remote Toastty and Codex app-server"
  if ! stop_remote_session; then
    warn "Remote process cleanup failed"
  fi

  toastty_run_phase artifactCopy
  local copy_succeeded=1
  log "Copying remote artifacts back"
  if ! copy_remote_artifacts_back "$remote_run_root"; then
    copy_succeeded=0
    warn "Failed copying remote artifacts back"
  fi

  local ended_at
  ended_at="$(timestamp_utc)"
  local client_status="setup_error"
  local summary_text="Remote Computer Use run failed before the client summary was written"
  local failure_reason_json='{"kind":"missing_summary","message":"Client summary was not produced"}'
  local tokens_json='{"input":0,"cachedInput":0,"output":0,"reasoningOutput":0,"total":0}'
  local thread_id=""
  local turn_id=""
  local duration_seconds
  duration_seconds="$(jq -n --arg started "$started_at" --arg finished "$ended_at" '((($finished | fromdateiso8601) - ($started | fromdateiso8601)) | floor)')"
  local app_list_count=0
  local computer_use_ready=false
  local final_text=""
  local model_json
  model_json="$(configured_model_json)"

  if [[ -f "$client_summary" ]]; then
    client_status="$(jq -r '.status' "$client_summary")"
    thread_id="$(jq -r '.threadId // empty' "$client_summary")"
    turn_id="$(jq -r '.turnId // empty' "$client_summary")"
    summary_text="$(jq -r 'if .status == "pass" then "Remote Computer Use turn completed" else (.failureReason.message // "Remote Computer Use turn failed") end' "$client_summary")"
    failure_reason_json="$(jq -c '.failureReason // null' "$client_summary")"
    tokens_json="$(jq -c '.tokensUsed // {"input":0,"cachedInput":0,"output":0,"reasoningOutput":0,"total":0}' "$client_summary")"
    duration_seconds="$(jq -r '.durationSeconds // 0' "$client_summary")"
    app_list_count="$(jq -r '.appListCount // 0' "$client_summary")"
    computer_use_ready="$(jq -c '.computerUseReady // false' "$client_summary")"
    final_text="$(jq -r '.finalText // empty' "$client_summary")"
    model_json="$(
      jq -c \
        --arg fallbackName "$CODEX_COMPUTER_USE_MODEL" \
        --arg fallbackReasoningEffort "$CODEX_COMPUTER_USE_REASONING_EFFORT" \
        '{
          name: (.model // $fallbackName),
          provider: (.modelProvider // null),
          serviceTier: (.serviceTier // null),
          reasoningEffort: (.reasoningEffort // $fallbackReasoningEffort)
        }' "$client_summary"
    )"
  elif [[ "$client_exit_code" == "3" ]]; then
    client_status="timeout"
    summary_text="Remote Computer Use turn timed out"
    failure_reason_json="$(jq -cn --arg timeout "$TIMEOUT_SECONDS" '{"kind":"timeout","message":("Turn exceeded timeout of " + $timeout + " seconds")}')"
  elif [[ "$client_exit_code" == "2" ]]; then
    client_status="agent_error"
    summary_text="Remote Computer Use turn failed"
    failure_reason_json='{"kind":"agent_error","message":"Codex turn failed without a client summary"}'
  fi

  if [[ "$copy_succeeded" != 1 || "$CLEANUP_REMOTE_STOPPED" != 1 ]]; then
    summary_text="$summary_text; remote evidence copy or process cleanup failed; remote run retained"
    if [[ "$client_status" == pass ]]; then
      client_status=setup_error
      failure_reason_json='{"kind":"evidence_or_cleanup_failed","message":"Remote evidence copy or process cleanup failed; remote run retained"}'
    fi
  fi

  write_result_json \
    "$LOCAL_ARTIFACTS_DIR/result.json" \
    "$client_status" \
    "$started_at" \
    "$ended_at" \
    "$summary_text" \
    "$failure_reason_json" \
    "$tokens_json" \
    "$thread_id" \
    "$turn_id" \
    "$duration_seconds" \
    "$app_list_count" \
    "$computer_use_ready" \
    "$final_text" \
    "$remote_run_root" \
    "$remote_worktree_dir" \
    "$model_json"

  toastty_run_phase cleanup
  if [[ "$KEEP_REMOTE" != "1" && "$copy_succeeded" == 1 && "$CLEANUP_REMOTE_STOPPED" == 1 ]]; then
    log "Cleaning up remote worktree"
    if remote_shell "
REMOTE_REPO_ROOT=$(escape_sh "$REMOTE_REPO_ROOT")
REMOTE_WORKTREE_DIR=$(escape_sh "$remote_worktree_dir")
REMOTE_RUN_ROOT=$(escape_sh "$remote_run_root")
$(declare -f toastty_remove_remote_run)
toastty_remove_remote_run \"\$REMOTE_REPO_ROOT\" \"\$REMOTE_WORKTREE_DIR\" \"\$REMOTE_RUN_ROOT\"
"; then
      TOASTTY_METADATA_REMOTE_REMOVED=true
      CLEANUP_REMOTE_REMOVED=1
    else
      warn "Remote directory cleanup failed; inspect retained paths: $remote_run_root"
      client_status=setup_error
      toastty_record_infrastructure_failure "$LOCAL_ARTIFACTS_DIR/result.json" "Remote directory cleanup failed; inspect retained paths" setup_error
    fi
  fi

  # The existing EXIT handler finalizes metadata after any fallback cleanup.

  if [[ "$client_status" != "pass" ]]; then
    return 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt)
      [[ $# -ge 2 ]] || fail "--prompt requires a value"
      PROMPT_TEXT="$2"
      shift 2
      ;;
    --prompt-file)
      [[ $# -ge 2 ]] || fail "--prompt-file requires a value"
      PROMPT_FILE="$2"
      shift 2
      ;;
    --scope)
      [[ $# -ge 2 ]] || fail "--scope requires a value"
      VALIDATION_SCOPE="$2"
      shift 2
      ;;
    --ref)
      [[ $# -ge 2 ]] || fail "--ref requires a value"
      REF_SPEC="$2"
      shift 2
      ;;
    --run-label)
      [[ $# -ge 2 ]] || fail "--run-label requires a value"
      RUN_LABEL="$2"
      shift 2
      ;;
    --timeout-seconds)
      [[ $# -ge 2 ]] || fail "--timeout-seconds requires a value"
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --full-artifacts)
      FULL_ARTIFACTS=1
      shift
      ;;
    --keep-remote)
      KEEP_REMOTE=1
      shift
      ;;
    --remote-session)
      REMOTE_SESSION=1
      shift
      ;;
    --remote-prepare)
      REMOTE_PREPARE=1
      shift
      ;;
    --remote-stop)
      REMOTE_STOP=1
      shift
      ;;
    --remote-run-root)
      [[ $# -ge 2 ]] || fail "--remote-run-root requires a value"
      REMOTE_RUN_ROOT_ARG="$2"
      shift 2
      ;;
    --remote-worktree-dir)
      [[ $# -ge 2 ]] || fail "--remote-worktree-dir requires a value"
      REMOTE_WORKTREE_DIR_ARG="$2"
      shift 2
      ;;
    --socket-path)
      [[ $# -ge 2 ]] || fail "--socket-path requires a value"
      SOCKET_PATH_ARG="$2"
      shift 2
      ;;
    --app-pid)
      [[ $# -ge 2 ]] || fail "--app-pid requires a value"
      APP_PID_ARG="$2"
      shift 2
      ;;
    --app-server-pid)
      [[ $# -ge 2 ]] || fail "--app-server-pid requires a value"
      APP_SERVER_PID_ARG="$2"
      shift 2
      ;;
    --app-server-listener-pid)
      [[ $# -ge 2 ]] || fail "--app-server-listener-pid requires a value"
      APP_SERVER_LISTENER_PID_ARG="$2"
      shift 2
      ;;
    --app-server-launchd-label)
      [[ $# -ge 2 ]] || fail "--app-server-launchd-label requires a value"
      APP_SERVER_LAUNCHD_LABEL_ARG="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

if [[ -n "$PROMPT_FILE" && -n "$PROMPT_TEXT" ]]; then
  fail "Use either --prompt or --prompt-file, not both"
fi

if (( REMOTE_PREPARE + REMOTE_STOP + REMOTE_SESSION > 1 )); then
  fail "--remote-prepare, --remote-session, and --remote-stop are mutually exclusive"
fi
[[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || fail "--timeout-seconds must be a positive integer"
[[ "$QUEUE_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || fail "TOASTTY_REMOTE_QUEUE_TIMEOUT_SECONDS must be a positive integer"

if [[ "$REMOTE_PREPARE" == "1" || "$REMOTE_SESSION" == "1" ]]; then
  run_remote_prepare_mode
elif [[ "$REMOTE_STOP" == "1" ]]; then
  run_remote_stop_mode
else
  run_local_mode
fi
