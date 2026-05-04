#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SCRIPT_PATH="scripts/remote/computer-use-run.sh"

REMOTE_PREPARE=0
REMOTE_STOP=0
RUN_LABEL="${RUN_LABEL:-computer-use-$(date +%Y%m%d-%H%M%S)}"
VALIDATION_SCOPE="working-tree"
REF_SPEC=""
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
KEEP_REMOTE=0
PROMPT_FILE=""
PROMPT_TEXT=""
CODEX_COMPUTER_USE_MODEL="${CODEX_COMPUTER_USE_MODEL:-gpt-5.3-codex-spark}"
CODEX_COMPUTER_USE_REASONING_EFFORT="${CODEX_COMPUTER_USE_REASONING_EFFORT:-high}"

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

CLEANUP_REMOTE_WORKTREE_CREATED=0
CLEANUP_REMOTE_PREPARED=0
CLEANUP_REMOTE_STOPPED=0
CLEANUP_REMOTE_REMOVED=0
CLEANUP_TUNNEL_PID=""
CLEANUP_REMOTE_WORKTREE_DIR=""
CLEANUP_REMOTE_RUN_ROOT=""
CLEANUP_SOCKET_PATH=""
CLEANUP_APP_PID=""
CLEANUP_APP_SERVER_PID=""
CLEANUP_APP_SERVER_LISTENER_PID=""

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
  --keep-remote                         Keep the remote worktree and run directory after completion
  --remote-prepare                      Internal mode used on the remote host
  --remote-stop                         Internal mode used on the remote host
  -h, --help                            Show this help

Required local environment:
  TOASTTY_REMOTE_GUI_HOST               SSH host for the dedicated remote GUI machine

Optional local environment:
  TOASTTY_REMOTE_GUI_REPO_ROOT          Absolute Toastty repo path on the remote host
  TOASTTY_REMOTE_GUI_ROOT               Remote directory that will hold disposable worktrees and runs
  CODEX_COMPUTER_USE_MODEL              Codex model for app-server turns (default: gpt-5.3-codex-spark)
  CODEX_COMPUTER_USE_REASONING_EFFORT   Codex reasoning effort for app-server turns (default: high)

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
    -e 'ssh -o BatchMode=yes -o ConnectTimeout=5' \
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
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_HOST" /bin/bash -l -s -- <<EOF
set -euo pipefail
$script
EOF
}

run_remote_preflight() {
  local output
  if ! output="$(
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_HOST" /bin/bash -l -s -- \
      "$REMOTE_REPO_ROOT" \
      "$REMOTE_GUI_ROOT" <<'EOF' 2>&1
set -euo pipefail
remote_repo_root="$1"
remote_gui_root="$2"
git -C "$remote_repo_root" rev-parse --is-inside-work-tree >/dev/null
test -x /Applications/Codex.app/Contents/Resources/codex
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
EOF
}

configured_model_json() {
  jq -cn \
    --arg name "$CODEX_COMPUTER_USE_MODEL" \
    --arg reasoningEffort "$CODEX_COMPUTER_USE_REASONING_EFFORT" \
    '{
      name: $name,
      provider: null,
      serviceTier: null,
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
  rsync -a "$REMOTE_HOST:$1/" "$LOCAL_ARTIFACTS_DIR/remote/"
}

run_remote_prepare_mode() {
  require_command xcodebuild
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
  local socket_path="${TMPDIR:-/tmp}/tt-cu-${run_hash_value}.sock"
  local build_log="$remote_run_root/build.log"
  local app_log="$remote_run_root/app.log"
  local bootstrap_log="$remote_run_root/bootstrap.log"
  local app_server_log="$remote_run_root/app-server.log"
  local app_server_session_log="$remote_run_root/app-server-session.log"
  local launch_json="$remote_run_root/launch.json"
  local arch="${ARCH:-$(uname -m)}"
  local app_bundle="$derived_path/Build/Products/Debug/Toastty.app"
  local app_binary="$app_bundle/Contents/MacOS/Toastty"
  local instance_json="$runtime_home/instance.json"
  local codex_cli="/Applications/Codex.app/Contents/Resources/codex"
  local app_pid=""
  local app_server_pid=""
  local app_server_listener_pid=""
  local app_server_port=""
  local prepare_succeeded=0

  cleanup_remote_prepare() {
    local cleanup_exit_code=$?
    if [[ "$prepare_succeeded" == "1" ]]; then
      return "$cleanup_exit_code"
    fi
    rm -f "$socket_path"
    if [[ -n "$app_server_listener_pid" ]]; then
      kill "$app_server_listener_pid" >/dev/null 2>&1 || true
    fi
    if [[ -n "$app_server_pid" ]]; then
      kill "$app_server_pid" >/dev/null 2>&1 || true
      wait "$app_server_pid" >/dev/null 2>&1 || true
    fi
    if [[ -n "$app_pid" ]]; then
      kill "$app_pid" >/dev/null 2>&1 || true
      wait "$app_pid" >/dev/null 2>&1 || true
    fi
    return "$cleanup_exit_code"
  }
  trap cleanup_remote_prepare EXIT

  mkdir -p "$remote_run_root" "$runtime_home" "$(dirname "$socket_path")"
  rm -f "$socket_path"
  rm -f "$launch_json"

  (
    cd "$remote_worktree_dir"
    ./scripts/dev/bootstrap-worktree.sh
  ) >"$bootstrap_log" 2>&1

  (
    cd "$remote_worktree_dir"
    xcodebuild \
      -workspace toastty.xcworkspace \
      -scheme ToasttyApp \
      -configuration Debug \
      -destination "platform=macOS,arch=${arch}" \
      -derivedDataPath "$derived_path" \
      build
  ) >"$build_log" 2>&1

  TOASTTY_RUNTIME_HOME="$runtime_home" \
  TOASTTY_SOCKET_PATH="$socket_path" \
  TOASTTY_DERIVED_PATH="$derived_path" \
  "$app_binary" >"$app_log" 2>&1 &
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

  local recorded_pid
  recorded_pid="$(grep -Eo '"pid"[[:space:]]*:[[:space:]]*[0-9]+' "$instance_json" | grep -Eo '[0-9]+' | head -n 1 || true)"
  if [[ -n "$recorded_pid" ]]; then
    app_pid="$recorded_pid"
  fi

  app_server_port="$(pick_unused_port)" || fail "Failed to allocate a free port for codex app-server"

  nohup script -q "$app_server_session_log" "$codex_cli" app-server \
    -c "model=\"${CODEX_COMPUTER_USE_MODEL}\"" \
    -c "model_reasoning_effort=\"${CODEX_COMPUTER_USE_REASONING_EFFORT}\"" \
    --listen "ws://127.0.0.1:${app_server_port}" \
    >"$app_server_log" 2>&1 < /dev/null &
  app_server_pid=$!

  for _ in $(seq 1 150); do
    if curl -fsS "http://127.0.0.1:${app_server_port}/readyz" >/dev/null 2>&1; then
      break
    fi
    if ! kill -0 "$app_server_pid" >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
  done

  curl -fsS "http://127.0.0.1:${app_server_port}/readyz" >/dev/null 2>&1 || fail "codex app-server did not become ready"
  app_server_listener_pid="$(lsof -tiTCP:"$app_server_port" -sTCP:LISTEN | head -n 1 || true)"

  cat >"$launch_json" <<EOF
{
  "schemaVersion": 1,
  "executionPath": "codex_app_server",
  "runLabel": "$(json_escape "$RUN_LABEL")",
  "remoteRunRoot": "$(json_escape "$remote_run_root")",
  "remoteWorktreeDir": "$(json_escape "$remote_worktree_dir")",
  "derivedPath": "$(json_escape "$derived_path")",
  "runtimeHome": "$(json_escape "$runtime_home")",
  "socketPath": "$(json_escape "$socket_path")",
  "instanceJson": "$(json_escape "$instance_json")",
  "appBundle": "$(json_escape "$app_bundle")",
  "appBinary": "$(json_escape "$app_binary")",
  "appPid": ${app_pid},
  "codexModel": "$(json_escape "$CODEX_COMPUTER_USE_MODEL")",
  "codexReasoningEffort": "$(json_escape "$CODEX_COMPUTER_USE_REASONING_EFFORT")",
  "appServerPort": ${app_server_port},
  "appServerPid": ${app_server_pid},
  "appServerListenerPid": $(if [[ -n "$app_server_listener_pid" ]]; then printf '%s' "$app_server_listener_pid"; else printf 'null'; fi)
}
EOF

  prepare_succeeded=1
  trap - EXIT
}

run_remote_stop_mode() {
  [[ -n "$SOCKET_PATH_ARG" ]] || fail "--socket-path is required for --remote-stop"

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

  rm -f "$SOCKET_PATH_ARG"

  if [[ -n "$APP_SERVER_LISTENER_PID_ARG" ]]; then
    kill "$APP_SERVER_LISTENER_PID_ARG" >/dev/null 2>&1 || true
    wait_for_pid_exit "$APP_SERVER_LISTENER_PID_ARG" || true
  fi

  if [[ -n "$APP_SERVER_PID_ARG" ]]; then
    kill "$APP_SERVER_PID_ARG" >/dev/null 2>&1 || true
    wait_for_pid_exit "$APP_SERVER_PID_ARG" || true
  fi

  if [[ -n "$APP_PID_ARG" ]]; then
    kill "$APP_PID_ARG" >/dev/null 2>&1 || true
    wait_for_pid_exit "$APP_PID_ARG" || true
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

  [[ -n "$REMOTE_HOST" ]] || fail "TOASTTY_REMOTE_GUI_HOST is required"
  if ! run_remote_preflight; then
    fail "Remote preflight failed: $REMOTE_PREFLIGHT_ERROR"
  fi

  prepare_local_artifacts
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

  cleanup_local_mode() {
    local cleanup_exit_code=$?

    if [[ -n "$CLEANUP_TUNNEL_PID" ]]; then
      kill "$CLEANUP_TUNNEL_PID" >/dev/null 2>&1 || true
      wait "$CLEANUP_TUNNEL_PID" >/dev/null 2>&1 || true
    fi

    if [[ "$CLEANUP_REMOTE_PREPARED" == "1" && "$CLEANUP_REMOTE_STOPPED" != "1" ]]; then
      ssh -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_HOST" /bin/bash -l -s -- \
        "$CLEANUP_REMOTE_WORKTREE_DIR" \
        "$SCRIPT_PATH" \
        "$RUN_LABEL" \
        "$CLEANUP_SOCKET_PATH" \
        "$CLEANUP_APP_PID" \
        "$CLEANUP_APP_SERVER_PID" \
        "${CLEANUP_APP_SERVER_LISTENER_PID:-}" <<'EOF' >/dev/null 2>&1 || true
set -euo pipefail
remote_worktree_dir="$1"
script_path="$2"
run_label="$3"
socket_path="$4"
app_pid="$5"
app_server_pid="$6"
app_server_listener_pid="${7:-}"
cd "$remote_worktree_dir"
/bin/bash "$script_path" \
  --run-label "$run_label" \
  --remote-stop \
  --socket-path "$socket_path" \
  --app-pid "$app_pid" \
  --app-server-pid "$app_server_pid" \
  --app-server-listener-pid "$app_server_listener_pid"
EOF
    fi

    if [[ "$KEEP_REMOTE" != "1" && "$CLEANUP_REMOTE_WORKTREE_CREATED" == "1" && "$CLEANUP_REMOTE_REMOVED" != "1" ]]; then
      remote_shell "
REMOTE_REPO_ROOT=$(escape_sh "$REMOTE_REPO_ROOT")
REMOTE_WORKTREE_DIR=$(escape_sh "$CLEANUP_REMOTE_WORKTREE_DIR")
REMOTE_RUN_ROOT=$(escape_sh "$CLEANUP_REMOTE_RUN_ROOT")
git -C \"\$REMOTE_REPO_ROOT\" worktree remove --force \"\$REMOTE_WORKTREE_DIR\" >/dev/null 2>&1 || rm -rf \"\$REMOTE_WORKTREE_DIR\"
rm -rf \"\$REMOTE_RUN_ROOT\"
" >/dev/null 2>&1 || true
    fi

    return "$cleanup_exit_code"
  }
  trap cleanup_local_mode EXIT

  log "Preparing remote worktree on $REMOTE_HOST"
  remote_shell "
REMOTE_REPO_ROOT=$(escape_sh "$REMOTE_REPO_ROOT")
REMOTE_WORKTREE_DIR=$(escape_sh "$remote_worktree_dir")
REMOTE_RUN_ROOT=$(escape_sh "$remote_run_root")
git -C \"\$REMOTE_REPO_ROOT\" rev-parse --is-inside-work-tree >/dev/null
mkdir -p \"\$(dirname \"\$REMOTE_WORKTREE_DIR\")\" \"\$(dirname \"\$REMOTE_RUN_ROOT\")\"
rm -rf \"\$REMOTE_RUN_ROOT\"
if [[ -e \"\$REMOTE_WORKTREE_DIR\" ]]; then
  git -C \"\$REMOTE_REPO_ROOT\" worktree remove --force \"\$REMOTE_WORKTREE_DIR\" >/dev/null 2>&1 || rm -rf \"\$REMOTE_WORKTREE_DIR\"
fi
git -C \"\$REMOTE_REPO_ROOT\" worktree add --detach \"\$REMOTE_WORKTREE_DIR\" >/dev/null
mkdir -p \"\$REMOTE_RUN_ROOT\"
"
  CLEANUP_REMOTE_WORKTREE_CREATED=1

  local sync_source_root="$ROOT_DIR"
  local export_root=""
  case "$VALIDATION_SCOPE" in
    working-tree)
      ;;
    head)
      export_root="$(export_ref_tree HEAD)"
      sync_source_root="$export_root"
      ;;
    ref)
      [[ -n "$REF_SPEC" ]] || fail "--ref is required when --scope ref is used"
      export_root="$(export_ref_tree "$REF_SPEC")"
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

  log "Building and launching Toastty on the remote host"
  if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_HOST" /bin/bash -l -s -- \
      "$remote_worktree_dir" \
      "$SCRIPT_PATH" \
      "$RUN_LABEL" \
      "$remote_run_root" \
      "$CODEX_COMPUTER_USE_MODEL" \
      "$CODEX_COMPUTER_USE_REASONING_EFFORT" \
      > >(tee "$remote_prepare_stdout") \
      2> >(tee "$remote_prepare_stderr" >&2) <<'EOF'; then
set -euo pipefail
remote_worktree_dir="$1"
script_path="$2"
run_label="$3"
remote_run_root="$4"
codex_model="$5"
codex_reasoning_effort="$6"
cd "$remote_worktree_dir"
CODEX_COMPUTER_USE_MODEL="$codex_model" \
CODEX_COMPUTER_USE_REASONING_EFFORT="$codex_reasoning_effort" \
  /bin/bash "$script_path" \
  --run-label "$run_label" \
  --remote-prepare \
  --remote-worktree-dir "$remote_worktree_dir" \
  --remote-run-root "$remote_run_root"
EOF
    warn "Remote prepare failed"
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

  rsync -a "$REMOTE_HOST:$remote_run_root/launch.json" "$LOCAL_ARTIFACTS_DIR/remote/"

  local launch_json="$LOCAL_ARTIFACTS_DIR/remote/launch.json"
  app_pid="$(jq -r '.appPid' "$launch_json")"
  app_server_pid="$(jq -r '.appServerPid' "$launch_json")"
  app_server_listener_pid="$(jq -r '.appServerListenerPid // empty' "$launch_json")"
  socket_path="$(jq -r '.socketPath' "$launch_json")"
  CLEANUP_APP_PID="$app_pid"
  CLEANUP_APP_SERVER_PID="$app_server_pid"
  CLEANUP_APP_SERVER_LISTENER_PID="$app_server_listener_pid"
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
    "$REMOTE_HOST" >"$tunnel_log" 2>&1 &
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

  log "Running remote Codex turn"
  local client_summary="$LOCAL_ARTIFACTS_DIR/client-summary.json"
  local client_stdout="$LOCAL_ARTIFACTS_DIR/client.stdout.log"
  local client_stderr="$LOCAL_ARTIFACTS_DIR/client.stderr.log"
  local client_exit_code=0

  if node "$ROOT_DIR/scripts/remote/codex-app-server-client.mjs" \
      --ws-url "ws://127.0.0.1:${local_ws_port}" \
      --cwd "$remote_worktree_dir" \
      --prompt-file "$PROMPT_FILE" \
      --transcript-path "$LOCAL_ARTIFACTS_DIR/remote/transcript.jsonl" \
      --summary-path "$client_summary" \
      --timeout-seconds "$TIMEOUT_SECONDS" \
      >"$client_stdout" 2>"$client_stderr"; then
    :
  else
    client_exit_code=$?
  fi

  log "Stopping remote Toastty and Codex app-server"
  if ssh -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_HOST" /bin/bash -l -s -- \
      "$remote_worktree_dir" \
      "$SCRIPT_PATH" \
      "$RUN_LABEL" \
      "$socket_path" \
      "$app_pid" \
      "$app_server_pid" \
      "${app_server_listener_pid:-}" <<'EOF'; then
set -euo pipefail
remote_worktree_dir="$1"
script_path="$2"
run_label="$3"
socket_path="$4"
app_pid="$5"
app_server_pid="$6"
app_server_listener_pid="${7:-}"
cd "$remote_worktree_dir"
/bin/bash "$script_path" \
  --run-label "$run_label" \
  --remote-stop \
  --socket-path "$socket_path" \
  --app-pid "$app_pid" \
  --app-server-pid "$app_server_pid" \
  --app-server-listener-pid "$app_server_listener_pid"
EOF
    CLEANUP_REMOTE_STOPPED=1
  else
    warn "Remote process cleanup failed"
  fi

  log "Copying remote artifacts back"
  if ! copy_remote_artifacts_back "$remote_run_root"; then
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

  if [[ "$KEEP_REMOTE" != "1" ]]; then
    log "Cleaning up remote worktree"
    remote_shell "
REMOTE_REPO_ROOT=$(escape_sh "$REMOTE_REPO_ROOT")
REMOTE_WORKTREE_DIR=$(escape_sh "$remote_worktree_dir")
REMOTE_RUN_ROOT=$(escape_sh "$remote_run_root")
git -C \"\$REMOTE_REPO_ROOT\" worktree remove --force \"\$REMOTE_WORKTREE_DIR\" >/dev/null 2>&1 || rm -rf \"\$REMOTE_WORKTREE_DIR\"
rm -rf \"\$REMOTE_RUN_ROOT\"
"
    CLEANUP_REMOTE_REMOVED=1
  fi

  trap - EXIT

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
    --keep-remote)
      KEEP_REMOTE=1
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

if [[ "$REMOTE_PREPARE" == "1" && "$REMOTE_STOP" == "1" ]]; then
  fail "--remote-prepare and --remote-stop are mutually exclusive"
fi

if [[ "$REMOTE_PREPARE" == "1" ]]; then
  run_remote_prepare_mode
elif [[ "$REMOTE_STOP" == "1" ]]; then
  run_remote_stop_mode
else
  run_local_mode
fi
